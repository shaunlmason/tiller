defmodule Tiller.Session do
  @moduledoc """
  One GenServer per agent run.

  init opts:
    driver:    a module implementing Tiller.Driver
    ctx:       initial driver context (opaque)
    whitelist: actions this session may call (root gets spawn_subagent,
               subagents do not; that's the depth limit)
    state:     the Tiller.State module (or any {append/5} impl)
    id:        session id (binary); defaults to a unique one
    parent_id: id of the session that spawned this one; nil for root
    parent:    optional pid; gets {:subagent_halted, self, n} on halt

  Loop: `run/1` casts; each turn is one `:turn` message to self, so the
  process is observable (and, later, mutable) between turns. A turn asks the
  driver for the next action, evaluates it against the whitelist, appends an
  attributed `Tiller.Event`, and schedules the next turn until `:halt`.
  A tool that crashes becomes data in the log; the driver decides what to
  do with it. `await/2` blocks the caller until the session halts.
  """
  use GenServer

  @type id :: binary

  @impl true
  def init(opts) do
    id = Keyword.get_lazy(opts, :id, &unique_id/0)
    Process.put(:tiller_session_id, id)

    {:ok,
     %{
       id: id,
       parent_id: Keyword.get(opts, :parent_id),
       driver: Keyword.fetch!(opts, :driver),
       ctx: Keyword.fetch!(opts, :ctx),
       whitelist: Keyword.get(opts, :whitelist, Tiller.Actions.root_whitelist()),
       state: Keyword.get(opts, :state, Tiller.State),
       parent: Keyword.get(opts, :parent),
       turns: 0,
       status: :idle,
       waiters: []
     }}
  end

  defp unique_id, do: "s" <> Integer.to_string(System.unique_integer([:positive]))

  @doc "Start the session (under a supervisor or standalone). Registers its id."
  def start_link(opts) do
    id = Keyword.get_lazy(opts, :id, &unique_id/0)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :id, id), name: via(id))
  end

  @doc "Child spec for supervised sessions (used by spawn_subagent)."
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
    target = if is_pid(pid_or_id), do: pid_or_id, else: via(pid_or_id)

    try do
      GenServer.call(target, :await, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  @impl true
  def handle_cast(:run, %{status: :idle} = s) do
    send(self(), :turn)
    {:noreply, %{s | status: :running}}
  end

  def handle_cast(:run, s), do: {:noreply, s}

  @impl true
  def handle_call(:await, _from, %{status: {:halted, n}} = s), do: {:reply, {:halted, n}, s}
  def handle_call(:await, from, s), do: {:noreply, %{s | waiters: [from | s.waiters]}}

  @impl true
  def handle_info(:turn, %{status: :running} = s) do
    case s.driver.next_action(s.ctx) do
      :halt ->
        {:noreply, halt(s)}

      {:action, a, ctx} ->
        result = Tiller.Actions.eval(a, s.whitelist)
        {:ok, _event} = s.state.append(s.id, s.parent_id, s.turns, a, result)
        send(self(), :turn)
        {:noreply, %{s | ctx: ctx, turns: s.turns + 1}}
    end
  end

  # A subagent finished; its trajectory is in State under its own id.
  def handle_info({:subagent_halted, _pid, _n}, s), do: {:noreply, s}
  def handle_info(_other, s), do: {:noreply, s}

  defp halt(s) do
    {:ok, _event} = s.state.append(s.id, s.parent_id, s.turns, :halt, {:halted, s.turns})
    if s.parent, do: send(s.parent, {:subagent_halted, self(), s.turns})
    for from <- s.waiters, do: GenServer.reply(from, {:halted, s.turns})
    %{s | status: {:halted, s.turns}, waiters: []}
  end
end
