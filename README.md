# tiller

A small agentic harness for Elixir. One loop, two modes: a session you drive
interactively, or a session that spawns supervised subagents. Subagents are
not a mode — they're a tool (`spawn_subagent`) in the parent's whitelist.

### The name

A tiller is the lever on a rudder: one hand, one course, small
corrections. That is the harness this started as. In grasses, tillering
is when one plant sends up many stems from the same crown: every stem
shares the root, they grow in parallel, and the plant keeps the ones
that make it. That is the lab this became. The name reads as a rudder
and the code reads as a crown, and both readings are meant.

## Design

### The borrowed idea

From [lisptc](https://github.com/1hachem/lisptc) (neuro-symbolic LLM + small
Lisp runtime): constrain the model's action output to **data in a shared,
inspectable store**, so the trajectory is a diffable, replayable program —
not a pile of log strings.

We keep that property and drop the interpreter: in Elixir, a quoted term
*is* the AST, and evaluating it against a whitelisted set of functions gives
us lisptc's three claims with no runtime to maintain:

1. **Constrained output** — the driver emits a quoted MFA term, not free-form code. Garbage in → `FunctionClauseError`, not a half-executed script.
2. **Deterministic memory** — every action + result is appended to a single
   `Tiller.State` log. It is the audit trail, the replay log, and the source
   of the next prompt. One thing, three jobs.
3. **Bidirectional** — the loop is just `next_action(state) → eval → append → repeat`.

### Architecture

```
Tiller (DynamicSupervisor)
├─ Tiller.State            ← ordered event store, attributed per session
├─ Tiller.ToolState        ← state behind side-effecting tools (kv, budget)
├─ Tiller.Registry         ← sessions addressable by id
├─ Session "root"          ← you drive; base tools + spawn_subagent
│   └─ Session "root.0"    ← LLM/fake-driven; base tools only, no spawn
├─ Session "root@2.1"      ← a fork of root at turn 2, one thing different
└─ TillerWeb.Endpoint      ← the lab screen (Phoenix LiveView, loopback only)
```

- **Session** (`Tiller.Session`): one GenServer per run. `run/1` casts; each
  turn is one message to self: ask driver for next action → evaluate against
  tool whitelist → append a `Tiller.Event` to `Tiller.State` → schedule the
  next turn, until `:halt`. `await/2` blocks until halt. Crashes are
  contained: a tool crash is data in the log, and a subagent runs under the
  supervisor without blocking its parent.
- **Event** (`Tiller.Event`): `{seq, session_id, parent_id, turn, action,
  result}`. Subagent ids are deterministic (`"root.0"`), so trajectories
  compare across runs. `Tiller.Divergence.first_diff/2` finds the first turn
  where two of them disagree.
- **Fork** (`Tiller.Session.fork/4`): start a branch from any turn of a
  session with one `Tiller.Mutation` (or none, for a control). The branch
  replays the prefix with recorded results (`Tiller.Driver.Replay`), starts
  from the tool-state snapshot taken at that turn, then continues with the
  source's driver and context as they were, or with what the mutation says.
  Branches run under the supervisor and race; `Tiller.Demo.run/0` shows four.
- **Race** (`Tiller.Race`): ranks branches against the original. A mutation
  is *decisive* if the branch ends somewhere else; the smallest decisive one
  is the one whose trajectory differs in the fewest turns. Measured on the
  log, so axes never need comparing.
- **Cost** (`Tiller.Driver.usage/1`): a driver that spends anything reports
  what it spent, and the lab shows it per branch and for the race. A fork
  is billed only for the turns it decided: the prefix is replayed from the
  log, not re-requested, and the tally it inherits at the fork point is the
  source's bill, not its own. A scripted driver reports nothing rather than
  a zero it did not earn.
- **Reason** (`Tiller.Event.rationale/1`): the driver asks for summarized
  thinking and the session stores what comes back on the turn it explains,
  so the middle pane shows the original's reason for a turn beside each
  branch's reason for what it did instead. It is outside `Tiller.Event.key/1`
  on purpose: two branches that reasoned differently and acted the same are
  the same trajectory. A scripted driver reports none, and the pane says so
  once rather than showing empty boxes.
- **Control band** (`Tiller.Race.noise_floor/2`): with a model deciding each
  turn, everything after the fork point is a fresh sample, so two branches
  that changed nothing can still diverge. A race carries several control
  branches; how far *they* drift is the floor, and only a mutation whose
  effect clears it is *beyond noise* and earns the star. Scripted drivers
  keep the floor at zero, where beyond-noise means what decisive used to.
