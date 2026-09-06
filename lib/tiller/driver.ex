defmodule Tiller.Driver do
  @moduledoc """
  The one seam for "where the next action comes from".

  A driver is a pure function: given its opaque context, it returns the next
  action (a quoted MFA term) and its updated context, or :halt. The Session
  stores the context between turns; a real LLM driver uses it for conversation
  state. Nothing else in the harness changes when you swap drivers.

  A driver may also answer `{:replay, action, result, ctx}`: the session
  records the pair as-is and runs nothing. Only `Tiller.Driver.Replay` does
  this today; it is how a forked branch re-lives its parent's prefix
  without executing side effects twice.

  `resume_ctx/2` is optional (butterfly lab, open question 2). When a
  replayed prefix runs out, the replay driver hands off to a delegate and
  needs that delegate's context *as of the fork turn*. Driver contexts are
  opaque, so only the driver can rebuild one: given its initial context
  and the events that were replayed, return the context to continue from.
  A driver that does not implement it is handed its context exactly as
  supplied at fork time, so the caller must position it themselves.
  """

  @type action :: {:call, module, atom, [term]}
  @type reply :: {:action, action, ctx :: term} | {:replay, action, term, ctx :: term} | :halt

  @callback next_action(ctx :: term()) :: reply
  @callback resume_ctx(initial_ctx :: term(), replayed :: [Tiller.Event.t()]) :: term()
  @optional_callbacks resume_ctx: 2

  @doc "Build a quoted action term: the grammar is the capability boundary."
  def action(f, args \\ []), do: {:call, Tiller.Tools, f, args}

  @doc "The delegate's context as of the fork turn: `resume_ctx/2` if it has one, else as supplied."
  def resume(driver, initial_ctx, replayed) do
    if function_exported?(driver, :resume_ctx, 2),
      do: driver.resume_ctx(initial_ctx, replayed),
      else: initial_ctx
  end
end

defmodule Tiller.FakeDriver do
  @moduledoc "Scripts a list of actions; halts when the queue is empty."
  @behaviour Tiller.Driver

  @impl true
  def next_action(%{queue: [a | rest]}), do: {:action, a, %{queue: rest}}

  def next_action(_ctx), do: :halt

  @doc "Resuming a script is skipping the turns already taken."
  @impl true
  def resume_ctx(%{queue: q}, replayed), do: %{queue: Enum.drop(q, length(replayed))}

  @doc "Fresh context for a scripted run."
  def context(actions), do: %{queue: actions}
end

defmodule Tiller.Driver.Replay do
  @moduledoc """
  Re-live a recorded prefix, then hand off (butterfly lab, step 7).

  Context: the events to replay (a parent's first N), the delegate driver
  and its initial context, and optional `overrides` (`%{turn => result}`)
  that substitute a recorded result at a turn: the `result_override`
  mutation axis. Each replayed turn is answered as
  `{:replay, action, result, ctx}`, so the session appends the pair and
  executes nothing: replaying *actions* would re-run the tools, and
  deterministic replay requires injecting the recorded *result*.

  When the prefix is spent, the delegate's context is rebuilt once with
  `Tiller.Driver.resume/3` from the events as replayed (overrides
  included, because that is the past this branch experienced), and every
  later turn is the delegate's.
  """
  @behaviour Tiller.Driver

  alias Tiller.Event

  @type t :: %{
          pending: [Event.t()],
          done: [Event.t()],
          overrides: %{non_neg_integer => term},
          delegate: module,
          delegate_ctx: term,
          resumed: boolean
        }

  @doc "Build a replay context. `overrides` keys must fall inside the prefix."
  @spec context([Event.t()], module, term, keyword) :: t
  def context(prefix, delegate, delegate_ctx, opts \\ []) do
    %{
      pending: prefix,
      done: [],
      overrides: Map.new(Keyword.get(opts, :overrides, [])),
      delegate: delegate,
      delegate_ctx: delegate_ctx,
      resumed: false
    }
  end

  @impl true
  def next_action(%{pending: [%Event{action: :halt} | _]}), do: :halt

  def next_action(%{pending: [%Event{} = ev | rest]} = ctx) do
    result = Map.get(ctx.overrides, ev.turn, ev.result)
    replayed = %Event{ev | result: result}
    {:replay, ev.action, result, %{ctx | pending: rest, done: [replayed | ctx.done]}}
  end

  def next_action(%{pending: [], resumed: false} = ctx) do
    dctx = Tiller.Driver.resume(ctx.delegate, ctx.delegate_ctx, Enum.reverse(ctx.done))
    next_action(%{ctx | delegate_ctx: dctx, resumed: true})
  end

  def next_action(%{pending: [], resumed: true} = ctx) do
    case ctx.delegate.next_action(ctx.delegate_ctx) do
      :halt -> :halt
      {:action, a, dctx} -> {:action, a, %{ctx | delegate_ctx: dctx}}
      {:replay, a, r, dctx} -> {:replay, a, r, %{ctx | delegate_ctx: dctx}}
    end
  end
end
