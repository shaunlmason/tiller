defmodule Tiller.State do
  @moduledoc """
  The attributed, ordered event store. Every session's every turn lands
  here as a `Tiller.Event` with a global monotonic `seq`, its
  `session_id`, its `parent_id`, and its `turn`. It is the audit trail,
  the replay log, the source of the next prompt, and now the thing a
  fork reads its prefix from: `Enum.take(events(id), n)` is the state at
  turn n.

  Subscribers (`subscribe/1`) get `{:tiller_event, %Tiller.Event{}}` on
  every append for that session, or for every session with `:all`, over
  `Phoenix.PubSub` (`Tiller.PubSub`; the LiveView subscribes to `:all`).

  In memory, newest first internally, oldest first on every read. With
  `config :tiller, state_log: path` (or `TILLER_STATE_LOG`) every write is
  also appended to that file (`Tiller.State.Log`) and the store is rebuilt
  from it at start, so trajectories and packets survive a VM restart and
  a session that died with the VM can be brought back with
  `Tiller.Session.resume/1`.
  """
  use GenServer

  alias Tiller.Event

  @pubsub Tiller.PubSub

  def child_spec(_opts \\ []), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], Keyword.put(opts, :name, __MODULE__))
  end

  @doc "The PubSub `subscribe/1` uses; started by the application."
  def pubsub_spec, do: {Phoenix.PubSub, name: @pubsub}

  @doc "Append one event. Returns the stored event, `seq` assigned. `origin` is `:live` or `:replay`."
  @spec append(term, term, non_neg_integer, Event.action(), Event.result(), :live | :replay) :: {:ok, Event.t()}
  def append(session_id, parent_id, turn, action, result, origin \\ :live) do
    GenServer.call(__MODULE__, {:append, session_id, parent_id, turn, action, result, origin})
  end

  @doc "All events for one session, oldest first."
  @spec events(term) :: [Event.t()]
  def events(session_id), do: GenServer.call(__MODULE__, {:events, session_id})

  @doc "Every event in `seq` order."
  @spec events() :: [Event.t()]
  def events(), do: GenServer.call(__MODULE__, :all)

  @doc """
  The human projection: `{action, result}` pairs in order, a halt as
  `{:halt, turns}`, for one session or (with no argument) across all.
  """
  def log(session_id \\ :all) do
    (if session_id == :all, do: events(), else: events(session_id))
    |> Enum.map(fn
      %Event{action: :halt, result: {:halted, n}} -> {:halt, n}
      %Event{action: a, result: r} -> {a, r}
    end)
  end

  @doc "Has this session recorded its halt?"
  def halted?(session_id) do
    Enum.any?(events(session_id), &match?(%Event{action: :halt}, &1))
  end

  @doc "Receive `{:tiller_event, event}` for a session, or for `:all`."
  @spec subscribe(term) :: :ok
  def subscribe(session_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(session_id))

  def unsubscribe(session_id), do: Phoenix.PubSub.unsubscribe(@pubsub, topic(session_id))

  defp topic(:all), do: "tiller:events"
  defp topic(id) when is_binary(id), do: "tiller:session:" <> id
  defp topic(id), do: "tiller:session:" <> inspect(id)

  @doc """
  Store a session's packet: what a resume needs besides its events
  (origin driver and context, whitelist, latency, lineage). Written by
  `Tiller.Session` at start; `resumed_by` is set when a killed session
  comes back.
  """
  def put_session(id, packet), do: GenServer.call(__MODULE__, {:put_session, id, packet})

  def update_session(id, fun), do: GenServer.call(__MODULE__, {:update_session, id, fun})

  @doc "A session's packet, or nil."
  def get_session(id), do: GenServer.call(__MODULE__, {:get_session, id})

  @doc "Reset (tests). Truncates the log file too."
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc """
  Switch to (or re-read) the log at `path`, replacing the in-memory store
  with the file's contents; `nil` goes back to memory only. What a VM
  restart does, callable for tests.
  """
  def reopen(path), do: GenServer.call(__MODULE__, {:reopen, path})

  @doc "The log path in use, or nil."
  def log_path, do: GenServer.call(__MODULE__, :log_path)

  ## Server

  @impl true
  def init(_) do
    path = Application.get_env(:tiller, :state_log) || blank_to_nil(System.get_env("TILLER_STATE_LOG"))
    {:ok, load(path)}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  # the store from a log file (or an empty one from nothing)
  defp load(nil), do: %{seq: 0, events: [], sessions: %{}, log: nil, path: nil}

  defp load(path) do
    empty = %{seq: 0, events: [], sessions: %{}, log: nil, path: path}

    s =
      Enum.reduce(Tiller.State.Log.read(path), empty, fn
        {:event, %Event{} = ev}, s -> %{s | seq: max(s.seq, ev.seq), events: [ev | s.events]}
        {:session, id, packet}, s -> %{s | sessions: Map.put(s.sessions, id, packet)}
        _, s -> s
      end)

    %{s | log: Tiller.State.Log.open(path)}
  end

  defp record(%{log: nil}, _frame), do: :ok
  defp record(%{log: io}, frame), do: Tiller.State.Log.append(io, frame)

  @impl true
  def handle_call({:append, sid, pid, turn, action, result, origin}, _from, s) do
    seq = s.seq + 1
    ev = %Event{seq: seq, session_id: sid, parent_id: pid, turn: turn, action: action, result: result, origin: origin}
    record(s, {:event, ev})
    publish(ev)
    {:reply, {:ok, ev}, %{s | seq: seq, events: [ev | s.events]}}
  end

  def handle_call({:reopen, path}, _from, s) do
    if s.log, do: File.close(s.log)
    {:reply, :ok, load(path)}
  end

  def handle_call(:log_path, _from, s), do: {:reply, s.path, s}

  def handle_call({:events, sid}, _from, s) do
    {:reply, s.events |> Enum.filter(&(&1.session_id == sid)) |> Enum.reverse(), s}
  end

  def handle_call(:all, _from, s), do: {:reply, Enum.reverse(s.events), s}

  def handle_call(:clear, _from, s) do
    log = if s.log, do: Tiller.State.Log.truncate(s.log, s.path), else: nil
    {:reply, :ok, %{seq: 0, events: [], sessions: %{}, log: log, path: s.path}}
  end

  def handle_call({:put_session, id, packet}, _from, s) do
    record(s, {:session, id, packet})
    {:reply, :ok, %{s | sessions: Map.put(s.sessions, id, packet)}}
  end

  def handle_call({:update_session, id, fun}, _from, s) do
    case Map.fetch(s.sessions, id) do
      {:ok, packet} ->
        packet = fun.(packet)
        record(s, {:session, id, packet})
        {:reply, :ok, %{s | sessions: Map.put(s.sessions, id, packet)}}

      :error ->
        {:reply, {:error, :unknown_session}, s}
    end
  end

  def handle_call({:get_session, id}, _from, s), do: {:reply, Map.get(s.sessions, id), s}

  defp publish(ev) do
    for key <- [ev.session_id, :all] do
      Phoenix.PubSub.broadcast(@pubsub, topic(key), {:tiller_event, ev})
    end
  end
end
