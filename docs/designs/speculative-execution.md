# Design: Speculative execution for agents

Date: 2026-09-10
Repo: tiller
Status: IDEA (not approved; a research write-up, not a build plan)
Mode: Research

## One sentence

Fork an agent's whole world before a risky step, run many futures to
completion, commit the one that worked, and the others never happened.

## Problem Statement

An agent today is one trajectory. It reads, decides, acts, and if the
action was wrong the world already changed: the file is edited, the
command ran, the ticket moved. Every harness in the field mitigates this
the same way, with approval prompts, allowlists, and a human reading the
transcript afterwards. None of them can try the step first.

The pieces that would let an agent try the step first have all arrived in
the last year, in separate projects that do not talk to each other:

- The log is the state. Anthropic's managed agents, Google's Agent
  Executor (AX), Exo, and tiller all keep an append-only event log and
  rebuild a session from it.
- The world can be snapshotted. Agent Substrate suspends an actor's RAM
  and filesystem and resumes it in under a second. E2B, Daytona, and
  Tensorlake snapshot sandboxes.
- Branching exists as a feature. AX offers trajectory branching from a
  checkpoint. Pi's session tree lets a user go back and try again.

What nobody has built is the combination: a fork of the world that fans
out, a way to run the branches concurrently, a selector that picks a
winner for a reason, and a rule for which steps to fork before. That
combination changes what an agent is, from one trajectory to a search
over trajectories, and every layer above it gets more reliable without
changing its code.

## What Makes This Cool

- **The mistake never happened.** A branch that failed is discarded with
  its side effects. Undo for agents that actually undoes.
- **Reliability becomes a dial.** Spend more branches on the steps that
  matter and fewer on the ones that do not. pass^k rises with compute
  instead of with prompt engineering.
- **Every fork is an experiment.** Branches with nothing changed are the
  controls, so the runtime measures its own noise floor as a byproduct,
  and the corpus of measured counterfactuals grows for free.
- **Nobody sees branches.** Users see an agent that stops making the
  mistake. Pi, Junie, Paperclip, and AX all benefit as-is.
- **The labs already do this for text.** Best-of-N sampling is routine
  for tokens. Nobody does it for actions, because actions touch a world
  and worlds do not fork. That is the gap.

## Premises

1. World snapshots are about to be cheap. Substrate and the sandbox
   vendors are racing on suspend and resume; fan-out is one step past
   what they ship.
2. The prefix is free. Everything before the fork point is replayed from
   the log with recorded results, not re-run, so N branches do not cost
   N full runs. tiller's replay driver already does this.
3. Selection needs a noise floor. Two branches with nothing changed still
   diverge, so a selector that picks the best ending without controls
   picks luck. tiller's race already carries controls.
4. Some actions cannot be forked. Sending an email happens once. The
   runtime must know which actions are irreversible and fork before them,
   never after.
5. Compute keeps getting cheaper and agent mistakes keep getting more
   expensive. The trade moves in this idea's favour every quarter.

## The stack, and who holds each piece

| Layer | What it owns | Who has it today |
| --- | --- | --- |
| World | Sandbox lifecycle, snapshot, restore | Agent Substrate, E2B, Daytona, Tensorlake |
| Session | Event log, single writer, resume, branch | AX, Anthropic managed agents, Exo, tiller |
| Loop | Prompt, tools, model, turn | Pi, Junie, Claude Code, Codex, Antigravity |
| Organisation | Who does what, budgets, goals | Paperclip, Symphony, Gas Town |
| Selection | Which future to keep, and why | tiller only, on toy worlds |

The fork primitive (one snapshot restored into N actors at once) belongs
to the World layer and nobody ships it. The selector belongs to a layer
that does not exist yet.

## Recommended Approach

Four parts. The first is the hard one and the last is the one tiller
already has.

### 1. fork() for worlds

One snapshot, N actors, copy-on-write, in milliseconds. Substrate's
snapshot is a file of RAM and disk; restoring it into twenty workers is
not the advertised path but is not obviously blocked either. The
git-sized version, one worktree per branch with a commit per turn, is
enough for coding tasks and is what tiller should build first.

### 2. Run

Branches run concurrently under a supervisor, each with its own world
and its own copy of the log. The prefix before the fork point is replayed
from recorded results. Each branch runs to a checkable ending: a test
passes, a verifier accepts, or the agent calls done.

### 3. Select

Given N finished branches plus K controls:

- Grade the ending, not the path. (Anthropic's evals guidance; tiller's
  decisive rule.)
