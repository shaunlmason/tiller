defmodule Tiller.RaceTest do
  use ExUnit.Case, async: true

  alias Tiller.{Divergence, Driver, Race}

  @put {Driver.action(:put, [:k, 1]), {:ok, {:put, :k}}}
  @spend {Driver.action(:spend, [4]), {:ok, {:remaining, 6}}}
  @get {Driver.action(:get, [:k]), {:ok, 1}}
  @original [@put, @spend, @get, {:halt, 3}]

  # A four-step run, so a control can drift in the middle without changing
  # where it ended: with only three steps the last one is the outcome.
  @echo_a {Driver.action(:echo, ["a"]), {:ok, "a"}}
  @echo_b {Driver.action(:echo, ["b"]), {:ok, "b"}}
  @long [@put, @spend, @echo_a, @get, {:halt, 4}]

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

  describe "the control band" do
    defp control(events), do: %{mutation: nil, events: events}
    defp mutated(m, events), do: %{mutation: m, events: events}

    test "quiet controls leave the floor at zero and beyond-noise means decisive" do
      ended_elsewhere =
        mutated(
          {:whitelist, [{:put, 2}]},
          [@put, @spend, {Driver.action(:get, [:k]), {:error, :not_whitelisted}}, {:halt, 3}]
        )

      branches = [control(@original), control(@original), ended_elsewhere]
      floor = Race.noise_floor(@original, branches)

      assert %{controls: 2, distance: 0, decisive: 0} = floor
      assert %{beyond_noise: true} = Race.score(@original, ended_elsewhere, floor)
      assert %{mutation: {:whitelist, _}} = Race.smallest_decisive(@original, branches)
    end

    test "a drifting control raises the floor, and a mutation inside it loses the star" do
      # Changed nothing, took a different path for two turns, ended in the
      # same place after the same number of steps.
      drifted = control([@put, @echo_b, @echo_b, @get, {:halt, 4}])

      # Ends elsewhere, but differs in fewer turns than that control did.
      inside =
        mutated(
          {:latency, 50},
          [@put, @spend, @echo_a, {Driver.action(:get, [:k]), {:error, :nope}}, {:halt, 4}]
        )

      # Ends elsewhere and differs in more turns than the control did.
      outside = mutated({:kill_at, 1}, [@echo_a, @echo_b, @echo_a, {:halt, 3}])

      branches = [control(@long), drifted, inside, outside]
      floor = Race.noise_floor(@long, branches)

      assert %{controls: 2, distance: 2, decisive: 0} = floor

      assert %{decisive: true, beyond_noise: false, distance: 1} =
               Race.score(@long, inside, floor)

      assert %{decisive: true, beyond_noise: true} = Race.score(@long, outside, floor)

      # The star goes to the one that cleared the band, not to the smaller
      # effect sitting inside it.
      assert %{mutation: {:kill_at, 1}} = Race.smallest_decisive(@long, branches)
      assert [%{mutation: {:kill_at, 1}} | _] = Race.rank(@long, branches)
    end

    test "a control that ends elsewhere is counted, and is never itself beyond noise" do
      rogue = control([@put, @spend, {Driver.action(:get, [:k]), {:error, :flake}}, {:halt, 3}])
      branches = [control(@original), rogue]
      floor = Race.noise_floor(@original, branches)

      assert %{controls: 2, distance: 1, decisive: 1} = floor
      assert %{decisive: true, beyond_noise: false} = Race.score(@original, rogue, floor)
      assert nil == Race.smallest_decisive(@original, branches)
    end

    test "an unfinished control does not count: it has had less chance to drift" do
      running = control([@put, @echo_a])
      assert %{controls: 0, distance: 0} = Race.noise_floor(@original, [running])

      assert %{controls: 1, distance: 3} =
               Race.noise_floor(@original, [control([@put, @echo_a, {:halt, 2}])])
    end
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
