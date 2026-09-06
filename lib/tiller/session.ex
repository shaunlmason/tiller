defmodule Tiller.Session do
  @moduledoc """
  One GenServer per agent run.

  init opts:
    driver:     a module implementing Tiller.Driver
    ctx:        initial driver context (opaque)
    whitelist:  actions this session may call (root gets spawn_subagent,
                subagents do not; that's the depth limit)
    state:      the Tiller.State module (or any {append/5, events/1} impl)
    id:         session id (binary); defaults to a unique one
    parent_id:  id of the session that spawned or forked this one; nil for root
    parent:     optional pid; gets {:subagent_halted, self, n} on halt
    tool_state: a Tiller.ToolState pid to share (subagents), or a snapshot
                map to start an isolated instance from (forks); default is
                the global instance
    latency:    milliseconds to wait between turns (the latency mutation)
    mutation:   the Tiller.Mutation this branch carries, for info/1

  Loop: `run/1` casts; each turn is one `:turn` message to self, so the
  process is observable (and mutable) between turns. A turn snapshots the
  driver context and tool state, asks the driver for the next action,
  evaluates it against the whitelist, appends an attributed `Tiller.Event`,
  and schedules the next turn until `:halt`. A tool that crashes becomes
  data in the log; the driver decides what to do with it. `await/2` blocks
  the caller until the session halts.

  `fork/4` starts a branch from any turn: the branch replays the events up
  to that turn with recorded results (`Tiller.Driver.Replay`), starts from
  the tool state snapshot taken at that turn, and continues with the
  source's driver and context as they were at that turn, or with whatever
  the mutation says instead.
  """
  use GenServer

  alias Tiller.{Mutation, ToolState}
  alias Tiller.Driver.Replay

  @type id :: binary

  @impl true
  def init(opts) do
    id = Keyword.get_lazy(opts, :id, &unique_id/0)
    Process.put(:tiller_session_id, id)
    ToolState.bind(tool_state(Keyword.get(opts, :tool_state)))

    {:ok,
     %{
       id: id,
       parent_id: Keyword.get(opts, :parent_id),
       driver: Keyword.fetch!(opts, :driver),
       ctx: Keyword.fetch!(opts, :ctx),
       whitelist: Keyword.get(opts, :whitelist, Tiller.Actions.root_whitelist()),
       state: Keyword.get(opts, :state, Tiller.State),
       parent: Keyword.get(opts, :parent),
       latency: Keyword.get(opts, :latency, 0),
       mutation: Keyword.get(opts, :mutation),
       turns: 0,
       status: :idle,
       waiters: [],
       snapshots: %{},
       forks: 0
     }}
  end

  defp tool_state(nil), do: ToolState

  defp tool_state(agent) when is_pid(agent) or is_atom(agent), do: agent

  defp tool_state(%{} = snapshot) do
    {:ok, pid} = ToolState.start_link(initial: snapshot)
    pid
  end

  defp unique_id, do: "s" <> Integer.to_string(System.unique_integer([:positive]))

  @doc "Start the session (under a supervisor or standalone). Registers its id."
  def start_link(opts) do
    id = Keyword.get_lazy(opts, :id, &unique_id/0)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :id, id), name: via(id))
  end

  @doc "Child spec for supervised sessions (used by spawn_subagent and fork)."
  def child_spec(opts) when is_list(opts) do
    %{id: Keyword.get(opts, :id, make_ref()), start: {__MODULE__, :start_link, [opts]}}
  end

  defp via(id), do: {:via, Registry, {Tiller.Registry, id}}

  @doc "Look up a running session by id."
  @spec whereis(id) :: pid | nil
  def whereis(id), do: GenServer.whereis(via(id))

  @doc "The id of the session the calling process is running in, if any."
  @spec current_id() :: id | nil
  def current_id, do: Process.get(:tiller_session_id)

  @doc "Start the loop. Returns immediately; the run proceeds one turn per message."
  @spec run(pid | id) :: :ok
  def run(pid) when is_pid(pid), do: GenServer.cast(pid, :run)
  def run(id) when is_binary(id), do: GenServer.cast(via(id), :run)

  @doc "Block until the session halts. Built on a halt notification, not a sleep."
  @spec await(pid | id, timeout) :: {:halted, non_neg_integer} | {:error, :timeout}
  def await(pid_or_id, timeout \\ 5_000) do
    try do
      GenServer.call(target(pid_or_id), :await, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  @doc "Id, ancestry, mutation, turn and status of a session."
  @spec info(pid | id) :: map
  def info(pid_or_id), do: GenServer.call(target(pid_or_id), :info)

  @doc """
  Fork a branch from `turn` under Tiller's supervisor, with one mutation
  (or `nil` for a control branch that should reproduce the source). The
  branch is started but not run, so the caller can subscribe first.

  Options: `:id` (default `"<source>@<turn>.<n>"`), `:state`.
  """
  @spec fork(pid | id, non_neg_integer, Mutation.t() | nil, keyword) ::
          {:ok, pid} | {:error, term}
  def fork(pid_or_id, turn, mutation, opts \\ []) do
    GenServer.call(target(pid_or_id), {:fork, turn, mutation, opts})
  end

  defp target(pid) when is_pid(pid), do: pid
  defp target(id) when is_binary(id), do: via(id)

  @impl true
  def handle_cast(:run, %{status: :idle} = s) do
    send(self(), :turn)
    {:noreply, %{s | status: :running}}
  end

  def handle_cast(:run, s), do: {:noreply, s}

  @impl true
  def handle_call(:await, _from, %{status: {:halted, n}} = s), do: {:reply, {:halted, n}, s}
  def handle_call(:await, from, s), do: {:noreply, %{s | waiters: [from | s.waiters]}}

  def handle_call(:info, _from, s) do
    {:reply, Map.take(s, [:id, :parent_id, :mutation, :turns, :status, :latency]), s}
  end

  def handle_call({:fork, turn, mutation, opts}, _from, s) do
    with {:ok, mutation} <- validate_mutation(mutation),
         {:ok, snapshot} <- Map.fetch(s.snapshots, turn) |> or_error({:no_snapshot, turn}),
         {:ok, branch_opts} <- branch_opts(s, turn, mutation, snapshot, opts) do
      sup = Application.fetch_env!(:tiller, :supervisor)

      case DynamicSupervisor.start_child(sup, child_spec(branch_opts)) do
        {:ok, pid} -> {:reply, {:ok, pid}, %{s | forks: s.forks + 1}}
        {:error, reason} -> {:reply, {:error, reason}, s}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  defp validate_mutation(nil), do: {:ok, nil}
  defp validate_mutation(m), do: Mutation.validate(m)

  defp or_error({:ok, v}, _reason), do: {:ok, v}
  defp or_error(:error, reason), do: {:error, reason}

  # Translate a mutation into the branch's session options. The prefix is
  # always replayed; the mutation decides what happens from `turn` on.
  defp branch_opts(s, turn, mutation, snapshot, opts) do
    events = s.state.events(s.id)
    id = Keyword.get(opts, :id, "#{s.id}@#{turn}.#{s.forks}")

    base = [
      id: id,
      parent_id: s.id,
      state: Keyword.get(opts, :state, s.state),
      whitelist: s.whitelist,
      tool_state: snapshot.tool_state,
      latency: s.latency,
      mutation: mutation
    ]

    same_driver = {s.driver, snapshot.ctx}

    with {:ok, {delegate, dctx}, replay_opts, extra} <- plan(mutation, turn, same_driver) do
      ctx = Replay.context(events, delegate, dctx, [turn: turn] ++ replay_opts)
      {:ok, Keyword.merge(base, [driver: Replay, ctx: ctx] ++ extra)}
    end
  end

  defp plan(nil, _turn, same), do: {:ok, same, [], []}
  defp plan({:whitelist, list}, _turn, same), do: {:ok, same, [], whitelist: list}
  defp plan({:driver, mod, ctx}, _turn, _same), do: {:ok, {mod, ctx}, [], []}
  defp plan({:latency, ms}, _turn, same), do: {:ok, same, [], latency: ms}

  defp plan({:result_override, at, result}, turn, same) when at < turn,
    do: {:ok, same, [overrides: %{at => result}], []}

  defp plan({:result_override, at, _}, turn, _same),
    do: {:error, {:override_outside_prefix, at, turn}}

  # Open Question 5: a supervisor restart is a duplicate, not a resume.
  defp plan({:kill_at, _}, _turn, _same), do: {:error, {:unsupported, :kill_at}}

  @impl true
  def handle_info(:turn, %{status: :running} = s) do
    s = snapshot(s)

    case s.driver.next_action(s.ctx) do
      :halt ->
        {:noreply, halt(s)}

      {:action, a, ctx} ->
        record(s, a, Tiller.Actions.eval(a, s.whitelist), ctx)

      # Recorded prefix: the result is injected, the tool is not run.
      {:replay, a, result, ctx} ->
        record(s, a, result, ctx)
    end
  end

  # A subagent finished; its trajectory is in State under its own id.
  def handle_info({:subagent_halted, _pid, _n}, s), do: {:noreply, s}
  def handle_info(_other, s), do: {:noreply, s}

  # What a fork at this turn needs: the driver context and the world as they
  # were before this turn's action ran.
  defp snapshot(s) do
    snap = %{ctx: s.ctx, tool_state: ToolState.snapshot()}
    %{s | snapshots: Map.put(s.snapshots, s.turns, snap)}
  end

  defp record(s, action, result, ctx) do
    {:ok, _event} = s.state.append(s.id, s.parent_id, s.turns, action, result)
    schedule_turn(s)
    {:noreply, %{s | ctx: ctx, turns: s.turns + 1}}
  end

  defp schedule_turn(%{latency: 0}), do: send(self(), :turn)
  defp schedule_turn(%{latency: ms}), do: Process.send_after(self(), :turn, ms)

  defp halt(s) do
    {:ok, _event} = s.state.append(s.id, s.parent_id, s.turns, :halt, {:halted, s.turns})
    if s.parent, do: send(s.parent, {:subagent_halted, self(), s.turns})
    for from <- s.waiters, do: GenServer.reply(from, {:halted, s.turns})
    %{s | status: {:halted, s.turns}, waiters: []}
  end
end
