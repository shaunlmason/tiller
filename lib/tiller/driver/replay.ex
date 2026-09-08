defmodule Tiller.Driver.Replay do
  @moduledoc """
  Replays a recorded prefix, then hands off to a delegate driver.

  This is what makes a fork point free: the state at turn N is the first N
  events, so a branch is "replay N events, then continue". Replayed turns
  return `{:replay, action, result, ctx}`, so the Session records the
  recorded result and never re-runs the tool. Replaying an action instead
  of its result would execute side effects twice and make replay
  non-deterministic.

  The delegate takes over once the prefix is exhausted. Its initial context
  is supplied at fork time (Open Question 2 in `docs/design.md`, answered
  with the simpler option); an optional `resume_ctx/1` callback that builds
  it from the recorded events is the upgrade path for a driver that needs
  the conversation so far.

  `overrides` maps a turn index to a replacement result, which is the
  `{:result_override, turn, result}` mutation axis.

  Caveat: injecting results reproduces the log, not the world. Side effects
  of the prefix (a `put`, a `spend`) are not re-applied to
  `Tiller.ToolState`, so a delegate that reads them sees whatever state the
  branch actually has. Per-branch tool state is the fork step's problem.
  """
  @behaviour Tiller.Driver

  alias Tiller.Event

  @type ctx :: %{
          prefix: [Event.t()],
          overrides: %{non_neg_integer => Event.result()},
          delegate: module,
          delegate_ctx: term,
          baseline: %{input: non_neg_integer, output: non_neg_integer} | nil,
          rationale: binary | nil,
          turn: non_neg_integer
        }

  @doc """
  Build a replay context from recorded events.

  Options:
    * `:turn` replay only the first `turn` events (the fork point); default
      replays every non-halt event
    * `:overrides` `%{turn => result}` results to inject in place of the
      recorded ones
  """
  @spec context([Event.t()], module, term, keyword) :: ctx
  def context(events, delegate, delegate_ctx, opts \\ []) do
    prefix = Enum.reject(events, &Event.halt?/1)

    prefix =
      case Keyword.get(opts, :turn) do
        nil -> prefix
        n when is_integer(n) and n >= 0 -> Enum.take(prefix, n)
      end

    %{
      prefix: prefix,
      overrides: Keyword.get(opts, :overrides, %{}),
      delegate: delegate,
      delegate_ctx: delegate_ctx,
      # What the source had already spent by the fork turn. The branch did
      # not pay it, so it is subtracted back out of usage/1.
      baseline: Tiller.Driver.usage(delegate, delegate_ctx),
      turn: 0,
      # false while the prefix is being replayed: those turns are already
      # in the delegate's context, which came from the fork-turn snapshot,
      # so observing them again would double-count them.
      delegating: false,
      # the recorded reason for the prefix turn being replayed, so a
      # branch's prefix reads the way the source's did
      rationale: nil
    }
  end

  @impl true
  def next_action(%{prefix: [event | rest], turn: turn} = ctx) do
    result = Map.get(ctx.overrides, turn, event.result)

    {:replay, event.action, result,
     %{ctx | prefix: rest, turn: turn + 1, rationale: Event.rationale(event)}}
  end

  def next_action(%{prefix: [], delegate: delegate, delegate_ctx: dctx} = ctx) do
    ctx = %{ctx | delegating: true, rationale: nil}

    case delegate.next_action(dctx) do
      :halt -> :halt
      {:halt, reason} -> {:halt, reason}
      {:action, a, dctx2} -> {:action, a, %{ctx | delegate_ctx: dctx2, turn: ctx.turn + 1}}
      {:replay, a, r, dctx2} -> {:replay, a, r, %{ctx | delegate_ctx: dctx2, turn: ctx.turn + 1}}
    end
  end

  @doc """
  Results from the branch's own turns reach the delegate; replayed ones do
  not, because the delegate's context already contains them.
  """
  @impl true
  def observe(%{delegating: true} = ctx, action, result) do
    %{ctx | delegate_ctx: Tiller.Driver.observe(ctx.delegate, ctx.delegate_ctx, action, result)}
  end

  def observe(ctx, _action, _result), do: ctx

  @doc """
  A result override reaches the delegate through here.

  A branch's driver is this module, so forking a branch again aims the
  fork's `override/3` at Replay rather than at the driver underneath.
  Without forwarding, the replayed event would carry the new result while
  the delegate (a conversation, say) still remembered the old one, and
  the model would choose its next action from a history that never
  happened. Nested branches recurse, since a delegate may itself be a
  Replay.
  """
  # The prefix is replayed, not re-requested, so a branch's cost is only
  # what its delegate spent past the fork point. The context it inherited
  # already held the source's running total; that part is not this
  # branch's bill.
  @impl true
  def usage(%{delegate: d, delegate_ctx: dctx} = ctx) do
    case {Tiller.Driver.usage(d, dctx), Map.get(ctx, :baseline)} do
      {nil, _} -> nil
      {now, nil} -> now
      {now, base} -> %{input: now.input - base.input, output: now.output - base.output}
    end
  end

  @doc """
  Why the turn just returned was chosen: the delegate's reason once the
  branch is deciding for itself, and the recorded one while the prefix
  is being replayed.

  A replayed turn was not decided again, so reporting the delegate's
  current reasoning for it would attribute the fork point's thinking to
  a turn that happened before it. The recorded reason is the true one,
  and it is what makes a branch's prefix read like its source's.
  """
  @impl true
  def rationale(%{delegating: true, delegate: d, delegate_ctx: dctx}),
    do: Tiller.Driver.rationale(d, dctx)

  def rationale(ctx), do: Map.get(ctx, :rationale)

  @impl true
  def override(ctx, turn, result) do
    %{ctx | delegate_ctx: Tiller.Driver.override(ctx.delegate, ctx.delegate_ctx, turn, result)}
  end
end
