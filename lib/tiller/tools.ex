defmodule Tiller.Tools do
  # `spawn/1` here is the delegation tool, not Kernel's process starter.
  import Kernel, except: [spawn: 1]

  @moduledoc """
  The actual tools. Every function here is callable only if `{name, arity}`
  is in the running session's whitelist (`Tiller.Actions`).

  Failure modes are deliberately distinct so a counterfactual has something
  to bite on:

    * `echo/1`  no side effect, never fails
    * `fail/0`  always crashes
    * `put/2`, `get/1`  a key-value store; `get` of a missing key refuses
    * `spend/1` a depleting budget; overspending refuses without depleting
    * `flaky/1` crashes on every third call, stateful across the run
    * `sleep/1` succeeds slowly, so branches finish at different times
    * `done/1`  ends a run by recording its answer, so the answer is an
      action two trajectories can be compared on
    * `spawn/1`, `await/1`  delegate a goal to a subagent and wait for
      what it finished with. A parent can use a child's answer in its own
      run, which is what makes a subagent a tool rather than a spectacle
    * `seed_*` talk to the open-seed engine through `Tiller.Seed`; a
      refused verb is `{:refused, envelope}`, a result, not a crash, so
      the log records exactly which exit class the port returned (2
      contention, 3 invalid transition, 6 fenced out, ...). A dead engine
      is a transport error, contained like any tool crash.
  """

  alias Tiller.ToolState

  @sleep_cap_ms 1_000

  def echo(value), do: "echo: #{inspect(value)}"
  def fail(), do: raise("simulated tool crash")

  @doc """
  Finish the run: record the final answer as an action.

  A driver that has nothing left to do calls this, so `Tiller.Race`
  compares runs on where they ended rather than on the last incidental
  tool call. The session halts on the turn after.
  """
  def done(summary), do: {:done, summary}

  @doc "Store a value. Later turns can `get` it."
  def put(key, value) do
    ToolState.put(key, value)
    {:put, key}
  end

  @doc "Read a stored value as `{:ok, value}`, or refuse with `{:error, :not_found}`."
  def get(key) do
    case ToolState.fetch(key) do
      {:ok, _} = ok -> ok
      :error -> {:error, :not_found}
    end
  end

  @doc "Spend from a fixed budget. Returns the remainder or `{:error, :budget_exceeded}`."
  def spend(n) do
    case ToolState.spend(n) do
      {:ok, remaining} -> {:remaining, remaining}
      {:error, _} = e -> e
    end
  end

  @doc "Returns `value`, except every third call across the run raises."
  def flaky(value) do
    case ToolState.flaky_tick() do
      {n, true} -> raise "flaky: call #{n} failed"
      {_n, false} -> value
    end
  end

  @doc "Sleep for `ms` (capped at #{@sleep_cap_ms}) and return how long it slept."
  def sleep(ms) when is_integer(ms) and ms >= 0 do
    slept = min(ms, @sleep_cap_ms)
    Process.sleep(slept)
    {:slept, slept}
  end

  @doc """
  Spawn a subagent under Tiller's supervisor (crash-isolated) and start it.
  Returns immediately with `{:subagent_started, turn}`; the child's id is
  `"<parent id>.<turn>"`, its trajectory lands in `Tiller.State` under that
  id with this session as `parent_id`, and the parent receives
  `{:subagent_halted, pid, turns}` when it halts. The result names the turn
  rather than the id so a fork's spawn compares equal to the original's.
  Re-running the turn after a kill finds the child already started and
  reports the same. A failure to start is contained: the caller gets
  {:subagent_failed, reason}.
  """
  def spawn_subagent(driver, ctx) do
    case start_child(driver, ctx) do
      {:ok, turn} -> {:subagent_started, turn}
      {:error, reason} -> {:subagent_failed, reason}
    end
  end

  @doc """
  Delegate `goal` to a subagent and return the handle to wait on it with:
  `{:spawned, turn}`, where `turn` is this turn.

  This is `spawn_subagent/2` in a form a model can call. The child comes
  from the running driver (`Tiller.Driver.subagent/3`): same model, same
  endpoint, a goal instead of a conversation, and the subagent whitelist,
  so it cannot delegate further. A driver that cannot make a child (a
  script pursues no goal it was not given) refuses here rather than
  guessing at one.

  The handle is the turn rather than the child's id for the reason
  `spawn_subagent/2` returns one: a branch's child has a different id
  from its source's, and a run that only differs in the names of things
  is not a run that differs.
  """
  def spawn(goal) when is_binary(goal) do
    case Tiller.Session.current_driver() do
      nil ->
        {:error, :no_session}

      {driver, ctx} ->
        case Tiller.Driver.subagent(driver, ctx, goal) do
          nil -> {:error, :cannot_delegate}
          {mod, child_ctx} -> spawned(start_child(mod, child_ctx))
        end
    end
  end

  defp spawned({:ok, turn}), do: {:ok, {:spawned, turn}}
  defp spawned({:error, reason}), do: {:error, {:spawn_failed, reason}}

  @doc """
  Wait for the subagent spawned at `turn` and return what it finished
  with: its `done` summary, or why it stopped.

  The session handles this one itself rather than running it here: a turn
  that waits must not stop the session answering for itself, so the turn
  is parked until the child halts and recorded then. Reaching this
  function means there was no session to park it.
  """
  def await(turn) when is_integer(turn), do: {:error, :no_session}

  # Start a session under Tiller's supervisor with the subagent whitelist
  # and this session's world. Deterministic id, so re-running the turn
  # after a kill finds the child already started rather than making a
  # second one.
  defp start_child(driver, ctx) do
    sup = Application.fetch_env!(:tiller, :supervisor)
    parent_id = Tiller.Session.current_id()
    turn = Tiller.Session.current_turn()

    spec =
      Tiller.Session.child_spec(
        id: child_id(parent_id, turn),
        parent_id: parent_id,
        parent: self(),
        driver: driver,
        ctx: ctx,
        whitelist: Tiller.Actions.sub_whitelist(),
        tool_state: Tiller.ToolState.current()
      )

    case DynamicSupervisor.start_child(sup, spec) do
      {:ok, pid} ->
        Tiller.Session.run(pid)
        {:ok, turn}

      {:error, {:already_started, _pid}} ->
        {:ok, turn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Deterministic child ids: "<parent>.<turn>". Outside a session there is
  # no turn, so fall back to a unique id.
  defp child_id(nil, _turn), do: "s" <> Integer.to_string(System.unique_integer([:positive]))
  defp child_id(parent_id, turn), do: parent_id <> "." <> Integer.to_string(turn)

  ## open-seed port verbs (read)

  @doc "Claimable cards for this actor."
  def seed_ready(), do: seed("task_ready", %{actor: actor()})

  @doc "One card."
  def seed_get(task), do: seed("task_get", %{task: task})

  ## open-seed port verbs (worker: fenced by the claim token)

  @doc "Claim a ready card with the engine's default lease. The envelope carries `claim_token`."
  def seed_claim(task), do: seed("task_claim", %{task: task, actor: actor()})

  @doc "Claim with an explicit lease, e.g. \"45m\"."
  def seed_claim(task, lease), do: seed("task_claim", %{task: task, actor: actor(), lease: lease})

  @doc "Extend a live claim's lease."
  def seed_lease_renew(task, token),
    do: seed("task_lease_renew", %{task: task, actor: actor(), token: token})

  @doc "Give the claim back without closing the card."
  def seed_release(task, token),
    do: seed("task_release", %{task: task, actor: actor(), token: token})

  @doc "Move a card (e.g. to \"review\")."
  def seed_transition(task, to, token),
    do: seed("task_transition", %{task: task, to: to, actor: actor(), token: token})

  @doc "Move a card to blocked with a blocked_on entry (plan:<pr> | dep:<id> | manual:<op>)."
  def seed_transition(task, to, token, blocked_on),
    do:
      seed("task_transition", %{
        task: task,
        to: to,
        actor: actor(),
        token: token,
        blocked_on: blocked_on
      })

  @doc "Append evidence (kind: log | commit | pr | file)."
  def seed_attach_evidence(task, kind, ref, token),
    do:
      seed("task_attach_evidence", %{
        task: task,
        actor: actor(),
        kind: kind,
        ref: ref,
        token: token
      })

  @doc "Append a comment to a card."
  def seed_comment(task, body, token),
    do: seed("task_comment", %{task: task, actor: actor(), body: body, token: token})

  defp seed(tool, args), do: Tiller.Seed.call(client(), tool, args)
  defp actor(), do: Tiller.Seed.actor(client())

  defp client() do
    Process.whereis(Tiller.Seed) ||
      raise Tiller.Seed.TransportError, reason: :not_started
  end
end
