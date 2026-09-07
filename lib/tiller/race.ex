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

  ## The control band

  With a scripted driver a control branch reproduces its source exactly, so
  any difference at all is the mutation's doing. With a model deciding each
  turn that is no longer true: everything after the fork point is a fresh
  sample, and two branches that changed nothing can still diverge. Calling
  every such difference decisive would credit the mutation with the
  sampler's work.

  So a race measures that. Control branches (`mutation: nil`) change
  nothing, and `noise_floor/2` reports how far they drifted anyway. A
  branch is *beyond noise* when it is decisive and its trajectory differs
  in more turns than the noisiest control managed. That is the one the star
  goes to.

  A race with no controls has a floor of zero, and beyond-noise collapses
  back to decisive, which is exactly what it meant before there was a band.
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
          required(:beyond_noise) => boolean,
          required(:distance) => non_neg_integer,
          required(:first) => non_neg_integer | nil,
          optional(atom) => term
        }

  @typedoc """
  What the controls in a race did: how many finished, the largest distance
  any of them reached, and how many ended somewhere else despite changing
  nothing. A non-zero `decisive` says the run is noisy enough that outcome
  alone proves little.
  """
  @type floor :: %{
          controls: non_neg_integer,
          distance: non_neg_integer,
          decisive: non_neg_integer
        }

  @no_floor %{controls: 0, distance: 0, decisive: 0}

  @doc "Where a trajectory ended: how many turns it took and its last action + result."
  @spec outcome([Event.t()]) :: {non_neg_integer, {term, term} | nil}
  def outcome(events) do
    steps = Enum.reject(events, &Event.halt?/1)
    {length(steps), if(steps == [], do: nil, else: Event.key(List.last(steps)))}
  end

  @doc "Did the branch end somewhere other than the original?"
  @spec decisive?([Event.t()], [Event.t()]) :: boolean
  def decisive?(original, branch), do: outcome(original) != outcome(branch)

  @doc """
  How far the controls drifted with nothing changed. Only controls that ran
  to a halt count: a branch still mid-flight has had less chance to diverge
  and would understate the floor.
  """
  @spec noise_floor([Event.t()], [branch]) :: floor
  def noise_floor(original, branches) do
    controls = for b <- branches, is_nil(b.mutation), finished?(b.events), do: b.events

    %{
      controls: length(controls),
      distance: controls |> Enum.map(&Divergence.distance(original, &1)) |> Enum.max(fn -> 0 end),
      decisive: Enum.count(controls, &decisive?(original, &1))
    }
  end

  defp finished?([]), do: false
  defp finished?(events), do: Event.halt?(List.last(events))

  @doc "Score one branch against the original, optionally against a measured floor."
  @spec score([Event.t()], branch, floor) :: ranked
  def score(original, branch, floor \\ @no_floor)

  def score(original, %{events: events} = branch, floor) do
    first =
      case Divergence.first_diff(original, events) do
        :identical -> nil
        {:diverged, i, _, _} -> i
      end

    decisive = decisive?(original, events)
    distance = Divergence.distance(original, events)

    Map.merge(branch, %{
      decisive: decisive,
      # A control is the noise; it is never beyond it.
      beyond_noise: decisive and not is_nil(branch.mutation) and distance > floor.distance,
      distance: distance,
      first: first
    })
  end

  @doc """
  All branches scored and sorted: beyond the control band first, then merely
  decisive, then smallest effect. The floor is measured from the controls in
  the same list, so a race carries its own baseline.
  """
  @spec rank([Event.t()], [branch]) :: [ranked]
  def rank(original, branches) do
    floor = noise_floor(original, branches)

    branches
    |> Enum.map(&score(original, &1, floor))
    |> Enum.sort_by(&sort_key/1)
  end

  # beyond the band before merely decisive before neither; fewer differing
  # turns; later divergence; then axis order and within-axis size so sizes
  # never compare across axes.
  defp sort_key(b) do
    axis = Mutation.axis(b.mutation)
    axis_index = Enum.find_index(Mutation.axes(), &(&1 == axis)) || -1

    {not b.beyond_noise, not b.decisive, b.distance, -(b.first || 0), axis_index,
     Mutation.size(b.mutation)}
  end

  @doc """
  The smallest mutation whose effect clears the control band, or `nil` when
  none did. With no controls this is the smallest decisive mutation, as
  before.
  """
  @spec smallest_decisive([Event.t()], [branch]) :: ranked | nil
  def smallest_decisive(original, branches) do
    original |> rank(branches) |> Enum.find(& &1.beyond_noise)
  end
end
