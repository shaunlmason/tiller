# tiller

A small agentic harness for Elixir. One loop, two modes: a session you drive
interactively, or a session that spawns supervised subagents. Subagents are
not a mode — they're a tool (`spawn_subagent`) in the parent's whitelist.

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
├─ Tiller.State            ← attributed event store (seq, session, parent, turn)
├─ Session (root)          ← you drive; tools: echo, spawn_subagent, seed_*
│   └─ Session (subagent)  ← LLM/fake-driven; smaller whitelist, no spawn
└─ Session (other tasks)
```

- **Session** (`Tiller.Session`): one GenServer per run, one turn per
  message. `run/1` is a cast; each turn asks the driver for the next action,
  evaluates it against the whitelist, appends a `Tiller.Event`, and schedules
  the next turn, so the process is observable between turns. `await/2`
  blocks on the halt event via `State.subscribe/1`. Crashes are contained: a
  tool that raises becomes `{:error, _}` in the log; a subagent runs
  concurrently under the supervisor and its parent keeps taking turns.
- **State** (`Tiller.State`): every session's every turn as a `Tiller.Event`
  with a global monotonic `seq`. `events(id)` is one trajectory;
  `Enum.take(events(id), n)` is the state at turn n, which is why forking
  needs no checkpointer. `subscribe(id | :all)` delivers each event live.
- **Divergence** (`Tiller.Divergence`): where two trajectories first part
  ways. A prefix walk with a normalizing equality (pids, refs, and stack
  traces are not divergence). The go/no-go spike for
  [the butterfly lab](docs/designs/agent-butterfly-lab.md); it passed.
- **Fork and race** (`Tiller.Session.fork/4`, `Tiller.Lab.race/4`): fork a
  session at any turn under one mutation (`whitelist`, `driver`,
  `result_override`, `latency`), re-live the prefix through
  `Tiller.Driver.Replay` with recorded results injected and nothing
  re-executed, then run live. `race/4` forks N branches, runs them
  concurrently, and reports each one's first divergence from the parent.
- **Driver** (`Tiller.Driver` behaviour): the only seam for "where the next
  action comes from". `Tiller.FakeDriver` scripts a list of actions for
  tests/demos. A real LLM driver (grammar-constrained decode → quoted term)
  plugs in here with no other changes.
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
- `Tiller.State` is in-memory, not ETS/Ecto. Add persistence when you need
  replay across restarts.
- One turn per message; no concurrent tool calls within a turn. Add
  `Task.async_stream` when a single turn needs fan-out. Sessions themselves
  run concurrently.
- No real LLM driver yet. The FakeDriver is the contract. A real one
  implements `next_action/1` and, to be forkable, `resume_ctx/2`.
- The `kill_at` mutation is refused: a supervisor restart replays the
  child's initial arguments, which is a duplicate branch, not a resume
  (design open question 5).

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

Foundation for the butterfly lab: attributed event store, async sessions,
`await/2`, divergence analysis, and the open-seed client. Run:

```sh
mix test
mix run -e 'Tiller.Demo.run()'          # root + subagent, a contained crash
mix run -e 'Tiller.Demo.butterfly()'    # one run forked five ways at turn 1, raced, compared
```

Against a real open-seed repo (one you instantiated from the template, with
its `scripts/seed` shim and a ready card):

```sh
mix run -e 'Tiller.Demo.seed("os-<id>", cd: "../my-seed-repo", actor: "tiller-1")'
```

The integration test builds a throwaway repo on the engine's local SQLite
backend and drives the real `seed mcp serve`:

```sh
test/support/seed_fixture.sh ../open-seed /path/to/seed /tmp/seed-fixture
TILLER_SEED_CMD="/path/to/seed mcp serve" TILLER_SEED_DIR=/tmp/seed-fixture \
  mix test --include integration
```