- **Kill** (`kill_at`): the branch runs the tool at turn N and dies before
  logging it; the supervisor restart resumes it at N (snapshots live in
  `Tiller.State`, branch tool state under `Tiller.ToolStates`) and runs the
  tool again. Log shows it once, world saw it twice.
- **Durable store** (`Tiller.State.Log`): with `config :tiller, state_log:
  path` every event, snapshot and session profile is appended to that file
  and read back at start, so a trajectory outlives the VM that produced it.
  `Tiller.resume_dead/0` then picks up the runs a restart interrupted, the
  same way the supervisor picks up a killed branch. Off by default; dev
  writes `tmp/tiller-state.log`.
  A snapshot holds the driver context, and for a model that is the whole
  conversation, so writing it whole every turn cost the square of the run:
  200 turns over an 80KB context wrote 18MB. Big list elements are stored
  once, content-addressed, and a snapshot names them; a turn writes what
  changed. The same run now writes 200KB, and because the addressing is by
  content, a race stores one copy of the prefix its branches share rather
  than one each.
- **Lab** (`TillerWeb.LabLive`): three panes. Timeline of the recorded run
  on the left (click a turn to pick the fork point), that turn across every
  branch in the middle with the reasoning behind each, and on the right a
  branch-by-turn grid ranked by `Tiller.Race`, the control band it
  measured, and the smallest mutation past that band starred. Fed entirely
  by `Tiller.State.subscribe/1`; nothing polls.
  Phoenix is the only reason the project is no longer dependency-free, and
  it stays out of `lib/tiller`.
- **Driver** (`Tiller.Driver` behaviour): the only seam for "where the next
  action comes from". `Tiller.FakeDriver` scripts a list of actions for
  tests/demos. `Tiller.Driver.LLM` is the real one: the session's whitelist
  becomes the model's tool surface, a `tool_use` block becomes the quoted
  term, and a run ends by calling `done/1`. Three optional callbacks carry
  what a script never needed: `observe/3` hands a result back to the
  driver, `override/3` lets a driver whose context embeds past results
  rewrite the one a `result_override` fork changed, and `rationale/1`
  answers why the turn just decided was decided.
- **Mutation** (`Tiller.Mutation`): the vocabulary of "one thing
  different", plus `sweep/4`, which reads a recorded run and returns every
  mutation that run reaches: one per tool it still uses after the fork
  point, one per replayed turn, one per turn it could die at, and a
  latency, capped (24 by default) by taking from each axis in turn so no
  axis is starved. The lab's Sweep button races the result.
- **Actions** (`Tiller.Actions`): the registry. The grammar *is* the
  capability boundary — an agent can only touch what's in its whitelist.
  Subagents get a smaller whitelist and can't spawn (depth limit).
