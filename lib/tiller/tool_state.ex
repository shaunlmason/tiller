defmodule Tiller.ToolState do
  @moduledoc """
  Mutable state behind the side-effecting tools in `Tiller.Tools`.

  One Agent holds everything (key-value store, spend budget, flaky-call
  counter). The application starts a global instance that root sessions
  share; a forked branch gets its own instance seeded from a snapshot, so
  concurrent branches never share a budget. Tools find theirs through
  `current/0`, which the owning session sets in its process dictionary.
  Defaults are fixed so trajectories are reproducible.
  """
  use Agent

  @default_budget 10
  @flaky_every 3

  def child_spec(_opts \\ []),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[name: __MODULE__]]}}

  @doc "Start an instance. Options: `:initial` (a snapshot map), `:name`."
  def start_link(opts \\ []) do
    initial = Keyword.get(opts, :initial, initial())

    case Keyword.get(opts, :name) do
      nil -> Agent.start_link(fn -> initial end)
      name -> Agent.start_link(fn -> initial end, name: name)
    end
  end

  @doc "Initial state. Exposed so forks and tests can build isolated copies."
  def initial, do: %{kv: %{}, budget: @default_budget, flaky_calls: 0}

  @doc "The instance the calling process's tools use: the session's, or the global one."
  def current, do: Process.get(:tiller_tool_state, __MODULE__)

  @doc "Bind the calling process (a session) to an instance."
  def bind(agent), do: Process.put(:tiller_tool_state, agent)

  @doc "Reset to the initial state (tests, demo)."
  def reset(agent \\ current()), do: Agent.update(agent, fn _ -> initial() end)

  @doc "Snapshot of the whole state."
  def snapshot(agent \\ current()), do: Agent.get(agent, & &1)

  def put(key, value), do: Agent.update(current(), &put_in(&1, [:kv, key], value))

  def fetch(key), do: Agent.get(current(), &Map.fetch(&1.kv, key))

  @doc "Spend `n` from the budget. Returns the remainder or refuses without depleting."
  def spend(n) when is_integer(n) and n >= 0 do
    Agent.get_and_update(current(), fn
      %{budget: b} = s when n <= b -> {{:ok, b - n}, %{s | budget: b - n}}
      s -> {{:error, :budget_exceeded}, s}
    end)
  end

  @doc "Count a flaky call. Returns {call_number, fails?}; every #{@flaky_every}rd call fails."
  def flaky_tick do
    Agent.get_and_update(current(), fn %{flaky_calls: c} = s ->
      n = c + 1
      {{n, rem(n, @flaky_every) == 0}, %{s | flaky_calls: n}}
    end)
  end
end
