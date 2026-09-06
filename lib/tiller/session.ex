defmodule Tiller.Session do
  @moduledoc """
  One GenServer per agent run, one turn per message.

  init opts:
    driver:    a module implementing Tiller.Driver
    ctx:       initial driver context (opaque)
    whitelist: actions this session may call (root gets spawn_subagent,
               subagents do not: that is the depth limit)
    id:        session id (default: a fresh unique "s-<n>")
    parent_id: the spawning session's id, nil for a root
    state:     the Tiller.State module (or any {append/5} impl)
    parent:    optional pid; gets {:subagent_halted, self, n} on halt
    latency:   ms to wait before each turn (default 0): the latency axis

  `run/1` is a cast: each turn is its own message (ask the driver ->
  evaluate against the whitelist -> append the event -> schedule the next
  turn), so the process answers `info/1` and can be inspected, forked, or
  killed between turns. `await/2` blocks the caller until the halt event
  lands in `Tiller.State`; it is built on `State.subscribe/1`, never on a
  sleep. A tool that crashes becomes data in the log; the driver decides
  what to do with it.
  """
  use GenServer

  alias Tiller.Event

  @type status :: :idle | :running | :halted

  ## API

  @doc "Start the session (under a supervisor or standalone)."
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    if name, do: GenServer.start_link(__MODULE__, opts, name: name), else: GenServer.start_link(__MODULE__, opts)
  end

  @doc "Child spec for supervised sessions (used by spawn_subagent)."
  def child_spec(opts) when is_list(opts) do
    %{id: Keyword.get(opts, :child_id, make_ref()), start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc "Start the loop. Returns at once; the turns are messages."
  @spec run(pid) :: :ok
  def run(pid), do: GenServer.cast(pid, :run)

  @doc "The session id."
  def id(pid), do: GenServer.call(pid, :id)

  @doc """
  The id of the session whose turn is executing, from inside a tool. A
  tool runs in the session process, so it cannot `call` it; the id is in
  the process dictionary instead.
  """
  def current_id, do: Process.get(:tiller_session_id)

  @doc "id, parent_id, turns, status."
  def info(pid), do: GenServer.call(pid, :info)

  @doc """
  Block until the session halts: `{:halted, turns}` or `{:error, :timeout}`.
  Subscribes to the session's events first, then checks the store, so a
  halt that already happened is not missed and one that happens after the
  subscription is delivered.
  """
  @spec await(pid, timeout) :: {:halted, non_neg_integer} | {:error, :timeout}
  def await(pid, timeout \\ 5_000) do
    %{id: id, state: state} = info(pid)
    state.subscribe(id)

    try do
      case Enum.find(state.events(id), &match?(%Event{action: :halt}, &1)) do
        %Event{result: {:halted, n}} -> {:halted, n}
        nil -> wait_for_halt(id, timeout)
      end
    after
      state.unsubscribe(id)
      flush(id)
    end
  end

  @doc "Run and await in one call: the synchronous shape tests and demos want."
  def run_to_halt(pid, timeout \\ 5_000) do
    :ok = run(pid)
    await(pid, timeout)
  end

  @doc """
  Fork a session at `turn` under one mutation (butterfly lab, step 8).

  The branch is a new session under `Tiller.Supervisor` whose `parent_id`
  is this session's id. It re-lives this session's first `turn` events
  through `Tiller.Driver.Replay` (recorded results injected, nothing
  re-executed) and then continues live under the mutation:

    * `{:whitelist, wl}`: the parent's driver, resumed at `turn`, under `wl`
    * `{:driver, mod, ctx}`: `mod` takes over at `turn` (its `resume_ctx/2`
      positions `ctx`, or `ctx` is used as supplied)
    * `{:result_override, t, result}`: the parent's driver, with the
      recorded result at replayed turn `t` (< `turn`) replaced
    * `{:latency, ms}`: the parent's driver with `ms` before every live turn
    * `{:kill_at, _}`: not yet (open question 5)

  Options: `id:` (default `"<parent>/f<turn>-<n>"`), `state:`. Returns
  `{:ok, pid}`; call `run/1` (or `Tiller.Lab.race/4`) to start it.
  """
  @spec fork(pid, non_neg_integer, Tiller.Mutation.t(), keyword) :: {:ok, pid} | {:error, term}
  def fork(pid, turn, mutation, opts \\ []) do
    %{id: parent_id, driver: driver, initial_ctx: initial, whitelist: wl, state: state, turns: turns} = info(pid)

    with :ok <- check_fork(turn, turns, mutation) do
      prefix = state.events(parent_id) |> Enum.reject(&match?(%Event{action: :halt}, &1)) |> Enum.take(turn)

      {delegate, dctx, whitelist, overrides, latency} =
        case mutation do
          {:whitelist, new_wl} -> {driver, initial, new_wl, [], 0}
          {:driver, mod, ctx} -> {mod, ctx, wl, [], 0}
          {:result_override, t, r} -> {driver, initial, wl, [{t, r}], 0}
          {:latency, ms} -> {driver, initial, wl, [], ms}
        end

      spec =
        child_spec(
          id: Keyword.get_lazy(opts, :id, fn -> "#{parent_id}/f#{turn}-#{System.unique_integer([:positive, :monotonic])}" end),
          parent_id: parent_id,
          driver: Tiller.Driver.Replay,
          ctx: Tiller.Driver.Replay.context(prefix, delegate, dctx, overrides: overrides),
          whitelist: whitelist,
          latency: latency,
          state: Keyword.get(opts, :state, state),
          fork_turn: turn,
          mutation: mutation
        )

      DynamicSupervisor.start_child(Application.fetch_env!(:tiller, :supervisor), spec)
    end
  end

  defp check_fork(_turn, _turns, {:kill_at, _}), do: {:error, {:unsupported, :kill_at}}

  defp check_fork(turn, _turns, {:result_override, t, _}) when t >= turn,
    do: {:error, {:override_outside_prefix, t, turn}}

  defp check_fork(turn, turns, _mutation) when turn > turns, do: {:error, {:turn_beyond_log, turn, turns}}
  defp check_fork(_turn, _turns, _mutation), do: :ok

  defp wait_for_halt(id, timeout) do
    receive do
      {:tiller_event, %Event{session_id: ^id, action: :halt, result: {:halted, n}}} -> {:halted, n}
      {:tiller_event, %Event{session_id: ^id}} -> wait_for_halt(id, timeout)
    after
      timeout -> {:error, :timeout}
    end
  end

  defp flush(id) do
    receive do
      {:tiller_event, %Event{session_id: ^id}} -> flush(id)
    after
      0 -> :ok
    end
  end

  ## Server

  @impl true
  def init(opts) do
    driver = Keyword.fetch!(opts, :driver)
    ctx = Keyword.fetch!(opts, :ctx)

    id = Keyword.get_lazy(opts, :id, fn -> "s-#{System.unique_integer([:positive, :monotonic])}" end)
    Process.put(:tiller_session_id, id)

    {:ok,
     %{
       id: id,
       parent_id: Keyword.get(opts, :parent_id),
       driver: driver,
       ctx: ctx,
       initial_ctx: ctx,
       whitelist: Keyword.get(opts, :whitelist, Tiller.Actions.root_whitelist()),
       state: Keyword.get(opts, :state, Tiller.State),
       parent: Keyword.get(opts, :parent),
       latency: Keyword.get(opts, :latency, 0),
       fork_turn: Keyword.get(opts, :fork_turn),
       mutation: Keyword.get(opts, :mutation),
       turns: 0,
       status: :idle
     }}
  end

  @impl true
  def handle_call(:id, _from, s), do: {:reply, s.id, s}

  def handle_call(:info, _from, s) do
    {:reply, Map.take(s, [:id, :parent_id, :turns, :status, :state, :driver, :initial_ctx, :whitelist, :fork_turn, :mutation, :latency]), s}
  end

  @impl true
  def handle_cast(:run, %{status: :idle} = s) do
    schedule_turn(s)
    {:noreply, %{s | status: :running}}
  end

  def handle_cast(:run, s), do: {:noreply, s}

  @impl true
  def handle_info(:turn, %{status: :running} = s) do
    case s.driver.next_action(s.ctx) do
      :halt ->
        s.state.append(s.id, s.parent_id, s.turns, :halt, {:halted, s.turns})
        if s.parent, do: send(s.parent, {:subagent_halted, self(), s.turns})
        {:noreply, %{s | status: :halted}}

      {:action, a, ctx} ->
        result = Tiller.Actions.eval(a, s.whitelist)
        s.state.append(s.id, s.parent_id, s.turns, a, result)
        schedule_turn(s)
        {:noreply, %{s | ctx: ctx, turns: s.turns + 1}}

      {:replay, a, result, ctx} ->
        # the driver already knows the answer: record it, run nothing
        s.state.append(s.id, s.parent_id, s.turns, a, result, :replay)
        send(self(), :turn)
        {:noreply, %{s | ctx: ctx, turns: s.turns + 1}}
    end
  end

  def handle_info(:turn, s), do: {:noreply, s}

  def handle_info({:subagent_halted, _pid, _n}, s), do: {:noreply, s}

  defp schedule_turn(%{latency: 0}), do: send(self(), :turn)
  defp schedule_turn(%{latency: ms}), do: Process.send_after(self(), :turn, ms)
end
