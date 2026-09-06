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
- **Kill** (`kill_at`): the branch runs the tool at turn N and dies before
  logging it; the supervisor restart resumes it at N (snapshots live in
  `Tiller.State`, branch tool state under `Tiller.ToolStates`) and runs the
  tool again. Log shows it once, world saw it twice.
- **Lab** (`TillerWeb.LabLive`): three panes. Timeline of the recorded run
  on the left (click a turn to pick the fork point), that turn across every
  branch in the middle, and on the right a branch-by-turn grid ranked by
  `Tiller.Race` with the smallest decisive mutation starred. Fed entirely by
  `Tiller.State.subscribe/1`; nothing polls.
  Phoenix is the only reason the project is no longer dependency-free, and
  it stays out of `lib/tiller`.
- **Driver** (`Tiller.Driver` behaviour): the only seam for "where the next
  action comes from". `Tiller.FakeDriver` scripts a list of actions for
  tests/demos. A real LLM driver (grammar-constrained decode → quoted term)
  plugs in here with no other changes.
- **Actions** (`Tiller.Actions`): the registry. The grammar *is* the
  capability boundary — an agent can only touch what's in its whitelist.
  Subagents get a smaller whitelist and can't spawn (depth limit).

### Deliberate limits (upgrade paths)

- Actions are flat MFA terms, no macros/macros-as-prompts. Add when a real
  LLM driver needs composability the whitelist can't express.
- `Tiller.State` is an in-memory list, not ETS/Ecto. Add persistence when
  you need replay across restarts. Subscriptions are a pid map in the
  GenServer; swap in `Phoenix.PubSub` when LiveView arrives.
- One turn per message, no concurrent tool calls within a turn.
  Add `Task.async_stream` when a single turn needs fan-out.
- `spawn_subagent` starts the child and returns; there is no `await` tool
  yet, so a parent cannot use a subagent's result within its own run.
- No real LLM driver yet. The FakeDriver is the contract.

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

## Status

`docs/design.md` MVP and stretch, all five open questions resolved: attributed
event store, async sessions, six tools, replay, fork on all five mutation
axes, concurrent race, first divergence, decisive-mutation ranking, and the
LiveView lab with the branch-by-turn grid. Run:

```sh
mix deps.get
mix test
mix run -e 'Tiller.Demo.run()'   # the race in the terminal
mix phx.server                   # the lab at http://localhost:4000
```
