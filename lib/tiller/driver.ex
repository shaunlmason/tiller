defmodule Tiller.Driver do
  @moduledoc """
  The one seam for "where the next action comes from".

  A driver is a pure function: given its opaque context, it returns the next
  action (a quoted MFA term) and its updated context, or :halt. The Session
  stores the context between turns; a real LLM driver uses it for conversation
  state. Nothing else in the harness changes when you swap drivers.

  A driver may also return `{:replay, action, result, ctx}`: the Session
  records the action with that result and does not evaluate it. Only
  `Tiller.Driver.Replay` does this; it is how a recorded prefix is replayed
  without re-running its tools.
  """

  @callback next_action(ctx :: term()) ::
              {:action, term(), ctx :: term()}
              | {:replay, term(), Tiller.Event.result(), ctx :: term()}
              | :halt

  @doc "Build a quoted action term: the grammar is the capability boundary."
  def action(f, args \\ []), do: {:call, Tiller.Tools, f, args}
end

defmodule Tiller.FakeDriver do
  @moduledoc "Scripts a list of actions; halts when the queue is empty."
  @behaviour Tiller.Driver

  @impl true
  def next_action(%{queue: [a | rest]}), do: {:action, a, %{queue: rest}}

  def next_action(_ctx), do: :halt

  @doc "Fresh context for a scripted run."
  def context(actions), do: %{queue: actions}
end
