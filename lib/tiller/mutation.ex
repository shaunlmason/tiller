defmodule Tiller.Mutation do
  @moduledoc """
  The vocabulary of "one thing different" for a forked branch.

  A mutation is applied to exactly one branch at fork time. Two axes are
  already plumbed through `Tiller.Session` options (whitelist, driver); the
  rest need Replay and scheduler support and are Stretch in `docs/design.md`.
  This module is data, validation, and one generator (`sweep/4`);
  applying a mutation is the fork's job.
  """

  alias Tiller.Event

  @type t ::
          {:whitelist, [{atom, arity}]}
          | {:driver, module, ctx :: term}
          | {:result_override, turn :: non_neg_integer, term}
          | {:latency, milliseconds :: pos_integer}
          | {:kill_at, turn :: non_neg_integer}

  @type axis :: :whitelist | :driver | :result_override | :latency | :kill_at

  @axes [:whitelist, :driver, :result_override, :latency, :kill_at]
  @mvp_axes [:whitelist, :driver]

  @doc "Every axis, in the order the design lists them."
  @spec axes() :: [axis]
  def axes, do: @axes

  @doc "Axes that need nothing beyond existing `Tiller.Session` options."
  @spec mvp_axes() :: [axis]
  def mvp_axes, do: @mvp_axes

  @doc """
  Every mutation worth trying on a run forked at `turn`.

  Hand-picked presets answer "what if this one thing were different".
  A sweep answers "which of the things that could matter did", by
  covering each axis at every point on it that this run reaches:

    * `:whitelist`: one branch per tool the run actually called at or
      after `turn`. Removing a tool it never reached cannot change
      anything, so those branches are not generated.
    * `:result_override`: one per replayed turn, since only the prefix
      can be overridden.
    * `:kill_at`: one per turn the branch will live through.
    * `:latency`: one per entry in `:latencies`, when the branch has a
      turn to be slowed down at all.

  `:controls` (default 1) prepends that many `nil` mutations. With a
  scripted driver a control is a reproduction; with a model it is a
  fresh sample, and comparing controls to each other is what tells a
  decisive mutation from ordinary variance.

  `:limit` (default 24) caps the result. A long run reaches many points
  on every axis, and each branch records a whole trajectory the lab then
  draws a cell per turn for, so an uncapped sweep of a long run costs
  roughly the square of its length. The cap takes one from each axis in
  turn rather than truncating the list, so no axis is starved by the one
  that happened to generate most: what comes back is a spread, not a
  prefix. `limit: :infinity` asks for all of them.

  Pure: give it a recorded trajectory and a whitelist, get a list back.
  """
  @spec sweep([Event.t()], [{atom, arity}], non_neg_integer, keyword) :: [t | nil]
  def sweep(events, whitelist, turn, opts \\ []) do
    axes = Keyword.get(opts, :axes, @axes -- [:driver])
    steps = Enum.reject(events, &Event.halt?/1)

    controls = List.duplicate(nil, Keyword.get(opts, :controls, 1))
    by_axis = for axis <- axes, do: for_axis(axis, steps, whitelist, turn, opts)
    limit = Keyword.get(opts, :limit, 24)

    controls ++ spread(by_axis, room(limit, length(controls)))
  end

  defp room(:infinity, _taken), do: :infinity
  defp room(limit, taken), do: max(limit - taken, 0)

  # One from each axis in turn, so a cap costs every axis evenly.
  defp spread(_by_axis, 0), do: []

  defp spread(by_axis, room) do
    case Enum.reject(by_axis, &(&1 == [])) do
      [] ->
        []

      lists ->
        heads = Enum.map(lists, &hd/1)
        tails = Enum.map(lists, &tl/1)

        case room do
          :infinity -> heads ++ spread(tails, :infinity)
          n -> Enum.take(heads, n) ++ spread(tails, max(n - length(heads), 0))
        end
    end
  end

  defp for_axis(:whitelist, steps, whitelist, turn, _opts) do
    for fa <- called_from(steps, turn), fa in whitelist, do: {:whitelist, whitelist -- [fa]}
  end

  defp for_axis(:result_override, _steps, _whitelist, turn, opts) do
    result = Keyword.get(opts, :override_result, {:error, :swept})
    for at <- 0..(turn - 1)//1, do: {:result_override, at, result}
  end

  defp for_axis(:kill_at, steps, _whitelist, turn, _opts) do
    for at <- turn..(length(steps) - 1)//1, do: {:kill_at, at}
  end

  defp for_axis(:latency, steps, _whitelist, turn, opts) do
    if length(steps) > turn do
      for ms <- Keyword.get(opts, :latencies, [60]), do: {:latency, ms}
    else
      []
    end
  end

  defp for_axis(:driver, _steps, _whitelist, _turn, _opts), do: []

  # A tool the run never reached after the fork point cannot change what
  # happens after it, so there is no branch for taking it away.
  defp called_from(steps, turn) do
    steps
    |> Enum.drop(turn)
    |> Enum.flat_map(fn
      %Event{action: {:call, _m, f, args}} -> [{f, length(args)}]
      _ -> []
    end)
    |> Enum.uniq()
  end

  @doc "The axis a mutation belongs to."
  @spec axis(t | nil) :: axis | nil
  def axis(nil), do: nil
  def axis(m) when is_tuple(m), do: elem(m, 0)

  @doc """
  A size for ordering mutations *within one axis* only: tools removed from
  the root whitelist, milliseconds of latency, and 1 for the rest. Sizes
  on different axes are not comparable (Open Question 3 in the design);
  `Tiller.Race` ranks by effect on the trajectory and uses this as the
  final tiebreak inside an axis.
  """
  @spec size(t | nil) :: non_neg_integer
  def size(nil), do: 0
  def size({:whitelist, list}), do: length(Tiller.Actions.root_whitelist() -- list)
  def size({:latency, ms}), do: ms
  def size(_other), do: 1

  @doc """
  Check a mutation's shape. Returns the mutation unchanged or a reason.

      iex> Tiller.Mutation.validate({:latency, 250})
      {:ok, {:latency, 250}}

      iex> Tiller.Mutation.validate({:latency, 0})
      {:error, {:invalid, :latency, {:latency, 0}}}

      iex> Tiller.Mutation.validate(:nope)
      {:error, {:unknown_mutation, :nope}}
  """
  @spec validate(term) :: {:ok, t} | {:error, term}
  def validate({:whitelist, tools} = m) when is_list(tools) do
    if Enum.all?(tools, &match?({f, a} when is_atom(f) and is_integer(a) and a >= 0, &1)),
      do: {:ok, m},
      else: {:error, {:invalid, :whitelist, tools}}
  end

  def validate({:driver, mod, _ctx} = m) when is_atom(mod), do: {:ok, m}

  def validate({:result_override, turn, _result} = m) when is_integer(turn) and turn >= 0,
    do: {:ok, m}

  def validate({:latency, ms} = m) when is_integer(ms) and ms > 0, do: {:ok, m}

  def validate({:kill_at, turn} = m) when is_integer(turn) and turn >= 0, do: {:ok, m}

  def validate(m) when is_tuple(m) and tuple_size(m) > 0 do
    axis = elem(m, 0)
    if axis in @axes, do: {:error, {:invalid, axis, m}}, else: {:error, {:unknown_mutation, m}}
  end

  def validate(other), do: {:error, {:unknown_mutation, other}}
end
