defmodule Tiller.Session do
  @moduledoc """
  One GenServer per agent run.

  init opts:
    driver:     a module implementing Tiller.Driver
    ctx:        initial driver context (opaque)
    whitelist:  actions this session may call (root gets spawn_subagent,
                subagents do not; that's the depth limit)
    state:      the Tiller.State module (or any impl of its API)
    id:         session id (binary); defaults to a unique one
    parent_id:  id of the session that spawned or forked this one; nil for root
    parent:     optional pid; gets {:subagent_halted, self, n} on halt
    tool_state: a Tiller.ToolState pid to share (subagents), or a snapshot
                map to start an isolated instance from (forks); default is
                the global instance
    latency:    milliseconds to wait between turns (the latency mutation)
    kill_at:    turn at which the process dies after acting, before logging
                (the kill mutation); see "Kill and resume" below
    mutation:   the Tiller.Mutation this branch carries, for info/1

  Loop: `run/1` casts; each turn is one `:turn` message to self, so the
  process is observable (and mutable) between turns. A turn parks a
  snapshot of the driver context and tool state in `Tiller.State`, asks the
  driver for the next action, evaluates it against the whitelist, appends
  an attributed `Tiller.Event` (with the driver's reason for the action,
  when it has one), and schedules the next turn until `:halt`.
  A tool that crashes becomes data in the log; the driver decides what to
  do with it. `await/2` blocks the caller until the session halts.

  `fork/4` starts a branch from any turn: the branch replays the events up
  to that turn with recorded results (`Tiller.Driver.Replay`), starts from
  the tool state snapshot taken at that turn, and continues with the
  source's driver and context as they were at that turn, or with whatever
  the mutation says instead.

  Kill and resume: when the supervisor restarts a session whose events are
  already in the store, `init/1` resumes it from the snapshot taken before
  the turn that was in flight, with the same id, turn counter and tool
  state. That turn runs again. Its tool already ran once before the kill,
  so the world sees the action twice while the log shows it once. That is
  the at-least-once hazard of supervised agents, and what `kill_at` exists
  to expose. A session that keeps dying in the same turn is resumed at most
  three times, then halted where it stands, so a deterministic crash stays
  one contained failure instead of a restart loop.
  """
  use GenServer

  alias Tiller.{Driver, Event, Mutation, ToolState}
  alias Tiller.Driver.Replay

  @type id :: binary

  @max_resumes 3

  @impl true
  def init(opts) do
    id = Keyword.get_lazy(opts, :id, &unique_id/0)
    Process.put(:tiller_session_id, id)
    state = Keyword.get(opts, :state, Tiller.State)
    whitelist = Keyword.get(opts, :whitelist, Tiller.Actions.root_whitelist())
    # A driver runs in this process; this is how it can offer exactly what
    # the session would allow (Tiller.Session.current_whitelist/0).
    Process.put(:tiller_session_whitelist, whitelist)

    s = %{
      id: id,
      parent_id: Keyword.get(opts, :parent_id),
      driver: Keyword.fetch!(opts, :driver),
      ctx: Keyword.fetch!(opts, :ctx),
      whitelist: whitelist,
      state: state,
      parent: Keyword.get(opts, :parent),
      latency: Keyword.get(opts, :latency, 0),
      kill_at: Keyword.get(opts, :kill_at),
      mutation: Keyword.get(opts, :mutation),
      turns: 0,
      status: :idle,
      forks: 0,
      resumed: false
    }

    # What bringing this session back needs beyond a snapshot: a snapshot
    # holds the driver's context and the world, not which driver.
    state.put_profile(id, %{
      driver: s.driver,
      parent_id: s.parent_id,
      whitelist: s.whitelist,
      latency: s.latency,
      kill_at: s.kill_at,
      mutation: s.mutation
    })

    tool_opt = Keyword.get(opts, :tool_state)

    case resume_point(state, id) do
      :fresh ->
        ToolState.bind(tool_state(id, tool_opt))
        {:ok, s}

      {:halted, n} ->
        ToolState.bind(tool_state(id, tool_opt))
        {:ok, %{s | turns: n, status: {:halted, n}}}

      {:resume, turn, snap} ->
        ToolState.bind(resume_tool_state(id, tool_opt, snap))
        s = %{s | ctx: snap.ctx, turns: turn, status: :running, resumed: true}

        if state.bump_resumes(id) > @max_resumes do
          # A branch that keeps dying at the same turn stops here, and the
          # log says why rather than just ending.
          {:ok, halt(s, :max_resumes)}
        else
          send(self(), :turn)
          {:ok, s}
        end
    end
  end

  # A restart with events already in the store is a resume, not a fresh run.
  defp resume_point(state, id) do
    case state.events(id) do
      [] ->
        :fresh

      events ->
        case List.last(events) do
          %Event{action: :halt, result: r} ->
            {:halted, Event.halted_turns(r)}

          _ ->
            turn = length(events)

            case state.snapshot(id, turn) do
              {:ok, snap} -> {:resume, turn, snap}
              :error -> :fresh
            end
        end
    end
  end

  defp tool_state(_id, nil), do: ToolState
  defp tool_state(_id, agent) when is_pid(agent) or is_atom(agent), do: agent

  defp tool_state(id, %{} = snapshot) do
    name = tool_state_name(id)

    case DynamicSupervisor.start_child(
           Tiller.ToolStates,
           {ToolState, initial: snapshot, name: name}
         ) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # On resume a branch keeps its surviving world (side effects included);
  # only if that is gone does it fall back to the snapshot.
  defp resume_tool_state(id, %{} = _opt, snap) do
    case GenServer.whereis(tool_state_name(id)) do
      pid when is_pid(pid) -> pid
      nil -> tool_state(id, snap.tool_state)
    end
  end

  defp resume_tool_state(id, opt, _snap), do: tool_state(id, opt)

  defp tool_state_name(id), do: {:via, Registry, {Tiller.Registry, {:tool_state, id}}}

  defp unique_id, do: "s" <> Integer.to_string(System.unique_integer([:positive]))

  @doc "Start the session (under a supervisor or standalone). Registers its id."
  def start_link(opts) do
    id = Keyword.get_lazy(opts, :id, &unique_id/0)
    start_registered(Keyword.put(opts, :id, id), 50)
  end

  # After a kill the Registry may not have dropped the old entry yet when
  # the supervisor restarts us; give it a few milliseconds.
  defp start_registered(opts, tries) do
    case GenServer.start_link(__MODULE__, opts, name: via(opts[:id])) do
      {:error, {:already_started, pid}} = err when tries > 0 ->
        if Process.alive?(pid) do
          err
        else
          Process.sleep(2)
          start_registered(opts, tries - 1)
        end

      other ->
        other
    end
  end

  @doc "Child spec for supervised sessions (used by spawn_subagent and fork)."
  def child_spec(opts) when is_list(opts) do
    %{id: Keyword.get(opts, :id, make_ref()), start: {__MODULE__, :start_link, [opts]}}
  end

  defp via(id), do: {:via, Registry, {Tiller.Registry, id}}

  @doc "Look up a running session by id."
  @spec whereis(id) :: pid | nil
  def whereis(id), do: GenServer.whereis(via(id))

  @doc "The id of a running session's pid."
  @spec id_of(pid) :: {:ok, id} | {:error, :noproc}
  def id_of(pid) do
    case Registry.keys(Tiller.Registry, pid) do
      [id | _] -> {:ok, id}
      [] -> {:error, :noproc}
    end
  end

  @doc "The id of the session the calling process is running in, if any."
  @spec current_id() :: id | nil
  def current_id, do: Process.get(:tiller_session_id)

  @doc "The turn the calling session is executing, if any."
  @spec current_turn() :: non_neg_integer | nil
  def current_turn, do: Process.get(:tiller_session_turn)

  @doc """
  The whitelist of the session the calling process is running in.

  A driver runs inside the session process, so this is how one that
  builds a tool surface (`Tiller.Driver.LLM`) offers exactly what the
  session would allow. It is what makes a `{:whitelist, list}` mutation
  literally a different tools array in the request, rather than a
  refusal after the model has already chosen.
  """
  @spec current_whitelist() :: [{atom, arity}] | nil
  def current_whitelist, do: Process.get(:tiller_session_whitelist)

  @doc "Start the loop. Returns immediately; the run proceeds one turn per message."
  @spec run(pid | id) :: :ok
  def run(pid) when is_pid(pid), do: GenServer.cast(pid, :run)
  def run(id) when is_binary(id), do: GenServer.cast(via(id), :run)

  @doc """
  Block until the session halts. Built on the event store's subscription,
  so it survives the session being killed and resumed under a new pid.
  """
  @spec await(pid | id, timeout) :: {:halted, non_neg_integer} | {:error, :timeout | :noproc}
  def await(pid_or_id, timeout \\ 5_000) do
    with {:ok, id} <- resolve_id(pid_or_id) do
      Tiller.State.subscribe(id)

      result =
        case List.last(Tiller.State.events(id)) do
          %Event{action: :halt, result: r} ->
            {:halted, Event.halted_turns(r)}

          _ ->
            receive do
              {:tiller_event, %Event{session_id: ^id, action: :halt, result: r}} ->
                {:halted, Event.halted_turns(r)}
            after
              timeout -> {:error, :timeout}
            end
        end

      Tiller.State.unsubscribe(id)
      flush(id)
      result
    end
  end

  # Drop the session's other events that the subscription delivered to us.
  defp flush(id) do
    receive do
      {:tiller_event, %Event{session_id: ^id}} -> flush(id)
    after
      0 -> :ok
    end
  end

  defp resolve_id(id) when is_binary(id), do: {:ok, id}
  defp resolve_id(pid) when is_pid(pid), do: id_of(pid)

  @doc """
  Start a session again that the store knows but no process is running:
  one the VM was restarted out from under, or a branch whose supervisor
  gave up.

  It comes back the way a supervisor restart brings one back, from the
  snapshot taken before the turn that was in flight, so nothing recorded
  is lost and the turn that never finished runs again.

  Refused for a session that is already running, that has halted, that
  the store has no profile for, or that has no snapshot at the turn it
  stopped on.
  """
  @spec resume(id) :: {:ok, pid} | {:error, :alive | :halted | :unknown | :no_resume_point}
  def resume(id) do
    cond do
      halted?(id) ->
        {:error, :halted}

      whereis(id) ->
        {:error, :alive}

      true ->
        case Tiller.State.profile(id) do
          {:ok, profile} -> start_from(id, profile)
          :error -> {:error, :unknown}
        end
    end
  end

  defp start_from(id, profile) do
    turn = length(Tiller.State.events(id))

    case Tiller.State.snapshot(id, turn) do
      :error ->
        {:error, :no_resume_point}

      {:ok, snap} ->
        opts = [
          id: id,
          # init reads the context back from the snapshot; there is no
          # live one to hand it.
          ctx: nil,
          driver: profile.driver,
          parent_id: profile.parent_id,
          whitelist: profile.whitelist,
          latency: profile.latency,
          kill_at: profile.kill_at,
          mutation: profile.mutation,
          # The world as this run left it. A supervisor restart finds the
          # global tool state still holding the run's effects; a VM
          # restart does not, so the snapshot is the only copy.
          tool_state: snap.tool_state
        ]

        DynamicSupervisor.start_child(
          Application.fetch_env!(:tiller, :supervisor),
          child_spec(opts)
        )
    end
  end

  defp halted?(id) do
    case List.last(Tiller.State.events(id)) do
      %Event{action: :halt} -> true
      _ -> false
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
  def handle_call(:info, _from, s) do
    info =
      s
      |> Map.take([:id, :parent_id, :mutation, :turns, :status, :latency, :kill_at, :resumed])
      |> Map.put(:usage, Tiller.Driver.usage(s.driver, s.ctx))

    {:reply, info, s}
  end

  def handle_call({:fork, turn, mutation, opts}, _from, s) do
    with {:ok, mutation} <- validate_mutation(mutation),
         {:ok, snapshot} <- s.state.snapshot(s.id, turn) |> or_error({:no_snapshot, turn}),
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

  # The prefix replays the new result; a driver whose context embeds past
  # results (a conversation) rewrites its own copy through override/3.
  defp plan({:result_override, at, result}, turn, {driver, dctx}) when at < turn,
    do:
      {:ok, {driver, Driver.override(driver, dctx, at, result)}, [overrides: %{at => result}], []}

  defp plan({:result_override, at, _}, turn, _same),
    do: {:error, {:override_outside_prefix, at, turn}}

  defp plan({:kill_at, at}, turn, same) when at >= turn, do: {:ok, same, [], kill_at: at}
  defp plan({:kill_at, at}, turn, _same), do: {:error, {:kill_inside_prefix, at, turn}}

  @impl true
  def handle_info(:turn, %{status: :running} = s) do
    snapshot(s)

    case s.driver.next_action(s.ctx) do
      :halt ->
        {:noreply, halt(s, nil)}

      # A driver that gave up says why, and the reason is in the log.
      {:halt, reason} ->
        {:noreply, halt(s, reason)}

      {:action, a, ctx} ->
        Process.put(:tiller_session_turn, s.turns)
        result = Tiller.Actions.eval(a, s.whitelist)
        maybe_die(s)
        record(s, a, result, ctx)

      # Recorded prefix: the result is injected, the tool is not run.
      {:replay, a, result, ctx} ->
        record(s, a, result, ctx)
    end
  end

  # A subagent finished; its trajectory is in State under its own id.
  def handle_info({:subagent_halted, _pid, _n}, s), do: {:noreply, s}
  def handle_info(_other, s), do: {:noreply, s}

  # What a fork or a resume at this turn needs: the driver context and the
  # world as they were before this turn's action ran.
  defp snapshot(s) do
    s.state.snapshot(s.id, s.turns, %{ctx: s.ctx, tool_state: ToolState.snapshot()})
  end

  # The kill mutation: the tool has run, the event has not been logged, and
  # the process is gone. The supervisor's restart resumes at this turn.
  defp maybe_die(%{kill_at: at, turns: at, resumed: false}), do: Process.exit(self(), :kill)
  defp maybe_die(_s), do: :ok

  defp record(s, action, result, ctx) do
    # Asked before observe/3, which is about the next turn: this is why
    # the driver chose the action being recorded, and a driver that reads
    # a script has nothing to say.
    rationale = Driver.rationale(s.driver, ctx)

    # How a result reaches the driver: scripted drivers ignore it, a model
    # needs it to choose the next action. This comes first, so the snapshot
    # below holds the context the next turn actually starts from: snapshot
    # the unobserved one and a resumed model loses the result it was
    # answering.
    ctx = Driver.observe(s.driver, ctx, action, result)
    s = %{s | ctx: ctx, turns: s.turns + 1}

    # The event and the next turn's starting point go in together. Parking
    # the snapshot covers a process that dies in the gap between turns,
    # which is where a VM restart usually catches one; writing it with the
    # event means a crash cannot leave the event durable with no point to
    # resume from. The turn handler parks it again with the same values.
    {:ok, _event} =
      s.state.append(s.id, s.parent_id, s.turns - 1, action, result, %{
        rationale: rationale,
        snapshot: %{ctx: ctx, tool_state: ToolState.snapshot()}
      })

    schedule_turn(s)
    {:noreply, s}
  end

  defp schedule_turn(%{latency: 0}), do: send(self(), :turn)
  defp schedule_turn(%{latency: ms}), do: Process.send_after(self(), :turn, ms)

  defp halt(s, reason) do
    {:ok, _event} =
      s.state.append(s.id, s.parent_id, s.turns, :halt, Event.halted(s.turns, reason))

    if s.parent, do: send(s.parent, {:subagent_halted, self(), s.turns})
    %{s | status: {:halted, s.turns}}
  end
end
