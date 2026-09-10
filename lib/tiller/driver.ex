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

  Three callbacks are optional, and a scripted driver needs none:

    * `observe/3` is how a result reaches the driver at all. The session
      calls it after recording each event. `Tiller.FakeDriver` never looks
      at a result; a model has to.
    * `override/3` is called at fork time for a `{:result_override, turn,
      result}` mutation, so a driver whose context embeds past results (a
      conversation) can rewrite the one that changed.
    * `rationale/1` is why the driver just chose what it chose. The
      session asks after every action and stores the answer on the
      event, which is how the lab can show a turn's reasoning next to
      the turn the same mutation produced elsewhere. A scripted driver
      has no reason to give and does not export it.
    * `subagent/2` is how a driver makes a child of itself: given its own
      context and a goal, the driver a subagent should run and the
      context it starts from. This is what lets a model delegate, since
      `spawn_subagent/2` takes a module and a context no model can
      supply. A driver that cannot say (a script has no way to pursue a
      goal it was not given) does not export it, and the tool refuses
      rather than inventing a child.
  """

  @callback next_action(ctx :: term()) ::
              {:action, term(), ctx :: term()}
              | {:replay, term(), Tiller.Event.result(), ctx :: term()}
              | :halt
              | {:halt, term()}

  @callback usage(ctx :: term()) :: %{input: non_neg_integer, output: non_neg_integer} | nil
  @callback observe(ctx :: term(), Tiller.Event.action(), Tiller.Event.result()) :: term()
  @callback override(ctx :: term(), non_neg_integer, Tiller.Event.result()) :: term()
  @callback rationale(ctx :: term()) :: binary | nil
  @callback subagent(ctx :: term(), goal :: binary) :: {module, term} | nil

  @optional_callbacks usage: 1, observe: 3, override: 3, rationale: 1, subagent: 2

  @doc """
  What this run has spent, if the driver is the kind that spends anything.
  `nil` from a scripted driver, which costs nothing and should not pretend
  to a zero.
  """
  @spec usage(module, term) :: %{input: non_neg_integer, output: non_neg_integer} | nil
  def usage(driver, ctx) do
    if function_exported?(driver, :usage, 1), do: driver.usage(ctx), else: nil
  end

  @doc """
  Why the action the driver just returned was chosen, if it can say.

  Asked with the context `next_action/1` handed back, so it describes
  the action about to be recorded and not the one before it. `nil` from
  a driver that reads a script: there is no reasoning to report, and an
  invented one would be worse than a blank.
  """
  @spec rationale(module, term) :: binary | nil
  def rationale(driver, ctx) do
    if function_exported?(driver, :rationale, 1), do: driver.rationale(ctx), else: nil
  end

  @doc """
  A child of this driver that pursues `goal`, or `nil` when the driver
  cannot make one.

  The child inherits what the parent runs on (its model, its endpoint,
  what it costs) and none of what the parent has done: a subagent gets a
  goal, not a conversation.
  """
  @spec subagent(module, term, binary) :: {module, term} | nil
  def subagent(driver, ctx, goal) do
    if function_exported?(driver, :subagent, 2), do: driver.subagent(ctx, goal), else: nil
  end

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