- Measure how far the controls drift from each other. That is the noise
  floor. (tiller's `Tiller.Race.noise_floor/2`.)
- A branch wins only if it clears the floor. Among winners, prefer the
  one whose trajectory diverged least and latest from the parent, and
  the cheapest.
- Keep the loser's log and the model's own reason on both sides. That is
  the audit trail and the training signal.

### 4. Commit, and know when to fork

The winning branch's world becomes the real one. The runtime keeps a
table of irreversible actions (network sends, external writes, money)
and forks before any turn that would take one. Reversible turns (file
edits, local commands) can fork lazily, on failure. This table is the
same shape as tiller's whitelist: a per-action property the harness
declares rather than the model decides.

## Products it throws off

In order of how soon each sells:

1. **Undo.** The failed branch is discarded with its side effects.
   Every team running agents against real systems wants this now.
2. **Reliability as a dial.** Per-step branch budget. A knob a buyer
   understands and pays for.
3. **The improvement loop.** Every fork is a measured counterfactual, so
   harness changes get gated on a corpus of them, with controls. This is
   what Meta-Harness, auto-harness, and Agentic Harness Engineering do
   today with noisy full re-runs.

## What tiller contributes, and what it does not

Contributes: the selector (`Tiller.Race`, `Tiller.Divergence`, the
control band), prefix replay (`Tiller.Driver.Replay`), the mutation
vocabulary as the list of things a branch can vary, the reason-per-turn
capture, cost billed to decided turns, and the lab as the demo. This is
the only part of the idea with a claim to being an idea rather than an
engineering budget.

Does not contribute: the fork primitive, sandboxing, providers, or a
loop anyone uses. Those are deep infrastructure in languages the field
uses, and the field has already chosen the VM as the unit of isolation,
which the BEAM cannot snapshot.

## Constraints and risks

- **Deep infrastructure.** The fork primitive is a systems project, not a
  weekend. It sits in Go and Kubernetes, next to Substrate, or inside a
  sandbox vendor.
- **A lab could internalise it.** Best-of-N for actions inside a model
  provider's own runtime is the obvious move. That is also the signal
  the idea is big.
- **Twenty branches is real money** until fork and prefix replay are
  cheap. Early versions fork only before irreversible steps.
- **Irreversibility is a judgment.** The table of what cannot be undone
  must be declared per tool. Getting it wrong sends the email twice.
- **Selection can be gamed by the verifier.** A branch that passes a weak
  test is not a branch that did the task. Grade with the strongest
  verifier available and keep humans on the loop where there is none.

## Open Questions

1. Can a Substrate snapshot be restored into N actors concurrently, and
   at what cost per fork? This decides whether the world layer exists
   yet or has to be built.
2. What is the right branch budget policy? Fixed per step, adaptive on
   disagreement between branches, or triggered by a confidence signal
   from the model?
3. How are branches compared when their endings are all different and
   all pass? Divergence distance from the parent is tiller's answer;
   it may not be the buyer's.
4. What does the audit trail look like to a user who never sees a
   branch? Probably: this step was tried N ways, this one was kept,
   here is why.

## Success Criteria

For a spike, not a product:

- A coding task in a worktree world forks at one turn into eight
  branches plus three controls, runs concurrently, and the selector
  commits a branch that passes the task's test where the unforked run
  did not.
- The cost of the eight branches is reported and is less than eight
  full runs because of prefix replay.
- The three controls produce a non-zero noise floor and at least one
  branch clears it.

## Next Steps

1. The world-as-worktree spike from the current plan: worktree per
   branch, commit per turn, fork at turn twenty, measure the cost.
2. Read, write, edit, and bash tools scoped to the worktree; a
   Terminal-Bench style task with a verifier as the ending.
3. Mark tools irreversible or not in `Tiller.Actions`, and fork before
   irreversible ones.
4. A selector that commits: today `Tiller.Race` ranks and the lab
   shows; it has never chosen a branch and made it the parent's world.
5. Ask Substrate's maintainers open question 1 before building anything
   above the worktree.

## Naming

Tiller stays the name of the repo and the instrument. A tiller is the
lever on a rudder, which fits the harness; in grasses, tillering is one
plant sending up many stems from a shared crown and keeping the ones
that make it, which fits the fork-and-race lab exactly. The README now
owns both readings.

If the speculative-execution product ever exists it wants its own name,
and the honest vocabulary is the CPU's, where the idea comes from: a
processor predicts a branch, executes ahead, retires the instructions
that were right, and squashes the ones that were not.

- **Squash**: what happens to the futures that lose. A verb, and the
  promise is in it: the mistake is squashed, not undone. Preferred.
- **Retire**: the CPU's word for committing a result. Quieter; says the
  kept branch is the one that finished.
- **Tillering**: keeps the lineage if the product stays inside this
  repo's story.

Recommendation: Squash for a product, Tiller for the lab that proves it.

## Research

- [Agent Substrate](https://github.com/agent-substrate/substrate): suspend
  and resume with full-state snapshots, 250 actors on 8 pods.
- [Google AX](https://github.com/google/ax): event log, single writer,
  trajectory branching from checkpoints, one branch at a time.
- [Anthropic managed agents](https://www.anthropic.com/engineering/managed-agents):
  session log decoupled from harness and sandbox.
- [Anthropic on infrastructure noise](https://www.anthropic.com/engineering/infrastructure-noise):
  6 points of Terminal-Bench 2 from resource limits alone; distrust
  differences under 3.
- [Anthropic on agent evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents):
  isolate every trial, grade outcomes not paths, pass@k against pass^k.
- [Exo](https://github.com/exoharness/exo): substrate and executor split,
  state is a version of the log.
- [Pi](https://github.com/badlogic/pi-mono): session tree with parent
  pointers, branch summaries, steering.
- [Meta-Harness](https://github.com/stanford-iris-lab/meta-harness),
  [auto-harness](https://github.com/neosigmaai/auto-harness),
  [Agentic Harness Engineering](https://github.com/china-qijizhifeng/agentic-harness-engineering):
  harness optimisation loops gated on full re-runs, the customers for a
  measured counterfactual.
- [awesome-agent-harness](https://github.com/Picrew/awesome-agent-harness):
  the map; no entry does fan-out, race, or a noise floor.
