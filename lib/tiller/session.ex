defmodule Tiller.Session do
  @moduledoc """
  One GenServer per agent run.

  init opts:
    driver:    a module implementing Tiller.Driver (or a 1-arity function)
    ctx:       initial driver context (opaque)
    whitelist: actions this session may call (root gets spawn_subagent,
               subagents do not — that's the depth limit)
    state:     the Tiller.State module (or any {append, log, clear} impl)
    parent:    optional pid; gets {:subagent_halted, self, n} on halt

  Loop: next_action(ctx) -> eval action against whitelist -> append
  {action, result} to state -> repeat until :halt. A tool that crashes
  becomes data in the log; the driver decides what to do with it.
  """
  use GenServer

  @impl true
  def init(opts) do
    driver = Keyword.fetch!(opts, :driver)
    ctx = Keyword.fetch!(opts, :ctx)
    whitelist = Keyword.get(opts, :whitelist, Tiller.Actions.root_whitelist())
    state = Keyword.get(opts, :state, Tiller.State)
    parent = Keyword.get(opts, :parent)
    %{driver: driver, ctx: ctx, whitelist: whitelist, state: state, parent: parent, turns: 0}
    |> then(&{:ok, &1})
  end

  @doc "Start the session (under a supervisor or standalone)."
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    opts = Keyword.delete(opts, :name)
    if name, do: GenServer.start_link(__MODULE__, opts, name: name), else: GenServer.start_link(__MODULE__, opts)
  end

  @doc "Child spec for supervised sessions (used by spawn_subagent)."
  def child_spec(opts) when is_list(opts) do
    %{id: Keyword.get(opts, :id, make_ref()), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Run the loop until halt. Returns {:halted, n_turns}."
  def run(pid), do: GenServer.call(pid, :run)

  @impl true
  def handle_call(:run, _from, s) do
    s = loop(s, s.driver.next_action(s.ctx), s)
    {:reply, {:halted, s.turns}, s}
  end

  defp loop(s, :halt, s) do
    s.state.append(:halt, s.turns)
    if s.parent, do: send(s.parent, {:subagent_halted, self(), s.turns})
    s
  end

  defp loop(s, {:action, a, ctx}, s) do
    result = execute(s, a)
    s.state.append(a, result)
    s = Map.merge(s, %{ctx: ctx, turns: s.turns + 1})
    loop(s, s.driver.next_action(ctx), s)
  end

  defp execute(s, a) do
    case Tiller.Actions.eval(a, s.whitelist) do
      {:ok, v} -> {:ok, v}
      {:error, r} -> {:error, r}
    end
  end
end
