defmodule Tiller.Actions do
  @moduledoc """
  Action registry. The whitelist *is* the capability boundary: an agent can
  only call what its session's whitelist allows. Subagents get a smaller
  whitelist and never get `spawn_subagent` (depth limit).
  """

  # Tools every session gets. Each has an observable side effect or a
  # distinct failure mode, so mutating one branch's whitelist or result
  # changes what later turns can do.
  @base_tools [
    {:echo, 1},
    {:fail, 0},
    {:put, 2},
    {:get, 1},
    {:spend, 1},
    {:flaky, 1},
    {:sleep, 1}
  ]

  @root_tools @base_tools ++ [{:spawn_subagent, 2}]
  @sub_tools @base_tools

  def root_whitelist, do: @root_tools
  def sub_whitelist, do: @sub_tools

  @doc """
  Evaluate a quoted MFA action `{:call, m, f, args}` against a whitelist.
  Returns {:ok, result} | {:error, reason} — never raises.

  A tool returns `{:ok, value}` or `{:error, reason}`, which pass through
  unchanged, or a bare value, which is wrapped as `{:ok, value}`. A tool
  that hands back arbitrary stored data (`get/1`) must use the explicit
  `{:ok, _}` form so a stored `{:error, _}` is not mistaken for a refusal.
  A crash (raise/throw/exit) is captured with its stacktrace as
  `{:error, {kind, reason, stacktrace}}`.
  """
  def eval({:call, _m, f, args}, whitelist) do
    if Enum.member?(whitelist, {f, length(args)}) do
      try do
        case apply(Tiller.Tools, f, args) do
          {:ok, _} = ok -> ok
          {:error, _} = err -> err
          value -> {:ok, value}
        end
      catch
        kind, reason -> {:error, {kind, reason, __STACKTRACE__}}
      end
    else
      {:error, :not_whitelisted}
    end
  end

  def eval(other, _whitelist), do: {:error, {:bad_action, other}}
end

defmodule Tiller.Tools do
  @moduledoc """
  The actual tools.

  Failure modes are deliberately distinct so a counterfactual has something
  to bite on:

    * `echo/1`  no side effect, never fails
    * `fail/0`  always crashes
    * `put/2`, `get/1`  a key-value store; `get` of a missing key refuses
    * `spend/1` a depleting budget; overspending refuses without depleting
    * `flaky/1` crashes on every third call, stateful across the run
    * `sleep/1` succeeds slowly, so branches finish at different times
  """

  alias Tiller.ToolState

  @sleep_cap_ms 1_000

  def echo(value), do: "echo: #{inspect(value)}"
  def fail(), do: raise("simulated tool crash")

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
    sup = Application.fetch_env!(:tiller, :supervisor)
    parent_id = Tiller.Session.current_id()
    turn = Tiller.Session.current_turn()
    child_id = child_id(parent_id, turn)

    spec =
      Tiller.Session.child_spec(
        id: child_id,
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
        {:subagent_started, turn}

      {:error, {:already_started, _pid}} ->
        {:subagent_started, turn}

      {:error, reason} ->
        {:subagent_failed, reason}
    end
  end

  # Deterministic child ids: "<parent>.<turn>". Outside a session there is
  # no turn, so fall back to a unique id.
  defp child_id(nil, _turn), do: "s" <> Integer.to_string(System.unique_integer([:positive]))
  defp child_id(parent_id, turn), do: parent_id <> "." <> Integer.to_string(turn)
end
