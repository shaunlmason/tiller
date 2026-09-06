defmodule Tiller.DivergenceTest do
  # The spike's three cases, then the projection edges that make the
  # answer trustworthy on real logs. No GenServers, no async: just terms.
  use ExUnit.Case, async: true

  alias Tiller.{Divergence, Driver, Event, Tools}

  defp act(f, args \\ []), do: Driver.action(f, args)

  test "identical prefixes, then a different tool" do
    left = [{act(:echo, ["a"]), {:ok, "echo: \"a\""}}, {act(:echo, ["b"]), {:ok, "echo: \"b\""}}, {act(:fail), {:error, :x}}, {:halt, 3}]
    right = [{act(:echo, ["a"]), {:ok, "echo: \"a\""}}, {act(:echo, ["b"]), {:ok, "echo: \"b\""}}, {act(:echo, ["c"]), {:ok, "echo: \"c\""}}, {:halt, 3}]

    assert {:diverged, 2, {{:call, Tools, :fail, []}, _}, {{:call, Tools, :echo, ["c"]}, _}} =
             Divergence.first_diff(left, right)
  end

  test "identical actions, different results" do
    left = [{act(:seed_claim, ["os-1"]), {:ok, {:ok, %{"claim_token" => "t"}}}}, {:halt, 1}]
    right = [{act(:seed_claim, ["os-1"]), {:ok, {:refused, %{"error" => "contention", "exit" => 2}}}}, {:halt, 1}]

    assert {:diverged, 0, {_, {:ok, {:ok, _}}}, {_, {:ok, {:refused, _}}}} = Divergence.first_diff(left, right)
  end

  test "one branch halts early" do
    left = [{act(:echo, ["a"]), {:ok, "x"}}, {act(:echo, ["b"]), {:ok, "y"}}, {:halt, 2}]
    right = [{act(:echo, ["a"]), {:ok, "x"}}, {:halt, 1}]

    # turn 1: left still acting, right already halted
    assert {:diverged, 1, {{:call, Tools, :echo, ["b"]}, _}, {:halt, 1}} = Divergence.first_diff(left, right)

    # a branch that simply stops recording (no halt yet) diverges at the turn it lacks
    assert {:diverged, 1, {{:call, Tools, :echo, ["b"]}, _}, nil} = Divergence.first_diff(left, [hd(right)])
    assert {:diverged, 1, nil, {{:call, Tools, :echo, ["b"]}, _}} = Divergence.first_diff([hd(right)], left)
  end

  test "identical trajectories are identical, including empty ones" do
    log = [{act(:echo, ["a"]), {:ok, "x"}}, {:halt, 1}]
    assert :identical = Divergence.first_diff(log, log)
    assert :identical = Divergence.first_diff([], [])
  end

  test "pids and stack traces are not divergence" do
    st = [{Tiller.Tools, :fail, 0, [file: ~c"lib/tiller/tools.ex", line: 17]}]
    st2 = [{Tiller.Tools, :fail, 0, [file: ~c"lib/tiller/tools.ex", line: 99]}]

    left = [
      {act(:spawn_subagent, [Tiller.FakeDriver, %{queue: []}]), {:ok, {:subagent_done, self()}}},
      {act(:fail), {:error, {:error, %RuntimeError{message: "simulated tool crash"}, st}}},
      {:halt, 2}
    ]

    right = [
      {act(:spawn_subagent, [Tiller.FakeDriver, %{queue: []}]), {:ok, {:subagent_done, spawn(fn -> :ok end)}}},
      {act(:fail), {:error, {:error, %RuntimeError{message: "simulated tool crash"}, st2}}},
      {:halt, 2}
    ]

    assert :identical = Divergence.first_diff(left, right)

    # but a different crash reason is
    other = List.replace_at(right, 1, {act(:fail), {:error, {:error, %RuntimeError{message: "other"}, st2}}})
    assert {:diverged, 1, _, _} = Divergence.first_diff(left, other)
  end

  test "events from different sessions compare by turn content, not identity" do
    log = [{act(:echo, ["a"]), {:ok, "x"}}, {act(:echo, ["b"]), {:ok, "y"}}, {:halt, 2}]
    root = Event.from_log(log, "root")
    branch = Event.from_log(log, "branch-1", parent_id: "root")

    assert Enum.map(root, & &1.turn) == [0, 1, 2]
    assert %Event{action: :halt, result: {:halted, 2}} = List.last(branch)
    assert :identical = Divergence.first_diff(root, branch)

    # and mixed shapes are fine: events on one side, raw log on the other
    assert :identical = Divergence.first_diff(root, log)
  end

  test "a custom key projects away domain noise" do
    left = [{act(:seed_get, ["os-1"]), {:ok, {:ok, %{"card" => %{"updated_at" => "10:00"}}}}}]
    right = [{act(:seed_get, ["os-1"]), {:ok, {:ok, %{"card" => %{"updated_at" => "10:01"}}}}}]

    assert {:diverged, 0, _, _} = Divergence.first_diff(left, right)

    # a projection that drops the card's timestamps before the default scrub
    drop_ts = fn
      {a, {:ok, {tag, %{"card" => card} = env}}} ->
        Divergence.normalize({a, {:ok, {tag, %{env | "card" => Map.drop(card, ["updated_at"])}}}})

      pair ->
        Divergence.normalize(pair)
    end

    assert :identical = Divergence.first_diff(left, right, key: drop_ts)

    # or the bluntest one: actions only
    assert :identical = Divergence.first_diff(left, right, key: fn {a, _r} -> a end)
  end

  test "report ranks nothing, just answers per branch in order" do
    root = [{act(:echo, ["a"]), {:ok, "x"}}, {act(:echo, ["b"]), {:ok, "y"}}, {:halt, 2}]
    same = root
    early = [{act(:echo, ["a"]), {:ok, "x"}}, {:halt, 1}]
    other = [{act(:echo, ["z"]), {:ok, "z"}}, {:halt, 1}]

    assert [{0, :identical}, {1, {:diverged, 1, _, _}}, {2, {:diverged, 0, _, _}}] =
             Divergence.report(root, [same, early, other])
  end
end
