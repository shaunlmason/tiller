defmodule Tiller.Divergence do
  @moduledoc """
  Where do two trajectories first differ?

  A trajectory is an ordered list of events: `Tiller.Event` structs, or the
  bare `{action, result}` / `{:halt, turns}` tuples the current
  `Tiller.State` log records. Two branches forked from the same prefix share
  that prefix, so divergence is the first index at which the two lists stop
  agreeing.

  Events are compared on `Tiller.Event.key/1`, the action and its result,
  never on branch identity (`seq`, `session_id`, `parent_id`), which differs
  between branches by construction. A different action, a different result
  for the same action, or an early halt all count as divergence. When one
  branch simply has fewer events than the other (it is still running, or
  died before logging its halt), the missing side is `nil`.

  This is the go/no-go spike from `docs/design.md`: pure functions over lists,
  no processes.
  """

  @type event :: Tiller.Event.t() | {action :: term, result :: term} | {:halt, non_neg_integer}

  @doc """
  Return `:identical` when both trajectories agree event for event, otherwise
  `{:diverged, index, left, right}` where `index` is the position of the first
  disagreement and `left`/`right` are the events at that position (`nil` when
  that side has no event there).

      iex> Tiller.Divergence.first_diff([{:a, 1}, {:halt, 1}], [{:a, 1}, {:halt, 1}])
      :identical

      iex> Tiller.Divergence.first_diff([{:a, 1}, {:b, 2}], [{:a, 1}, {:b, 3}])
      {:diverged, 1, {:b, 2}, {:b, 3}}

      iex> Tiller.Divergence.first_diff([{:a, 1}], [{:a, 1}, {:b, 2}])
      {:diverged, 1, nil, {:b, 2}}
  """
  @spec first_diff([event], [event]) ::
          :identical
          | {:diverged, index :: non_neg_integer, left :: event | nil, right :: event | nil}
  def first_diff(left, right) when is_list(left) and is_list(right), do: walk(left, right, 0)

  @doc """
  How many positions differ between two trajectories: every index where
  the keys disagree, plus every index one side has and the other lacks.
  Zero means identical. Used to rank mutations by the size of their effect
  rather than by any size of their own.

      iex> Tiller.Divergence.distance([{:a, 1}, {:b, 2}], [{:a, 1}, {:b, 3}, {:c, 4}])
      2
  """
  @spec distance([event], [event]) :: non_neg_integer
  def distance(left, right) when is_list(left) and is_list(right), do: count(left, right, 0)

  defp count([], [], n), do: n
  defp count([], rest, n), do: n + length(rest)
  defp count(rest, [], n), do: n + length(rest)

  defp count([l | lt], [r | rt], n) do
    count(lt, rt, if(Tiller.Event.key(l) == Tiller.Event.key(r), do: n, else: n + 1))
  end

  defp walk([], [], _i), do: :identical

  defp walk([l | lt], [r | rt], i) do
    if Tiller.Event.key(l) == Tiller.Event.key(r),
      do: walk(lt, rt, i + 1),
      else: {:diverged, i, l, r}
  end

  defp walk([l | _], [], i), do: {:diverged, i, l, nil}
  defp walk([], [r | _], i), do: {:diverged, i, nil, r}
end
