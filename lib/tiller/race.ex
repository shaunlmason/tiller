defmodule Tiller.Race do
  @moduledoc """
  Rank forked branches against the original they came from.

  A mutation is *decisive* if the branch ends somewhere else: a different
  last action or result, or a different number of turns. A mutation that
  only changes the path is a perturbation, not a decision.

  "Smallest decisive mutation" (Open Question 3 in `docs/design.md`) is
  measured by effect, not by the mutation: among decisive branches, the one
  whose trajectory differs from the original in the fewest turns wins, a
  later first divergence breaks ties, and `Tiller.Mutation.size/1` breaks
  ties only between mutations on the same axis. No cross-axis weights.
  """

  alias Tiller.{Divergence, Event, Mutation}

  @type branch :: %{
          required(:mutation) => Mutation.t() | nil,
          required(:events) => [Event.t()],
          optional(atom) => term
        }

  @type ranked :: %{
          required(:mutation) => Mutation.t() | nil,
          required(:events) => [Event.t()],
          required(:decisive) => boolean,
          required(:distance) => non_neg_integer,
          required(:first) => non_neg_integer | nil,
          optional(atom) => term
        }

  @doc "Where a trajectory ended: how many turns it took and its last action + result."
  @spec outcome([Event.t()]) :: {non_neg_integer, {term, term} | nil}
  def outcome(events) do
    steps = Enum.reject(events, &Event.halt?/1)
    {length(steps), if(steps == [], do: nil, else: Event.key(List.last(steps)))}
  end

  @doc "Did the branch end somewhere other than the original?"
  @spec decisive?([Event.t()], [Event.t()]) :: boolean
  def decisive?(original, branch), do: outcome(original) != outcome(branch)

  @doc "Score one branch against the original."
  @spec score([Event.t()], branch) :: ranked
  def score(original, %{events: events} = branch) do
    first =
      case Divergence.first_diff(original, events) do
        :identical -> nil
        {:diverged, i, _, _} -> i
      end

    Map.merge(branch, %{
      decisive: decisive?(original, events),
      distance: Divergence.distance(original, events),
      first: first
    })
  end

  @doc "All branches scored and sorted: decisive first, then smallest effect."
  @spec rank([Event.t()], [branch]) :: [ranked]
  def rank(original, branches) do
    branches
    |> Enum.map(&score(original, &1))
    |> Enum.sort_by(&sort_key/1)
  end

  # decisive before not; fewer differing turns; later divergence; then
  # axis order and within-axis size so sizes never compare across axes.
  defp sort_key(b) do
    axis = Mutation.axis(b.mutation)
    axis_index = Enum.find_index(Mutation.axes(), &(&1 == axis)) || -1
    {not b.decisive, b.distance, -(b.first || 0), axis_index, Mutation.size(b.mutation)}
  end

  @doc "The decisive branch with the smallest effect, if any branch was decisive."
  @spec smallest_decisive([Event.t()], [branch]) :: ranked | nil
  def smallest_decisive(original, branches) do
    original |> rank(branches) |> Enum.find(& &1.decisive)
  end
end