- **Seed** (`Tiller.Seed`): an MCP stdio client for the
  [open-seed](https://github.com/shaunlmason/open-seed) engine. The `seed_*`
  tools (ready, get, claim, lease-renew, release, transition, evidence,
  comment) call the task port over JSON-RPC; the port's refusals come back
  as `{:refused, envelope}` with their exit class, so contention, a fenced
  token, or an invalid transition are results in the log, not crashes.
  Root sessions hold the worker verbs, subagents only the reads, and
  operator verbs are on no whitelist. Design and the deferred alternatives:
  [docs/designs/open-seed-integration.md](docs/designs/open-seed-integration.md).

### Deliberate limits (upgrade paths)

- Actions are flat MFA terms, no macros/macros-as-prompts. Add when a real
  LLM driver needs composability the whitelist can't express.
- `Tiller.State` is an in-memory list with a per-session index beside it,
  not ETS/Ecto: one process owns every read, so a lab-sized store is fast
  and a very large one would want a table. Subscriptions are a monitored
  pid map in the GenServer, deliberately not `Phoenix.PubSub`, so
  `lib/tiller` stays free of Phoenix.
- One turn per message, no concurrent tool calls within a turn.
  Add `Task.async_stream` when a single turn needs fan-out.
- `spawn_subagent` starts the child and returns; there is no `await` tool
  yet, so a parent cannot use a subagent's result within its own run.
- The durable store is still one file, read whole at start: what it costs
  to open grows with the run, even though what it costs to write no longer
  does. Segment it when a run outgrows memory.
- Sharing is by content, so it holds elements a list still names and ones
  it dropped alike: nothing collects a blob no snapshot references any
  more. A compaction pass is the answer when a lab session runs long
  enough to care.
- Addressing every element costs CPU that serializing the frame in bulk
  did not: a 200-turn run takes 408ms of store time rather than 64ms, and
  writes 399KB rather than 21MB. The right trade while a turn is an API
  call, and the wrong one if a driver ever gets cheap enough that 2ms a
  turn is the bottleneck.
- `Tiller.Driver.LLM` is exercised against `Tiller.FakeMessages`, a
  scripted stand-in for `POST /v1/messages` on Bandit, so the suite needs
  no key and no network. The real API is one opt-in test
  (`TILLER_ANTHROPIC_API_KEY=... mix test --include integration`).
- A turn's reason is the model's own summary, not its raw reasoning: the
  API never returns that. It is also the only thing on an event that no
  fake API can prove, so the live test is what checks that asking for it
  returns anything at all.
- A `result_override` fork strips the thinking blocks after the edited
  turn out of the branch's conversation, because editing a turn
  invalidates them on the API, so that branch plans without the reasoning
  it had. The log keeps the recorded reasons and the pane still shows
  them: the one place the screen says more than the model saw.

## Research

Projects looked at while shaping tiller, with the verdict on each.

- **[lisptc](https://github.com/1hachem/lisptc)**: borrowed. The
  "constrain action output to data in a shared, inspectable store" idea is
  the core of tiller (see The borrowed idea above).
- **[okf-agent-memory](https://github.com/okf-memory/okf-agent-memory)**:
  bookmarked, not adopted. A git-native project memory for coding agents:
  Markdown concepts with YAML frontmatter under `knowledge/`, following
  Google's Open Knowledge Format v0.2, plus a zero-dependency Go binary that
  validates the bundle, runs BM25 search, and exposes six tools over MCP
  (search, show, create, update, relate, validate). It solves cross-session
  knowledge, a different axis from `Tiller.State`, which is per-run
  trajectory state. Not adopted now because tiller has no LLM driver to read
  a memory, it would add a Go binary to a zero-dependency Elixir project, and
  `docs/*.jsonl` already serves as the agent memory for working on tiller.
  The project is very new (bundle dated late August 2026) and its benchmark
  claims against Mem0 and Letta are unlinked, so treat them as marketing.
  Possible future use: wrap `okf search` as a `Tiller.Tools` function once a
  real driver exists. A memory-read tool is a genuinely distinct tool, and
  "what if the agent could not consult memory at turn N" is a clean whitelist
  mutation axis for the butterfly lab.
- **[bb](https://github.com/get-bb/bb)**: looked at, not adopted. A
  TypeScript "agentic IDE": server, host daemon, web and desktop app, and CLI.
  It does not run agents itself; it wraps whichever provider CLI you have
  authenticated (Claude Code, Codex) behind a JSON-RPC bridge over
  stdin/stdout and shows the resulting threads live so you can steer or hand
  them off. Wrong layer for tiller, which is the loop rather than an
  orchestrator of opaque agent processes, and it would bring a Node toolchain
  with native add-ons to a zero-dependency Elixir project. It also does not
  solve the butterfly lab problem: threads are an append-only event stream,
  but there is no fork, no counterfactual replay, and no diff. Its record
  mode writes NDJSON of bridge traffic for parity testing, and its docs say
  deterministic re-execution is not a protocol feature. The one borrowable
  idea is the `thread/delta` vocabulary in
  `docs/provider-bridge-protocol.md`: a small set of semantic timeline events
  (turn.open, turn.boundary, item.open, item.close with a full item shape)
  rather than raw provider traffic. Worth a skim when the attributed event
  store that replaces the bare `{action, result}` list is designed.

## Status

`docs/design.md` MVP and stretch, all five open questions resolved: attributed
event store, async sessions, six tools, replay, fork on all five mutation
axes, concurrent race, first divergence, decisive-mutation ranking, and the
LiveView lab with the branch-by-turn grid, plus the open-seed client and the
`docs/designs/llm-driver.md` MVP: a real driver, so a mutation changes what
the agent decides rather than only which script it replays. Run:

Locally, `mise install` reads `mise.toml`. In Claude Code on the web the
SessionStart hook in `.claude/hooks/session-start.sh` installs prebuilt OTP
and Elixir from builds.hex.pm and fetches deps before the session starts.

```sh
mix deps.get
mix test
mix run -e 'Tiller.Demo.run()'   # the race in the terminal
mix phx.server                   # the lab at http://localhost:4000
```
