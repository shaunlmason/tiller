defmodule Tiller.State do
  @moduledoc """
  Ordered, attributed event store shared by every session.

  Every action + result from every session (root, subagent, future forks)
  lands here as a `Tiller.Event` with a globally monotonic `seq`. It is the
  audit trail, the replay log, and the source of the next prompt: one thing,
  three jobs. Per-session views come from filtering on `session_id`.

  Subscribers get `{:tiller_event, event}` for every append to the session
  they subscribed to (or `:all`). This is what `Tiller.Session.await/2` and
  the lab build on instead of sleeping or polling.

  Sessions also park a per-turn snapshot here (driver context and tool
  state as they were before the turn ran). Keeping it outside the session
  process is what lets a killed session resume and a fork start from any
  turn of a session that is no longer alive.

  In memory, newest first internally so append is O(1), with a per-session
  index beside the global list so reading one branch out of a race does
  not walk every other branch's turns. With `config :tiller, state_log:
  path` (or `TILLER_STATE_LOG`) every write is also appended to that file
  (`Tiller.State.Log`) and the store is rebuilt from it at start, so a
  trajectory outlives the VM that produced it and
  `Tiller.Session.resume/1` can pick a run back up where it stopped. The
  log shares what does not change between turns rather than writing the
  driver context again each time; see `Tiller.State.Log`.
  """
  use GenServer

  alias Tiller.Event

  @doc "Child spec for supervisors."
  def child_spec(_opts \\ []), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], Keyword.put(opts, :name, __MODULE__))
  end

  @doc """
  The log path this store would start with: `TILLER_STATE_LOG` when it is
  set, else `config :tiller, :state_log`, else none.

  The environment wins so a configured default (dev writes one) can be
  redirected, or turned off with an empty value, without editing config.
  """
  @spec configured_log_path() :: Path.t() | nil
  def configured_log_path do
    case System.get_env("TILLER_STATE_LOG") do
      nil -> Application.get_env(:tiller, :state_log)
      "" -> nil
      path -> path
    end
  end

  @impl true
  def init(_), do: {:ok, load(configured_log_path())}

  defp initial(path \\ nil, log \\ nil) do
    %{
      seq: 0,
      events: [],
      # the same events, per session and newest first: what every read but
      # `events/0` actually wants
      by_session: %{},
      subs: %{},
      snapshots: %{},
      resumes: %{},
      profiles: %{},
      path: path,
      log: log
    }
  end

  # The store a log file describes, or an empty one when there is no log.
  defp load(nil), do: initial()

  defp load(path) do
    {frames, log} = Tiller.State.Log.restore(path)

    s =
      Enum.reduce(frames, initial(path), fn
        {:event, %Event{} = e}, s -> %{put_event(s, e) | seq: max(s.seq, e.seq)}
        {:snapshot, id, turn, snap}, s -> put_snapshot(s, id, turn, snap)
        {:profile, id, profile}, s -> %{s | profiles: Map.put(s.profiles, id, profile)}
        {:resumes, id, n}, s -> %{s | resumes: Map.put(s.resumes, id, n)}
        _unknown, s -> s
      end)

    %{s | log: log}
  end

  # Both views of an event: the global order and the session's own.
  defp put_event(s, %Event{session_id: id} = e) do
    %{
      s
      | events: [e | s.events],
        by_session: Map.update(s.by_session, id, [e], &[e | &1])
    }
  end

  # The handle remembers what the file already holds, so writing returns a
  # new one rather than nothing.
  defp record(s, frame), do: record_all(s, [frame])

  defp record_all(%{log: nil} = s, _frames), do: s

  defp record_all(%{log: log} = s, frames),
    do: %{s | log: Tiller.State.Log.append_all(log, frames)}

  defp put_snapshot(s, id, turn, snap) do
    update_in(
      s.snapshots,
      &Map.update(&1, id, %{turn => snap}, fn m -> Map.put(m, turn, snap) end)
    )
  end

  @doc """
  Append an attributed event. Returns the stored event with its `seq`.

  `extra` carries what the session knows about the turn beyond the action
  and its result:

    * `:snapshot` parks the following turn's starting point in the same
      write. The two belong together: an event durable without the
      snapshot that follows it leaves a run with no point to resume from,
      so a crash between them must not be possible.
    * `:rationale` is why the driver chose the action, when it can say.
  """
  @spec append(
          binary,
          binary | nil,
          non_neg_integer,
          Event.action() | :halt,
          Event.result(),
          %{optional(:snapshot) => map, optional(:rationale) => binary | nil}
        ) :: {:ok, Event.t()}
  def append(session_id, parent_id, turn, action, result, extra \\ %{}) do
    GenServer.call(
      __MODULE__,
      {:append, session_id, parent_id, turn, action, result, extra}
    )
  end

  @doc "Every session the store knows, from its events or its profile."
  @spec sessions() :: [binary]
  def sessions, do: GenServer.call(__MODULE__, :sessions)

  @doc "All events, oldest first."
  @spec events() :: [Event.t()]
  def events, do: GenServer.call(__MODULE__, {:events, :all})

  @doc "One session's events, oldest first."
  @spec events(binary) :: [Event.t()]
  def events(session_id), do: GenServer.call(__MODULE__, {:events, session_id})

  @doc "Receive `{:tiller_event, event}` for every append to `session_id` (or `:all`)."
  @spec subscribe(binary | :all) :: :ok
  def subscribe(session_id), do: GenServer.call(__MODULE__, {:subscribe, session_id, self()})

  @doc "Stop receiving events for `session_id` (or `:all`)."
  @spec unsubscribe(binary | :all) :: :ok
  def unsubscribe(session_id), do: GenServer.call(__MODULE__, {:unsubscribe, session_id, self()})

  @doc "Park the state a session had before `turn` ran: `%{ctx: term, tool_state: map}`."
  @spec snapshot(binary, non_neg_integer, map) :: :ok
  def snapshot(session_id, turn, snap),
    do: GenServer.call(__MODULE__, {:snapshot, session_id, turn, snap})

  @doc "The snapshot taken before `turn` of `session_id`, if any."
  @spec snapshot(binary, non_neg_integer) :: {:ok, map} | :error
  def snapshot(session_id, turn), do: GenServer.call(__MODULE__, {:snapshot, session_id, turn})

  @doc """
  Remember how to start `id` again: the driver module and the options
  that are not in a snapshot.

  A snapshot carries the driver's context and the world, but not which
  driver, so this is the missing half of bringing a session back in a VM
  that never ran it.
  """
  @spec put_profile(binary, map) :: :ok
  def put_profile(id, profile), do: GenServer.call(__MODULE__, {:put_profile, id, profile})

  @doc "How `id` was started, if the store knows."
  @spec profile(binary) :: {:ok, map} | :error
  def profile(id), do: GenServer.call(__MODULE__, {:profile, id})

  @doc """
  Re-read the store from the log at `path` (`nil` for memory only).

  What a restart does, callable directly, which is how the persistence
  tests avoid restarting a VM.
  """
  @spec reopen(Path.t() | nil) :: :ok
  def reopen(path), do: GenServer.call(__MODULE__, {:reopen, path})

  @doc "The log file in use, or nil."
  @spec log_path() :: Path.t() | nil
  def log_path, do: GenServer.call(__MODULE__, :log_path)

  @doc "Count a resume of `session_id` (a supervisor restart mid-run). Returns the new count."
  @spec bump_resumes(binary) :: pos_integer
  def bump_resumes(session_id), do: GenServer.call(__MODULE__, {:bump_resumes, session_id})

  @doc """
  Reset (tests, demo). Drops events, snapshots and subscriptions. Every
  subscriber is told with `{:tiller_reset}` so it can resubscribe.
  """
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def handle_call({:append, session_id, parent_id, turn, action, result, extra}, _from, s) do
    seq = s.seq + 1

    event = %Event{
      seq: seq,
      session_id: session_id,
      parent_id: parent_id,
      turn: turn,
      action: action,
      result: result,
      rationale: Map.get(extra, :rationale)
    }

    for pid <- Map.get(s.subs, session_id, []) ++ Map.get(s.subs, :all, []) do
      send(pid, {:tiller_event, event})
    end

    s =
      case Map.get(extra, :snapshot) do
        nil ->
          record(s, {:event, event})

        snap ->
          # one write, so a crash cannot land between them
          s
          |> record_all([{:event, event}, {:snapshot, session_id, turn + 1, snap}])
          |> put_snapshot(session_id, turn + 1, snap)
      end

    {:reply, {:ok, event}, %{put_event(s, event) | seq: seq}}
  end

  def handle_call({:events, :all}, _from, s), do: {:reply, Enum.reverse(s.events), s}

  def handle_call({:events, session_id}, _from, s) do
    {:reply, s.by_session |> Map.get(session_id, []) |> Enum.reverse(), s}
  end

  def handle_call({:subscribe, key, pid}, _from, s) do
    pids = Map.get(s.subs, key, [])

    if pid in pids do
      {:reply, :ok, s}
    else
      Process.monitor(pid)
      {:reply, :ok, put_in(s.subs[key], [pid | pids])}
    end
  end

  def handle_call({:unsubscribe, key, pid}, _from, s) do
    {:reply, :ok,
     update_in(s.subs, &Map.update(&1, key, [], fn pids -> List.delete(pids, pid) end))}
  end

  def handle_call({:snapshot, session_id, turn, snap}, _from, s) do
    s = s |> record({:snapshot, session_id, turn, snap}) |> put_snapshot(session_id, turn, snap)
    {:reply, :ok, s}
  end

  def handle_call({:snapshot, session_id, turn}, _from, s) do
    {:reply, s.snapshots |> Map.get(session_id, %{}) |> Map.fetch(turn), s}
  end

  def handle_call({:bump_resumes, session_id}, _from, s) do
    s = update_in(s.resumes, &Map.update(&1, session_id, 1, fn n -> n + 1 end))
    s = record(s, {:resumes, session_id, s.resumes[session_id]})
    {:reply, s.resumes[session_id], s}
  end

  def handle_call({:put_profile, id, profile}, _from, s) do
    s = record(s, {:profile, id, profile})
    {:reply, :ok, %{s | profiles: Map.put(s.profiles, id, profile)}}
  end

  def handle_call({:profile, id}, _from, s), do: {:reply, Map.fetch(s.profiles, id), s}

  def handle_call({:reopen, path}, _from, s) do
    if s.log, do: File.close(s.log.io)
    {:reply, :ok, load(path)}
  end

  def handle_call(:log_path, _from, s), do: {:reply, s.path, s}

  def handle_call(:sessions, _from, s) do
    {:reply, Enum.uniq(Map.keys(s.by_session) ++ Map.keys(s.profiles)), s}
  end

  def handle_call(:clear, _from, s) do
    for {_key, pids} <- s.subs, pid <- pids, do: send(pid, {:tiller_reset})
    log = if s.log, do: Tiller.State.Log.truncate(s.log, s.path), else: nil
    {:reply, :ok, initial(s.path, log)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, s) do
    {:noreply, %{s | subs: Map.new(s.subs, fn {k, pids} -> {k, List.delete(pids, pid)} end)}}
  end
end
