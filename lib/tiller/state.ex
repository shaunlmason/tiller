defmodule Tiller.State do
  @moduledoc """
  Ordered, attributed event store shared by every session.

  Every action + result from every session (root, subagent, future forks)
  lands here as a `Tiller.Event` with a globally monotonic `seq`. It is the
  audit trail, the replay log, and the source of the next prompt: one thing,
  three jobs. Per-session views come from filtering on `session_id`.

  Subscribers get `{:tiller_event, event}` for every append to the session
  they subscribed to (or `:all`). This is what `Tiller.Session.await/2` and
  the tests build on instead of sleeping. A Phoenix.PubSub broadcast can
  replace the subscriber map when LiveView arrives.

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

  defp initial, do: %{seq: 0, events: [], subs: %{}}

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

  @doc "Reset (tests, demo). Drops events and subscriptions."
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
    {:reply, :ok, update_in(s.subs, &Map.update(&1, key, [pid], fn pids -> [pid | pids] end))}
  end

  def handle_call(:clear, _from, _s), do: {:reply, :ok, initial()}
end
