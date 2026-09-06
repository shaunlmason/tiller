defmodule Tiller.Divergence do
  @moduledoc """
  Where two trajectories first part ways.

  This is the go/no-go spike from docs/designs/agent-butterfly-lab.md ("The
  Assignment"): the one algorithmic piece of the lab. Everything else is
  plumbing. The answer turned out to be short because the question is
  narrower than "align two sequences": a branch forked at turn N shares the
  first N events with its parent by construction, so the first divergence
  is a prefix walk, not an edit distance. Both lists are compared turn by
  turn; the first turn whose `{action, result}` differs is the answer, and
  a list that ends first diverges at the turn it lacks.

  What "differs" means is the only real decision, and it is a projection,
  not a raw `==`. Two branches that both spawned a subagent did not diverge
  because the subagent got a different pid; two crashes with the same
  reason did not diverge because their stack traces list different line
  numbers. `normalize/1` erases exactly that: pids, references, ports, and
  functions become their kind, and the stack trace inside an
  `{:error, {kind, reason, stacktrace}}` result is dropped. Pass `key:` to
  substitute your own projection (a seed envelope's timestamps, say).

  Deliberately not here: which of several branches diverged "least"
  (open question 3 in the design), and any alignment that tolerates an
  inserted turn. An inserted turn IS the divergence.
  """

  alias Tiller.Event

  @type event :: Event.t() | {term, term}

  @type verdict ::
          :identical
          | {:diverged, non_neg_integer, event | nil, event | nil}

  @doc """
  Compare two trajectories. Each may be a list of `%Tiller.Event{}` or of
  raw `{action, result}` log tuples (a `{:halt, n}` record is understood).
  Returns `:identical`, or `{:diverged, turn, left, right}` where `left`
  or `right` is `nil` when that branch ran out of turns first.

  Options: `key:` a projection applied to `{action, result}` before
  comparison (default `&normalize/1`).
  """
  @spec first_diff([event], [event], keyword) :: verdict
  def first_diff(left, right, opts \\ []) do
    key = Keyword.get(opts, :key, &normalize/1)
    walk(left, right, 0, key)
  end

  @doc """
  One root against many branches: `[{branch_index, verdict}]`, in order.
  """
  @spec report([event], [[event]], keyword) :: [{non_neg_integer, verdict}]
  def report(root, branches, opts \\ []) do
    branches
    |> Enum.with_index()
    |> Enum.map(fn {b, i} -> {i, first_diff(root, b, opts)} end)
  end

  @doc """
  The default projection: `{action, result}` with non-deterministic
  identity erased. Pids, refs, ports, and funs become `:pid`, `:ref`,
  `:port`, `:fun`; the stack trace in an `{:error, {kind, reason, st}}`
  result is dropped. Structural everywhere else.
  """
  @spec normalize({term, term}) :: {term, term}
  def normalize({action, {:error, {kind, reason, st}}}) when is_list(st) do
    {scrub(action), {:error, {kind, scrub(reason)}}}
  end

  def normalize({action, result}), do: {scrub(action), scrub(result)}

  ## Internals

  defp walk([], [], _i, _key), do: :identical
  defp walk([l | _], [], i, _key), do: {:diverged, i, l, nil}
  defp walk([], [r | _], i, _key), do: {:diverged, i, nil, r}

  defp walk([l | ls], [r | rs], i, key) do
    if key.(pair(l)) == key.(pair(r)),
      do: walk(ls, rs, i + 1, key),
      else: {:diverged, i, l, r}
  end

  # the comparable core of an event, whichever shape it arrived in
  defp pair(%Event{action: a, result: r}), do: {a, r}
  defp pair({:halt, n}) when is_integer(n), do: {:halt, {:halted, n}}
  defp pair({a, r}), do: {a, r}

  defp scrub(t) when is_pid(t), do: :pid
  defp scrub(t) when is_reference(t), do: :ref
  defp scrub(t) when is_port(t), do: :port
  defp scrub(t) when is_function(t), do: :fun
  defp scrub(t) when is_list(t), do: Enum.map(t, &scrub/1)
  defp scrub(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&scrub/1) |> List.to_tuple()
  defp scrub(%{__struct__: _} = t), do: t |> Map.from_struct() |> scrub() |> Map.put(:__struct__, t.__struct__)
  defp scrub(t) when is_map(t), do: Map.new(t, fn {k, v} -> {scrub(k), scrub(v)} end)
  defp scrub(t), do: t
end
