# Design: open-seed integration

Date: 2026-09-06
Repos: tiller, open-seed, open-seed-engine
Status: APPROVED (option 1 built; options 2 to 4 recorded for later)

## Problem Statement

Three repos, one owner, no seam between them. open-seed and
open-seed-engine are already one system: the template holds the contract
as files (task cards on a `seed-state` ref, the transition table,
guardrails, roles, the loop, a harness adapter contract) and the pinned Go
binary implements it (the task port, claim/lease/fence, receipts, a
workflow engine, an MCP transport). tiller is orthogonal in language and
layer: a small Elixir harness whose driver emits a quoted MFA term, whose
session evaluates it against a whitelist, and whose every action and
result lands in one ordered log.

The open-seed contract is deliberately "files, a CLI, and envelopes, never
a vendor SDK" (SEED-NEXT.md, "Any coding harness staffs any lane"), so an
Elixir harness can plug in without either side changing shape. The
question is where.

## Options

Ranked cheapest first. Option 1 is built; the rest are the backlog.

### 1. tiller as an MCP client of the engine (chosen, built)

Run `scripts/seed mcp serve` from an instantiated open-seed repo and
expose its tools inside `Tiller.Tools` as whitelisted calls: ready, get,
claim, lease-renew, release, transition, attach-evidence, comment.

Why it fits:

- open-seed's load-bearing rule is that only the port touches a store.
  tiller never sees a store; it calls verbs, and the engine applies the
  same fencing, transition table, and envelopes it applies to its own CLI.
- tiller's log records every coordination call as data. A claim, a
  renewal, a contention, a fenced-out token: each is an `{action, result}`
  pair in `Tiller.State`, replayable and forkable like any other turn.
- The whitelist split mirrors the port's own rule that a sub-agent
  inherits its parent's claim. The root session holds the worker verbs;
  a subagent may only read. Operator verbs are on no whitelist at all.
- It answers tiller's own next step (butterfly lab, step 2: "four real
  tools with side effects and distinct failure modes"). The port's exit
  classes are those failure modes for free: 2 contention, 3 invalid
  transition, 4 not found, 6 fenced out. "What if the claim had been
  contended at turn 3" becomes a counterfactual axis with no new code.
- It needs no LLM driver. FakeDriver scripts port calls exactly as it
  scripts echo calls.

What it does not do: it does not make tiller a harness open-seed can
drive (that is option 2), and it does not touch open-seed or the engine.
No mail verbs, because the MCP surface exposes none.

### 2. tiller as an open-seed harness adapter (later)

The contract in `scripts/seed-harness` is small: prompt on stdin, one
JSON envelope on stdout, exit codes 0/1/3/124/127, and `SEED_ROLE`,
`SEED_TASK`, `SEED_PERMISSION`, `SEED_TIMEOUT` in the environment. A
`scripts/harness/tiller` adapter plus a `tiller` entry in the
`[workflows].harnesses` registry in `.seed/config.toml` would let
`loop.sh` and workflow steps drive tiller sessions like they drive
`claude` and `codex`.

tiller can honor the permission tiers (`read-only | safe-edit | yolo`)
more faithfully than most harnesses, because the whitelist already is the
capability boundary: each tier is a whitelist, declared rather than
mapped onto sandbox flags.

Blocked on: a real LLM driver. Until one exists a tiller adapter driven
by FakeDriver duplicates the shipped `scripts/harness/mock`. Do this when
`Tiller.Driver` has a non-fake implementation.

### 3. tiller as Seed's trajectory instrument (later, largest)

SEED-NEXT.md calls for trajectory-prefix regression ("recorded decision
points replay against lane configurations"), packet-resume drills with
randomized executor kills, a simulation mode with mock executors and
zero credentials, and a red-team harness for the compromised-actor
drill. The butterfly lab is that instrument: an event-sourced log, free
fork points, N concurrent branches under a supervisor, first-divergence
reporting.

Two shapes: export tiller's event log in Seed's envelope shape so Seed's
gates can consume it, or run tiller as the simulation or red-team
executor behind Seed's public executor-adapter interface
(`next/executor`).

Blocked on: the butterfly lab foundation (async sessions, attributed
`Tiller.Event`, PubSub), plus persistence, since `Tiller.State` is
in-memory and Seed disposes compute only after durable synchronization.
Option 1 is a prerequisite either way: the port verbs are the boundary
the instrument records.

### 4. open-seed as tiller's project template (reverse direction)

Instantiate open-seed onto tiller itself: AGENTS.md, cards on a
`seed-state` ref, plans, `make check`. tiller's `docs/*.jsonl` memory
files map onto `memory/` and `decisions/`.

Worth it only if multiple agents will work the butterfly lab through
cards. Today tiller is a one-person learning project and the jsonl files
are enough.

## Design of option 1

### Modules

- `Tiller.Seed`: one GenServer, one engine process. Opens `seed mcp
  serve` as an Erlang port (newline-delimited JSON-RPC 2.0, no SDK on
  either side), performs the `initialize` handshake, and multiplexes
  `tools/call` by request id. `call/4` returns `{:ok, envelope}` or
  `{:refused, envelope}`; only transport faults raise
  (`Tiller.Seed.TransportError`), so a session logs them as
  `{:error, _}` exactly like a tool crash.
- `Tiller.Tools.seed_*`: thin, explicit-arity wrappers. The actor is the
  client's; the claim token is a plain argument, because keeping it is
  the driver's job (the port fences every later worker verb on it).
- `Tiller.Actions`: `seed_read_whitelist/0` (ready, get) on both
  sessions; `seed_worker_whitelist/0` (claim, lease_renew, release,
  transition, attach_evidence, comment) on root only.
- `Tiller`: starts the client when `config :tiller, :seed, ...` is set.
  Without it nothing changes and the seed tools fail as data.

### Result shape in the log

```elixir
{{:call, Tiller.Tools, :seed_claim, ["os-1"]},        {:ok, {:ok, %{"claim_token" => "..."}}}}
{{:call, Tiller.Tools, :seed_claim, ["os-1"]},        {:ok, {:refused, %{"error" => "contention", "exit" => 2}}}}
{{:call, Tiller.Tools, :seed_lease_renew, ["os-1", "stale"]}, {:ok, {:refused, %{"error" => "fenced_out", "exit" => 6}}}}
{{:call, Tiller.Tools, :seed_ready, []},              {:error, {:error, %Tiller.Seed.TransportError{reason: :not_started}, _}}}
```

The outer tag is `Tiller.Actions.eval/2`'s (did the tool run); the inner
tag is the port's (did it accept). A refusal is a successful observation
of the port saying no.

### Tests

- `test/seed_test.exs` drives the client and the tools against
  `test/support/fake_seed_mcp.exs`, a scripted server that speaks the
  engine's exact wire format (same four methods, same envelope-in-text
  result shape, same JSON-RPC error for an unknown tool). No engine, no
  repo, runs in `mix test`.
- `test/seed_integration_test.exs` runs the same contract against the
  real engine on the fastcards (local SQLite) backend. Excluded by
  default; `test/support/seed_fixture.sh` builds the throwaway repo.
  Verified 2026-09-06 against open-seed-engine v0.16.0 built from source.

## Deliberately not done

- No operator verbs as tools (accept, reject, close, promote, cancel).
  They are a human's; the engine checks its roster regardless, and
  putting them behind a whitelist would suggest a session could earn them.
- No automatic lease renewal. Renewal is an action the driver emits, so
  "what if the lease had lapsed at turn N" stays a visible turn.
- No changes to open-seed or open-seed-engine. Option 1 needs none.
