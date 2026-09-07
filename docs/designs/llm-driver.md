# Design: LLM driver

Date: 2026-09-06
Repo: tiller
Status: BUILT (MVP; see "What shipped" below)
Mode: Builder

## Problem Statement

Everything tiller runs today is scripted. `Tiller.FakeDriver` hands the
session a fixed list of actions and never looks at a result, so no
mutation can change what the agent does next: most branches in the lab
come back "path only", and "decisive" is reserved for a driver swap that
scripts a different ending. The counterfactual machinery is complete and
the one thing missing is an agent that reacts.

`Tiller.Driver` was reserved for exactly this. The design goal is a driver
that turns the session's whitelist into the model's tool surface and the
model's tool call into the quoted MFA term the session already evaluates,
with every other module unchanged.

## What Makes This Cool

- **The grammar is the tool list.** Each whitelisted `{name, arity}` becomes
  one tool definition; a `tool_use` block becomes `{:call, Tiller.Tools, f,
  args}`. A whitelist mutation is literally a different `tools` array in
  the request. The capability boundary and the prompt are the same object.
- **The conversation is the context.** Driver context is the message list.
  A fork at turn N is a truncation of the conversation, so the prefix stays
  byte-identical: prompt caching hits across branches and, on models that
  bind thinking blocks to their prefix, the blocks stay valid.
- **Mutations become decisive.** A refused `spend` now changes what the
  model tries next. "What if this tool had not been allowed at turn 3" gets
  an answer that depends on the agent, not on the script.
- **A noise floor.** Branches after the fork point are fresh samples, so
  two control branches can differ with nothing changed. Racing a few
  controls measures that variance, and the lab can then say "this mutation
  changed the outcome beyond what nothing changes". No other tool surveyed
  reports that.

## Constraints

- Elixir has no official Anthropic SDK. The driver speaks raw HTTP through
  OTP's built-in `:httpc` and Elixir's built-in `JSON`. `lib/tiller` gains
  no dependency.
- Claude Code on the web has no API credential. Tests run against a
  scripted stand-in for `POST /v1/messages` (a Plug on the Bandit
  dependency that already exists), the same pattern as
  `test/support/fake_seed_mcp.exs`. A real-key run is an opt-in
  integration test tagged `:integration`.
- The Messages API rules the driver must absorb (checked against the
  current reference on 2026-09-06):
  - `tool_choice` stays `{type: "auto"}` with `disable_parallel_tool_use:
    true`: one action per turn matches the session loop. Forced tool use
    is rejected on some models anyway.
  - Check `stop_reason` before reading content. `refusal` is a successful
    HTTP 200 with empty or partial content.
  - Parse `tool_use.input` as JSON; never string-match it.
  - History is append-only. Editing a turn in the middle invalidates every
    later thinking block on models that bind them. Truncation is not an
    edit; a result override is.
  - Non-streaming requests with `max_tokens` around 4096: a turn's output
    is one tool call.
- Cost is bounded per run by a turn cap and an input-token cap, and per
  branch the lab shows tokens spent.

## Decisions (2026-09-06)

1. **Model:** `claude-opus-5` by default, configurable per driver context.
   Adaptive thinking is on by default there, every `tool_choice` is
   accepted, and there are no classifier refusals to route around. Effort
   `low` for the toy world.
2. **First task:** the toy world. A goal over the existing `put`, `get`,
   `spend`, `flaky`, `sleep` tools: store a fact, spend within budget,
   read it back, finish. No external process, fully testable against the
   fake API, every mutation axis applies. The open-seed loop is the second
   task (Open Question 3).
3. **Ending:** a `done/1` tool. The model finishes by calling
   `done(summary)`, so the final answer is an action in the log and
   `Tiller.Race.outcome/1` compares runs on it. A plain text reply with no
   tool call is treated as `done(text)`.

## Recommended Approach

### The driver

`Tiller.Driver.LLM` implements `Tiller.Driver`. Its context:

