defmodule Tiller.Session do
  @moduledoc """
  One GenServer per agent run, one turn per message.

  init opts:
    driver:    a module implementing Tiller.Driver
    ctx:       initial driver context (opaque)
    whitelist: actions this session may call (root gets spawn_subagent,
               subagents do not: that is the depth limit)
    id:        session id (default: a fresh unique "s-<n>")
    parent_id: the spawning or forked-from session's id, nil for a root
    parent:    optional pid; gets {:subagent_halted, self, n} on halt
    latency:   ms to wait before each live turn (default 0): the latency axis
    kill_at:   brutally kill this process before executing turn N (the
               kill_at axis); under the supervisor it comes back resumed

  `run/1` is a cast: each turn is its own message (ask the driver ->
  evaluate against the whitelist -> append the event -> schedule the next
  turn), so the process answers `info/1` and can be inspected, forked, or
  killed between turns. `await/2` blocks the caller until the session (or
  whatever session resumed it) halts. A tool that crashes becomes data in
  the log; the driver decides what to do with it.

  ## Restart is resume (open question 5)

  A session writes its packet to `Tiller.State` at start: the driver it
  runs on, that driver's initial context, its whitelist, latency, and
  lineage. Its events are the rest of the packet. When a supervised
  session is killed, the supervisor restarts it with the same start
  arguments, and `init/1` finds the packet already there: instead of
  starting over it starts a *new* session, `<id>/r<n>`, forked from the
  dead one at the turn it died, replaying the dead one's events through
  `Tiller.Driver.Replay` and resuming the driver with `resume_ctx/2`. The
  dead session's packet records `resumed_by`, so `await/2` follows the
  chain. Nothing recorded is lost and nothing recorded is re-executed:
  that is the packet-resume drill, passed by construction.
  """
  use GenServer

  alias Tiller.{Event, State}

  @type status :: :idle | :running | :halted

  @registry Tiller.Session.Registry

  ## API

  @doc "The id registry; started by the application."
  def registry_spec, do: {Registry, keys: :unique, name: @registry}

  @doc "The pid of the live session with this id, or nil."
  def whereis(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Start the session (under a supervisor or standalone)."
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    if name, do: GenServer.start_link(__MODULE__, opts, name: name), else: GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Child spec for supervised sessions. `restart:` defaults to `:temporary`;
  `:transient` makes a killed session come back resumed (see the moduledoc).
  """
  def child_spec(opts) when is_list(opts) do
    {restart, opts} = Keyword.pop(opts, :restart, :temporary)
    %{id: Keyword.get(opts, :child_id, make_ref()), start: {__MODULE__, :start_link, [opts]}, restart: restart}
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

  @doc "id, parent_id, turns, status, driver, initial_ctx, whitelist, fork_turn, mutation, latency, kill_at."
  def info(pid), do: GenServer.call(pid, :info)

  @doc """
  Block until the session halts: `{:halted, turns}` or `{:error, :timeout}`.
  Takes a pid or an id. If the session is killed and resumed (see the
  moduledoc), the wait follows the resumed session; the turn count is the
  final session's. Built on `State.subscribe/1`, never on a sleep.
  """
  @spec await(pid | term, timeout) :: {:halted, non_neg_integer} | {:error, :timeout | :dead}
  def await(target, timeout \\ 5_000)

  def await(pid, timeout) when is_pid(pid) do
    case safe_id(pid) do
      nil -> {:error, :dead}
      id -> await(id, timeout)
    end
  end

  def await(id, timeout) do
    :ok = State.subscribe(:all)
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      wait(id, deadline)
    after
      State.unsubscribe(:all)
      flush()
    end
  end

  @doc "Run and await in one call: the synchronous shape tests and demos want."
  def run_to_halt(pid, timeout \\ 5_000) do
    :ok = run(pid)
    await(pid, timeout)
  end

  @doc "The last session in `id`'s resume chain (itself when never resumed)."
  def final(id) do
    case State.get_session(id) do
      %{resumed_by: next} when not is_nil(next) -> final(next)
      _ -> id
    end
  end

  @doc "`id` and every session that resumed it, in order."
  def lineage(id) do
    case State.get_session(id) do
      %{resumed_by: next} when not is_nil(next) -> [id | lineage(next)]
      _ -> [id]
    end
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
    * `{:kill_at, t}`: the parent's driver, killed before turn `t` (>= `turn`)
      and resumed by the supervisor from its own log (see the moduledoc)

  Options: `id:` (default `"<parent>/f<turn>-<n>"`). Returns `{:ok, pid}`;
  call `run/1` (or `Tiller.Lab.race/4`) to start it.
  """
  @spec fork(pid, non_neg_integer, Tiller.Mutation.t(), keyword) :: {:ok, pid} | {:error, term}
  def fork(pid, turn, mutation, opts \\ []) do
    %{id: parent_id, driver: driver, initial_ctx: initial, whitelist: wl, turns: turns} = info(pid)

    with :ok <- check_fork(turn, turns, mutation) do
      prefix = State.events(parent_id) |> Enum.reject(&match?(%Event{action: :halt}, &1)) |> Enum.take(turn)

      {delegate, dctx, whitelist, overrides, latency, kill_at} =
        case mutation do
          {:whitelist, new_wl} -> {driver, initial, new_wl, [], 0, nil}
          {:driver, mod, ctx} -> {mod, ctx, wl, [], 0, nil}
          {:result_override, t, r} -> {driver, initial, wl, [{t, r}], 0, nil}
          {:latency, ms} -> {driver, initial, wl, [], ms, nil}
          {:kill_at, t} -> {driver, initial, wl, [], 0, t}
        end

      spec =
        child_spec(
          id: Keyword.get_lazy(opts, :id, fn -> "#{parent_id}/f#{turn}-#{System.unique_integer([:positive, :monotonic])}" end),
          parent_id: parent_id,
          driver: Tiller.Driver.Replay,
          ctx: Tiller.Driver.Replay.context(prefix, delegate, dctx, overrides: overrides),
          whitelist: whitelist,
          latency: latency,
          kill_at: kill_at,
          fork_turn: turn,
          mutation: mutation,
          # a kill must come back: transient restarts on an abnormal exit
          restart: if(kill_at, do: :transient, else: :temporary)
        )

      DynamicSupervisor.start_child(Application.fetch_env!(:tiller, :supervisor), spec)
    end
  end

  defp check_fork(turn, _turns, {:kill_at, t}) when t < turn, do: {:error, {:kill_before_fork, t, turn}}

  defp check_fork(turn, _turns, {:result_override, t, _}) when t >= turn,
    do: {:error, {:override_outside_prefix, t, turn}}

  defp check_fork(turn, turns, _mutation) when turn > turns, do: {:error, {:turn_beyond_log, turn, turns}}
  defp check_fork(_turn, _turns, _mutation), do: :ok

  ## await internals

  defp safe_id(pid) do
    id(pid)
  catch
    :exit, _ -> nil
  end

  defp wait(id, deadline) do
    cond do
      n = halted_turns(id) ->
        {:halted, n}

      next = resumed_by(id) ->
        wait(next, deadline)

      true ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:tiller_event, %Event{session_id: ^id, action: :halt, result: {:halted, n}}} ->
            {:halted, n}

          {:tiller_event, %Event{parent_id: ^id, session_id: sid}} ->
            # a child appeared: a resume of this session, or an ordinary fork or subagent
            if resumed_from(sid) == id, do: wait(sid, deadline), else: wait(id, deadline)

          {:tiller_event, _} ->
            wait(id, deadline)
        after
          remaining -> {:error, :timeout}
        end
    end
  end

  defp halted_turns(id) do
    case Enum.find(State.events(id), &match?(%Event{action: :halt}, &1)) do
      %Event{result: {:halted, n}} -> n
      nil -> nil
    end
  end

  defp resumed_by(id), do: get_in(State.get_session(id) || %{}, [:resumed_by])
  defp resumed_from(id), do: get_in(State.get_session(id) || %{}, [:resumed_from])

  defp flush do
    receive do
      {:tiller_event, _} -> flush()
    after
      0 -> :ok
    end
  end

  ## Server

  @impl true
  def init(opts) do
    id = Keyword.get_lazy(opts, :id, fn -> "s-#{System.unique_integer([:positive, :monotonic])}" end)

    case State.get_session(id) do
      nil -> init_fresh(id, opts)
      _packet -> init_resumed(id)
    end
  end

  defp init_fresh(id, opts) do
    driver = Keyword.fetch!(opts, :driver)
    ctx = Keyword.fetch!(opts, :ctx)

    # the driver a resume must come back on: for a replay-driven fork,
    # the delegate underneath, since the prefix will be re-read from events
    {origin_driver, origin_ctx} =
      case {driver, ctx} do
        {Tiller.Driver.Replay, %{delegate: d, delegate_ctx: c}} -> {d, c}
        other -> other
      end

    s = %{
      id: id,
      parent_id: Keyword.get(opts, :parent_id),
      driver: driver,
      ctx: ctx,
      initial_ctx: ctx,
      whitelist: Keyword.get(opts, :whitelist, Tiller.Actions.root_whitelist()),
      parent: Keyword.get(opts, :parent),
      latency: Keyword.get(opts, :latency, 0),
      kill_at: Keyword.get(opts, :kill_at),
      fork_turn: Keyword.get(opts, :fork_turn),
      mutation: Keyword.get(opts, :mutation),
      resumed_from: Keyword.get(opts, :resumed_from),
      turns: 0,
      status: :idle
    }

    State.put_session(id, %{
      parent_id: s.parent_id,
      origin_driver: origin_driver,
      origin_ctx: origin_ctx,
      whitelist: s.whitelist,
      latency: s.latency,
      kill_at: s.kill_at,
      fork_turn: s.fork_turn,
      mutation: s.mutation,
      resumed_from: s.resumed_from,
      resumed_by: nil
    })

    register(id)
    {:ok, s}
  end

  # The supervisor restarted a session whose packet exists: resume the
  # last session in its chain as a new session forked at the death turn.
  defp init_resumed(id) do
    dead = final(id)
    packet = State.get_session(dead)
    prefix = State.events(dead) |> Enum.reject(&match?(%Event{action: :halt}, &1))
    new_id = "#{dead}/r#{System.unique_integer([:positive, :monotonic])}"
    State.update_session(dead, &Map.put(&1, :resumed_by, new_id))

    {:ok, s} =
      init_fresh(new_id,
        parent_id: dead,
        driver: Tiller.Driver.Replay,
        ctx: Tiller.Driver.Replay.context(prefix, packet.origin_driver, packet.origin_ctx),
        whitelist: packet.whitelist,
        latency: packet.latency,
        fork_turn: length(prefix),
        mutation: {:resumed, length(prefix)},
        resumed_from: dead
      )

    # a resumed session runs at once: nobody else knows its pid to cast run/1
    send(self(), :turn)
    {:ok, %{s | status: :running}}
  end

  defp register(id) do
    Process.put(:tiller_session_id, id)
    # a reused id (a stale session still alive) is not fatal: whereis/1 then finds the older one
    _ = Registry.register(@registry, id, nil)
  end

  @impl true
  def handle_call(:id, _from, s), do: {:reply, s.id, s}

  def handle_call(:info, _from, s) do
    {:reply,
     Map.take(s, [
       :id,
       :parent_id,
       :turns,
       :status,
       :driver,
       :initial_ctx,
       :whitelist,
       :fork_turn,
       :mutation,
       :latency,
       :kill_at,
       :resumed_from
     ]), s}
  end

  @impl true
  def handle_cast(:run, %{status: :idle} = s) do
    schedule_turn(s)
    {:noreply, %{s | status: :running}}
  end

  def handle_cast(:run, s), do: {:noreply, s}

  @impl true
  def handle_info(:turn, %{status: :running, kill_at: k, turns: k} = _s) when is_integer(k) do
    # the kill_at axis: die before executing turn k, the way a real
    # executor dies: nothing recorded, nothing cleaned up
    Process.exit(self(), :kill)
  end

  def handle_info(:turn, %{status: :running} = s) do
    case s.driver.next_action(s.ctx) do
      :halt ->
        State.append(s.id, s.parent_id, s.turns, :halt, {:halted, s.turns})
        if s.parent, do: send(s.parent, {:subagent_halted, self(), s.turns})
        {:noreply, %{s | status: :halted}}

      {:action, a, ctx} ->
        result = Tiller.Actions.eval(a, s.whitelist)
        {:ok, ev} = State.append(s.id, s.parent_id, s.turns, a, result)
        schedule_turn(s)
        {:noreply, %{s | ctx: Tiller.Driver.observe(s.driver, ctx, ev), turns: s.turns + 1}}

      {:replay, a, result, ctx} ->
        # the driver already knows the answer: record it, run nothing
        {:ok, ev} = State.append(s.id, s.parent_id, s.turns, a, result, :replay)
        send(self(), :turn)
        {:noreply, %{s | ctx: Tiller.Driver.observe(s.driver, ctx, ev), turns: s.turns + 1}}
    end
  end

  def handle_info(:turn, s), do: {:noreply, s}

  def handle_info({:subagent_halted, _pid, _n}, s), do: {:noreply, s}

  defp schedule_turn(%{latency: 0}), do: send(self(), :turn)
  defp schedule_turn(%{latency: ms}), do: Process.send_after(self(), :turn, ms)
end
