defmodule Tiller.DivergenceTest do
  use ExUnit.Case, async: true

  alias Tiller.{Divergence, Driver, Tools}

  doctest Divergence

  # Hand-written events in the shape Tiller.State records them:
  # {action, result} pairs followed by a terminal {:halt, turns}.
  @echo_hi {Driver.action(:echo, ["hi"]), {:ok, "echo: \"hi\""}}
  @echo_bye {Driver.action(:echo, ["bye"]), {:ok, "echo: \"bye\""}}
  @fail {Driver.action(:fail, []), {:error, :boom}}

  test "identical prefix, then a different tool" do
    left = [@echo_hi, @echo_bye, {:halt, 2}]
    right = [@echo_hi, @fail, {:halt, 2}]

    assert {:diverged, 1, @echo_bye, @fail} = Divergence.first_diff(left, right)
  end

  test "identical actions with different results" do
    action = Driver.action(:echo, ["hi"])
    left = [{action, {:ok, "echo: \"hi\""}}, {:halt, 1}]
    right = [{action, {:error, :not_whitelisted}}, {:halt, 1}]

    assert {:diverged, 0, {^action, {:ok, _}}, {^action, {:error, :not_whitelisted}}} =
             Divergence.first_diff(left, right)

    assert action == {:call, Tools, :echo, ["hi"]}
  end

  test "one branch halts early" do
    left = [@echo_hi, {:halt, 1}]
    right = [@echo_hi, @echo_bye, {:halt, 2}]

    # :halt is an event, so an early halt diverges against the other branch's
    # next action rather than reading as a missing entry.
    assert {:diverged, 1, {:halt, 1}, @echo_bye} = Divergence.first_diff(left, right)

    # A branch that never logged :halt (still running, or crashed) is the nil
    # case: it has no event at that index at all.
    assert {:diverged, 1, nil, @echo_bye} = Divergence.first_diff([@echo_hi], right)
    assert {:diverged, 1, @echo_bye, nil} = Divergence.first_diff(right, [@echo_hi])
  end

  test "events are compared on action and result, not branch identity" do
    alias Tiller.Event

    {a, r} = @echo_hi
    left = [%Event{seq: 1, session_id: "a", parent_id: nil, turn: 0, action: a, result: r}]
    right = [%Event{seq: 7, session_id: "b", parent_id: "a", turn: 0, action: a, result: r}]

    assert :identical = Divergence.first_diff(left, right)

    left_halt = left ++ [Event.halt(2, "a", nil, 1)]
    {a2, r2} = @echo_bye

    right_more =
      right ++ [%Event{seq: 8, session_id: "b", parent_id: "a", turn: 1, action: a2, result: r2}]

    assert {:diverged, 1, %Event{action: :halt}, %Event{action: ^a2}} =
             Divergence.first_diff(left_halt, right_more)
  end

  test "identical trajectories" do
    run = [@echo_hi, @echo_bye, {:halt, 2}]
    assert :identical = Divergence.first_diff(run, run)
    assert :identical = Divergence.first_diff([], [])
  end
end
