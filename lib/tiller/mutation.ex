defmodule Tiller.Mutation do
  @moduledoc """
  The vocabulary of "one thing different" for a forked branch.

  A mutation is applied to exactly one branch at fork time. Two axes are
  already plumbed through `Tiller.Session` options (whitelist, driver); the
  rest need Replay and scheduler support and are Stretch in `docs/design.md`.
  This module is data and validation only; applying a mutation is the
  fork's job.
  """

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
  def size({:whitelist, list}), do: abs(length(Tiller.Actions.root_whitelist()) - length(list))
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
