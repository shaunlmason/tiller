defmodule Tiller.ToolState do
  @moduledoc """
  Shared mutable state behind the side-effecting tools in `Tiller.Tools`.

  One Agent holds everything (key-value store, spend budget, flaky-call
  counter) so a future fork can hand each branch an isolated copy in one
  move. Defaults are fixed so trajectories are reproducible.
  """
  use Agent

  @default_budget 10
  @flaky_every 3

  def child_spec(_opts \\ []), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  def start_link(opts \\ []) do
    Agent.start_link(&initial/0, Keyword.put(opts, :name, __MODULE__))
  end

  @doc "Initial state. Exposed so forks and tests can build isolated copies."
  def initial, do: %{kv: %{}, budget: @default_budget, flaky_calls: 0}

  @doc "Reset to the initial state (tests, demo)."
  def reset, do: Agent.update(__MODULE__, fn _ -> initial() end)

  @doc "Snapshot of the whole state."
  def snapshot, do: Agent.get(__MODULE__, & &1)

  def put(key, value), do: Agent.update(__MODULE__, &put_in(&1, [:kv, key], value))

  def fetch(key), do: Agent.get(__MODULE__, &Map.fetch(&1.kv, key))

  @doc "Spend `n` from the budget. Returns the remainder or refuses without depleting."
  def spend(n) when is_integer(n) and n >= 0 do
    Agent.get_and_update(__MODULE__, fn
      %{budget: b} = s when n <= b -> {{:ok, b - n}, %{s | budget: b - n}}
      s -> {{:error, :budget_exceeded}, s}
    end)
  end

  @doc "Count a flaky call. Returns {call_number, fails?}; every #{@flaky_every}rd call fails."
  def flaky_tick do
    Agent.get_and_update(__MODULE__, fn %{flaky_calls: c} = s ->
      n = c + 1
      {{n, rem(n, @flaky_every) == 0}, %{s | flaky_calls: n}}
    end)
  end
end
