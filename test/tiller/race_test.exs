defmodule Tiller.RaceTest do
  use ExUnit.Case, async: true

  alias Tiller.{Divergence, Driver, Race}

  @put {Driver.action(:put, [:k, 1]), {:ok, {:put, :k}}}
  @spend {Driver.action(:spend, [4]), {:ok, {:remaining, 6}}}
  @get {Driver.action(:get, [:k]), {:ok, 1}}
  @original [@put, @spend, @get, {:halt, 3}]

  test "distance counts differing and missing positions" do
    assert Divergence.distance(@original, @original) == 0

    assert Divergence.distance(@original, [
             @put,
             {Driver.action(:spend, [4]), {:error, :x}},
             @get,
             {:halt, 3}
           ]) == 1

    assert Divergence.distance(@original, [@put, {:halt, 1}]) == 3
  end

  test "a path-only perturbation is not decisive; a different ending is" do
    perturbed = [{Driver.action(:put, [:k, 1]), {:error, :disk_full}}, @spend, @get, {:halt, 3}]
    refute Race.decisive?(@original, perturbed)

    ended_elsewhere = [
      @put,
      @spend,
      {Driver.action(:get, [:k]), {:error, :not_whitelisted}},
      {:halt, 3}
    ]

    assert Race.decisive?(@original, ended_elsewhere)
    assert Race.decisive?(@original, [@put, {:halt, 1}])
  end

  test "rank: decisive first, then fewest differing turns, then later divergence, then within-axis size" do
    branches = [
      %{mutation: nil, events: @original},
      %{mutation: {:latency, 50}, events: @original},
      # decisive, differs in 1 turn (the last)
      %{
        mutation: {:whitelist, [{:put, 2}, {:spend, 1}]},
        events: [
          @put,
          @spend,
          {Driver.action(:get, [:k]), {:error, :not_whitelisted}},
          {:halt, 3}
        ]
      },
      # decisive, differs in 3 turns (new script from turn 1)
      %{
        mutation: {:driver, Tiller.FakeDriver, %{}},
        events: [@put, {Driver.action(:echo, ["x"]), {:ok, "x"}}, {:halt, 2}]
      },
      # not decisive, differs in 1 turn (turn 0)
      %{
        mutation: {:result_override, 0, {:error, :disk_full}},
        events: [{Driver.action(:put, [:k, 1]), {:error, :disk_full}}, @spend, @get, {:halt, 3}]
      },
      # not decisive, differs in 1 turn (turn 1): later divergence ranks above turn 0
      %{
        mutation: {:kill_at, 1},
        events: [@put, {Driver.action(:spend, [4]), {:ok, {:remaining, 2}}}, @get, {:halt, 3}]
      }
    ]

    ranked = Race.rank(@original, branches)

    assert Enum.map(
             ranked,
             &{Tiller.Mutation.axis(&1.mutation), &1.decisive, &1.distance, &1.first}
           ) == [
             {:whitelist, true, 1, 2},
             {:driver, true, 3, 1},
             {nil, false, 0, nil},
             {:latency, false, 0, nil},
             {:kill_at, false, 1, 1},
             {:result_override, false, 1, 0}
           ]

    assert %{mutation: {:whitelist, _}} = Race.smallest_decisive(@original, branches)
    assert nil == Race.smallest_decisive(@original, Enum.take(branches, 2))
  end
end