```elixir
@type ctx :: %{
        model: String.t(),                  # "claude-opus-5"
        system: String.t(),                 # frozen at session start
        tools: [map],                       # derived from the whitelist, name-sorted
        messages: [map],                    # the conversation; ends with a user message
        effort: :low | :medium | :high,
        max_turns: pos_integer,             # default 12
        max_input_tokens: pos_integer,      # per run
        turn: non_neg_integer,
        usage: %{input: non_neg_integer, output: non_neg_integer},
        api: %{base_url: String.t(), api_key: String.t() | nil, timeout: pos_integer},
        pending: String.t() | nil,          # tool_use id awaiting its result
        status: :running | :finished | {:halted, term}
      }
```

`next_action/1`:

1. If `status` is not `:running`, return `:halt`.
2. If the turn or token cap is spent, halt with reason `:budget`.
3. `POST /v1/messages` with `model`, `max_tokens`, `system`, `tools`,
   `tool_choice`, `output_config: %{effort: ...}`, `messages`. Retry
   429 and 5xx with bounded backoff; a transport failure after retries
   halts with reason `{:api, reason}`.
4. Branch on `stop_reason`:
   - `tool_use`: take the single `tool_use` block, map its `input` to
     positional args (below), append the assistant content to `messages`,
     set `pending` to the block id, return `{:action, term, ctx}`.
   - `end_turn` with text and no tool call: synthesize `done(text)` as the
     action so the answer is logged; mark `finished`.
   - `refusal`: halt with reason `{:refusal, category}`.
   - `max_tokens`: halt with reason `:max_tokens`.

`observe/3` (new, optional callback; see below): after the session records
the result, append `{role: "user", content: [%{type: "tool_result",
tool_use_id: pending, content: ..., is_error: ...}]}`. `{:ok, v}` renders
`v` as JSON when encodable, else `inspect(v)`; `{:error, r}` sets
`is_error` and renders the reason. A `done` call ends the run: the next
`next_action/1` returns `:halt`.

### Tool surface

`Tiller.Tools.Schema` is the single table that makes a tool callable by a
model: ordered parameter names and JSON types per `{name, arity}`.

```elixir
%{
  {:put, 2}   => [key: :string, value: :any],
  {:get, 1}   => [key: :string],
  {:spend, 1} => [amount: :integer],
  {:flaky, 1} => [value: :any],
  {:sleep, 1} => [ms: :integer],
  {:echo, 1}  => [value: :any],
  {:done, 1}  => [summary: :string]
}
```

`tools(whitelist)` emits one definition per whitelisted entry that has a
schema, `strict: true`, `additionalProperties: false`, every parameter
required, sorted by name so the array is stable across requests. Entries
without a schema (`spawn_subagent`, `fail`) are simply not offered; the
session still refuses anything off the whitelist at `eval`, so the model
never gets past the boundary even if it invents a name. JSON `input` maps
to positional args in schema order. The `seed_*` verbs get schemas when
the second task lands.

### Driver behaviour additions

Two optional callbacks join `Tiller.Driver`; the session and the fork
honour them when exported, and `FakeDriver` needs neither.

- `observe(ctx, action, result) :: ctx`, called by the session after it
  records an event. This is how a result reaches the driver; today
  nothing does, because scripted drivers never look.
- `override(ctx, turn, result) :: ctx`, called at fork time for a
  `{:result_override, turn, result}` mutation. The LLM driver rewrites the
  `tool_result` at that turn and strips `thinking` blocks from every later
  assistant message, which is the API's rule for an edited history. The
  branch continues without the reasoning those blocks carried; that is the
  documented cost of the axis and the lab says so on the branch card.

Replay and snapshots already do the rest. The snapshot at turn N holds the
driver context at N, which for this driver is the conversation up to N.
A control, whitelist, driver, latency or kill fork hands the branch that
context unchanged. A kill resumes at the in-flight turn and calls the API
again for it, so the re-run turn is a fresh sample: the tool already ran
once, and the model may now choose differently. Honest, and visible.

