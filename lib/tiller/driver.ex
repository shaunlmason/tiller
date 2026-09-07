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
  without re-running its tools. `{:halt, reason}` ends the run and records
  the reason, which is how an abnormal ending (a refusal, a spent budget)
  diverges from a normal one.

  Two callbacks are optional, and a scripted driver needs neither:

    * `observe/3` is how a result reaches the driver at all. The session
      calls it after recording each event. `Tiller.FakeDriver` never looks
      at a result; a model has to.
    * `override/3` is called at fork time for a `{:result_override, turn,
      result}` mutation, so a driver whose context embeds past results (a
      conversation) can rewrite the one that changed.
  """

  @callback next_action(ctx :: term()) ::
              {:action, term(), ctx :: term()}
              | {:replay, term(), Tiller.Event.result(), ctx :: term()}
              | :halt
              | {:halt, term()}

  @callback observe(ctx :: term(), Tiller.Event.action(), Tiller.Event.result()) :: term()
  @callback override(ctx :: term(), non_neg_integer, Tiller.Event.result()) :: term()

  @optional_callbacks observe: 3, override: 3

  @doc "Build a quoted action term: the grammar is the capability boundary."
  def action(f, args \\ []), do: {:call, Tiller.Tools, f, args}

  @doc "Fold a recorded result into the driver's context, if it observes."
  @spec observe(module, term, Tiller.Event.action(), Tiller.Event.result()) :: term
  def observe(driver, ctx, action, result) do
    if function_exported?(driver, :observe, 3),
      do: driver.observe(ctx, action, result),
      else: ctx
  end

  @doc "Rewrite the result the driver remembers for `turn`, if it can."
  @spec override(module, term, non_neg_integer, Tiller.Event.result()) :: term
  def override(driver, ctx, turn, result) do
    if function_exported?(driver, :override, 3),
      do: driver.override(ctx, turn, result),
      else: ctx
  end
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
