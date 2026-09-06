defmodule Tiller.State do
  @moduledoc """
  The attributed, ordered event store. Every session's every turn lands
  here as a `Tiller.Event` with a global monotonic `seq`, its
  `session_id`, its `parent_id`, and its `turn`. It is the audit trail,
  the replay log, the source of the next prompt, and now the thing a
  fork reads its prefix from: `Enum.take(events(id), n)` is the state at
  turn n.

  Subscribers (`subscribe/1`) get `{:tiller_event, %Tiller.Event{}}` on
  every append for that session, or for every session with `:all`.
  Delivery is a `Registry` dispatch: zero dependencies, same shape a
  `Phoenix.PubSub` broadcast will have when the LiveView arrives (step 9);
  `subscribe/1` is the seam.

  In-memory, newest first internally, oldest first on every read. Move to
  ETS or a table when replay across restarts is needed.
  """
  use GenServer

  alias Tiller.Event

  @registry Tiller.State.Registry

  def child_spec(_opts \\ []), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], Keyword.put(opts, :name, __MODULE__))
  end

  @doc "The registry `subscribe/1` uses; started by the application."
  def registry_spec, do: {Registry, keys: :duplicate, name: @registry}

  @doc "Append one event. Returns the stored event, `seq` assigned."
  @spec append(term, term, non_neg_integer, Event.action(), Event.result()) :: {:ok, Event.t()}
  def append(session_id, parent_id, turn, action, result) do
    GenServer.call(__MODULE__, {:append, session_id, parent_id, turn, action, result})
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
  def subscribe(session_id) do
    {:ok, _} = Registry.register(@registry, session_id, nil)
    :ok
  end

  def unsubscribe(session_id), do: Registry.unregister(@registry, session_id)

  @doc "Reset (tests)."
  def clear, do: GenServer.call(__MODULE__, :clear)

  ## Server

  @impl true
  def init(_), do: {:ok, %{seq: 0, events: []}}

  @impl true
  def handle_call({:append, sid, pid, turn, action, result}, _from, s) do
    seq = s.seq + 1
    ev = %Event{seq: seq, session_id: sid, parent_id: pid, turn: turn, action: action, result: result}
    publish(ev)
    {:reply, {:ok, ev}, %{s | seq: seq, events: [ev | s.events]}}
  end

  def handle_call({:events, sid}, _from, s) do
    {:reply, s.events |> Enum.filter(&(&1.session_id == sid)) |> Enum.reverse(), s}
  end

  def handle_call(:all, _from, s), do: {:reply, Enum.reverse(s.events), s}
  def handle_call(:clear, _from, _s), do: {:reply, :ok, %{seq: 0, events: []}}

  defp publish(ev) do
    for key <- [ev.session_id, :all] do
      Registry.dispatch(@registry, key, fn entries ->
        for {pid, _} <- entries, do: send(pid, {:tiller_event, ev})
      end)
    end
  end
end
