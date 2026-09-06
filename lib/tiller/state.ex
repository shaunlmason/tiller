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

  ponytail: in-memory, newest first internally so append is O(1). Move to
  ETS/Ecto when you need replay across restarts.
  """
  use GenServer

  alias Tiller.Event

  @doc "Child spec for supervisors."
  def child_spec(_opts \\ []), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], Keyword.put(opts, :name, __MODULE__))
  end

  @impl true
  def init(_), do: {:ok, initial()}

  defp initial, do: %{seq: 0, events: [], subs: %{}, snapshots: %{}, resumes: %{}}

  @doc "Append an attributed event. Returns the stored event with its `seq`."
  @spec append(binary, binary | nil, non_neg_integer, Event.action() | :halt, Event.result()) ::
          {:ok, Event.t()}
  def append(session_id, parent_id, turn, action, result) do
    GenServer.call(__MODULE__, {:append, session_id, parent_id, turn, action, result})
  end

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

  @doc "Count a resume of `session_id` (a supervisor restart mid-run). Returns the new count."
  @spec bump_resumes(binary) :: pos_integer
  def bump_resumes(session_id), do: GenServer.call(__MODULE__, {:bump_resumes, session_id})

  @doc """
  Reset (tests, demo). Drops events, snapshots and subscriptions. Every
  subscriber is told with `{:tiller_reset}` so it can resubscribe.
  """
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def handle_call({:append, session_id, parent_id, turn, action, result}, _from, s) do
    seq = s.seq + 1

    event = %Event{
      seq: seq,
      session_id: session_id,
      parent_id: parent_id,
      turn: turn,
      action: action,
      result: result
    }

    for pid <- Map.get(s.subs, session_id, []) ++ Map.get(s.subs, :all, []) do
      send(pid, {:tiller_event, event})
    end

    {:reply, {:ok, event}, %{s | seq: seq, events: [event | s.events]}}
  end

  def handle_call({:events, :all}, _from, s), do: {:reply, Enum.reverse(s.events), s}

  def handle_call({:events, session_id}, _from, s) do
    {:reply, s.events |> Enum.filter(&(&1.session_id == session_id)) |> Enum.reverse(), s}
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
    {:reply, :ok,
     update_in(
       s.snapshots,
       &Map.update(&1, session_id, %{turn => snap}, fn m -> Map.put(m, turn, snap) end)
     )}
  end

  def handle_call({:snapshot, session_id, turn}, _from, s) do
    {:reply, s.snapshots |> Map.get(session_id, %{}) |> Map.fetch(turn), s}
  end

  def handle_call({:bump_resumes, session_id}, _from, s) do
    s = update_in(s.resumes, &Map.update(&1, session_id, 1, fn n -> n + 1 end))
    {:reply, s.resumes[session_id], s}
  end

  def handle_call(:clear, _from, s) do
    for {_key, pids} <- s.subs, pid <- pids, do: send(pid, {:tiller_reset})
    {:reply, :ok, initial()}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, s) do
    {:noreply, %{s | subs: Map.new(s.subs, fn {k, pids} -> {k, List.delete(pids, pid)} end)}}
  end
end
