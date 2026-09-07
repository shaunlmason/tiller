defmodule Tiller.SweepTest do
  @moduledoc "Tiller.Mutation.sweep/4: pure, over a recorded trajectory."
  use ExUnit.Case, async: true

  alias Tiller.{Driver, Event, Mutation}

  defp event(turn, action, result \\ {:ok, :x}) do
    %Event{
      seq: turn + 1,
      session_id: "r",
      parent_id: nil,
      turn: turn,
      action: action,
      result: result
    }
  end

  # put, spend, get, then halt
  defp run do
    [
      event(0, Driver.action(:put, [:k, 1])),
      event(1, Driver.action(:spend, [4])),
      event(2, Driver.action(:get, [:k])),
      %Event{
        seq: 4,
        session_id: "r",
        parent_id: nil,
        turn: 3,
        action: :halt,
        result: {:halted, 3}
      }
    ]
  end

  @whitelist [{:put, 2}, {:spend, 1}, {:get, 1}, {:echo, 1}]

  test "covers every axis at the points this run reaches" do
    sweep = Mutation.sweep(run(), @whitelist, 1)

    assert [nil | rest] = sweep

    # only tools the run called at or after turn 1: spend and get
    assert [{:whitelist, without_spend}, {:whitelist, without_get}] =
             Enum.filter(rest, &match?({:whitelist, _}, &1))

    assert {:spend, 1} not in without_spend
    assert {:get, 1} not in without_get
    # put was called before the fork, echo never: no branch takes them away
    assert {:put, 2} in without_spend
    assert {:echo, 1} in without_spend

    # only the replayed prefix can be overridden
    assert [{:result_override, 0, {:error, :swept}}] =
             Enum.filter(rest, &match?({:result_override, _, _}, &1))

    # a kill for each turn the branch will live through
    assert [{:kill_at, 1}, {:kill_at, 2}] = Enum.filter(rest, &match?({:kill_at, _}, &1))

    assert [{:latency, 60}] = Enum.filter(rest, &match?({:latency, _}, &1))
  end

  test "a fork at turn 0 has nothing to override and kills every turn" do
    sweep = Mutation.sweep(run(), @whitelist, 0)

    assert [] = Enum.filter(sweep, &match?({:result_override, _, _}, &1))

    assert [{:kill_at, 0}, {:kill_at, 1}, {:kill_at, 2}] =
             Enum.filter(sweep, &match?({:kill_at, _}, &1))

    # put is now reachable from the fork point, so it gets a branch
    assert 3 == Enum.count(sweep, &match?({:whitelist, _}, &1))
  end

  test "options pick the axes, the controls, and the latencies" do
    sweep = Mutation.sweep(run(), @whitelist, 1, axes: [:kill_at], controls: 2)
    assert [nil, nil, {:kill_at, 1}, {:kill_at, 2}] = sweep

    sweep =
      Mutation.sweep(run(), @whitelist, 1, axes: [:latency], controls: 0, latencies: [5, 500])

    assert [{:latency, 5}, {:latency, 500}] = sweep
  end

  test "a long run is capped, and the cap spreads across axes" do
    long =
      for turn <- 0..39 do
        event(turn, Driver.action(:echo, [turn]))
      end ++
        [
          %Event{
            seq: 41,
            session_id: "r",
            parent_id: nil,
            turn: 40,
            action: :halt,
            result: {:halted, 40}
          }
        ]

    all = Mutation.sweep(long, @whitelist, 20, limit: :infinity)
    assert length(all) > 40

    capped = Mutation.sweep(long, @whitelist, 20)
    assert length(capped) == 24

    axes =
      capped |> Enum.reject(&is_nil/1) |> Enum.map(&Mutation.axis/1) |> Enum.uniq() |> Enum.sort()

    # every axis this run reaches is represented, not just the one that
    # generated the most
    assert axes == [:kill_at, :latency, :result_override, :whitelist]
    assert 1 == Enum.count(capped, &is_nil/1)
  end

  test "every generated mutation validates" do
    for m <- Mutation.sweep(run(), @whitelist, 2), m != nil do
      assert {:ok, ^m} = Mutation.validate(m)
    end
  end

  test "a run with no turns left to fork sweeps to controls only" do
    assert [nil] = Mutation.sweep([], @whitelist, 0)
    # forking at the end: nothing to remove, kill, or slow down
    assert [nil, {:result_override, 0, _}, {:result_override, 1, _}, {:result_override, 2, _}] =
             Mutation.sweep(run(), @whitelist, 3)
  end
end