### Halting with a reason

`next_action/1` may return `{:halt, reason}`. The session records the
terminal event as `{:halted, turns, reason}` in that case and `{:halted,
turns}` as today otherwise, so an abnormal ending diverges from a normal
one under `Tiller.Divergence` and `Tiller.Event.halt?/1` still matches
both.

### The fake API

`Tiller.FakeMessages` is a Plug router mounted on Bandit for tests and for
the demo when no key is present. It accepts the real request shape and
answers from a script: a list of responses keyed by turn, or a function
of the last `tool_result`, so a test can say "when `spend` is refused,
answer with `get`". It validates that `tools` names match the whitelist
sent and that `tool_choice` is `auto`, which catches request drift.

### The lab

- **Control band.** The fork presets gain `k` control branches (default
  3). `Tiller.Race.noise_floor/2` is the largest distance among controls;
  a mutation is *decisive beyond noise* when it is decisive and its
  distance exceeds the floor. The grid marks the band and the star goes
  only to branches above it.
- **Cost.** Each branch card shows input and output tokens from the
  driver's `usage`.
- **Prompt cache.** All branches share the source's prefix. A
  `cache_control` breakpoint on the last prefix message makes the fan-out
  mostly cache reads. Deferred until the first real-key run shows the
  numbers.

### Request shape (for the record)

```json
{
  "model": "claude-opus-5",
  "max_tokens": 4096,
  "system": "...frozen at session start...",
  "tools": [{"name": "spend", "description": "...", "strict": true,
             "input_schema": {"type": "object",
                              "properties": {"amount": {"type": "integer"}},
                              "required": ["amount"],
                              "additionalProperties": false}}],
  "tool_choice": {"type": "auto", "disable_parallel_tool_use": true},
  "output_config": {"effort": "low"},
  "messages": [{"role": "user", "content": "Store the greeting..."}]
}
```

Headers: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type`.
Thinking is omitted (adaptive by default on this model).

## Mutation axes, revisited

| Axis | Scripted driver | LLM driver |
|---|---|---|
| Whitelist | session refuses the call | tool absent from the request; the model plans without it |
| Driver | a different script | a different system prompt, model, or effort |
| Result override | one injected result | one edited `tool_result`; thinking stripped after it |
| Latency | slower turns | unchanged |
| Kill | double side effect, same action | double side effect, possibly a different action |

## Open Questions

1. **Parallel tool calls.** Disabled in v1 so one action equals one turn.
   Enabling them means lifting the session's one-call-per-turn limit,
   which the original design deferred to `Task.async_stream`.
2. **Subagents from the model.** `spawn_subagent/2` takes a module and a
   context, which a model cannot supply. The model-facing form is a
   `spawn(goal)` tool that starts an LLM subagent with a goal string and
   the subagent whitelist. Not v1; needs the `await` tool question from
   the lab design answered first.
3. **The open-seed task.** A system prompt for the worker loop plus
   schemas for the `seed_*` verbs. Branch isolation stops at the engine's
   state, so a fork's replayed prefix does not put the engine back where
   it was. The honest version runs each branch against its own
   instantiated repo, which is a fixture question, not a driver one.
4. **Thinking display.** Omitted in v1. `display: "summarized"` would let
   the turn-detail pane show why the model chose an action, which is the
   inspector's natural next feature.
5. **Determinism knobs.** No sampling parameters exist on this model, so
   the noise floor is the only handle. Whether three controls are enough
   is an empirical question for the first real-key run.

## Success Criteria

**MVP (this is "Done"):** against the fake API, a run of the toy goal
produces a log in which the model's next action depends on the previous
result (a test scripts a refused `spend` and asserts the following action
differs from the unrefused script); a fork with the whitelist minus
`spend` is decisive; three control branches yield a noise floor and the
grid shows the band. All of it in `mix test` with no network.

**Stretch:** the same goal against the real API with three controls and
four mutations, one screenshot; the seed task; summarized thinking in the
turn pane.

Out of scope: streaming, parallel tool calls, model-spawned subagents,
prompt-cache tuning before there are numbers.

## What shipped (2026-09-07)

Steps 1 to 5 and 7 of the plan below, as `mix test` with no credential:

- **The Assignment passed.** `Tiller.Driver.LLM.Wire` is pure encode and
  decode over maps; `Tiller.Tools.Schema` is the one table naming each
  tool's parameters and their order, so named JSON maps onto positional
  args in one place. Well inside the budget, so the tool surface keeps
  the shape this design proposed.
- **`Tiller.Driver` gained `observe/3` and `override/3`** as optional
  callbacks, plus `{:halt, reason}`. The session calls `observe` after
  recording each event and `override` at fork time for a result
  override; `Tiller.Driver.Replay` forwards both, but only for the
  branch's own turns, because the delegate's context already contains
  the replayed prefix. A halt with a reason is logged as
  `{:halted, turns, reason}`, and `Tiller.Event.halted_turns/1` is what
  reads either form.
- **`done/1`** is a tool on every whitelist, so a run's answer is an
  action `Tiller.Race` compares two runs on.
- **`Tiller.Driver.LLM`** speaks the Messages API over `:httpc` with
  retries and turn and token caps. Refusals, caps and API failures end
  the run through `{:halt, reason}`.
- **`Tiller.FakeMessages`** is the Plug this is all tested against. It
  validates the request shape (auto tool choice, strict tools, known
  names), so request drift fails a test.
- **The real API** is one opt-in test, `TILLER_ANTHROPIC_API_KEY` plus
  `--include integration`.

**One correction to the design.** The ctx type below carries a `tools`
array built at context creation. That is wrong for the lab: a
`{:whitelist, list}` fork changes the *session's* whitelist, and a baked
array would leave the branch's model still being offered a tool the
session would refuse. The array is derived per request from
`Tiller.Session.current_whitelist/0` instead, with the context's own
whitelist as the fallback outside a session. This is what the design's
own claim ("a whitelist mutation is literally a different `tools`
array") requires, and a test asserts the branch plans without the tool
rather than being refused after choosing it.

**Not built:** step 6, the control band and per-branch cost in the lab.
Until it lands, the lab cannot separate a branch the mutation changed
from one the model merely sampled differently.

## Next Steps

1. **The Assignment** below. Go/no-go on the arg mapping.
2. `Tiller.Driver` gains `observe/3` and `override/3` as optional
   callbacks; the session calls `observe` after `record`, the fork calls
   `override` for result overrides. `{:halt, reason}` and the
   three-element halt result.
3. `Tiller.Tools.Schema` and `done/1`.
4. `Tiller.Driver.LLM` with `:httpc`, retries, caps.
5. `Tiller.FakeMessages` and the driver tests.
6. Control band and cost in `Tiller.Race` and the lab.
7. Integration test behind `TILLER_ANTHROPIC_API_KEY`, tagged
   `:integration`, like the seed one.

## The Assignment

Before touching the session, spend 30 minutes on `Tiller.Driver.LLM.Wire`,
pure functions over maps:

```elixir
@spec tools([{atom, arity}]) :: [map]
@spec decode(response :: map) ::
        {:tool_use, id :: String.t(), Tiller.Event.action()}
      | {:text, String.t()}
      | {:refusal, term}
      | {:stop, atom}
@spec tool_result(id :: String.t(), Tiller.Event.result()) :: map
```

Three tests with hand-written JSON: a `tool_use` for `spend` decodes to
`{:call, Tiller.Tools, :spend, [4]}` with args in schema order; an
`end_turn` text decodes to `{:text, _}`; a `refusal` decodes to
`{:refusal, _}` without touching `content`. If the schema-order mapping is
obviously right inside 30 minutes, build the rest. If arities and JSON
objects are still fighting at minute 45, the tool surface needs a
different shape (named args everywhere, or one `call(name, args)` tool)
and that decision comes before any HTTP.
