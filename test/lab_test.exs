defmodule Tiller.LabTest do
  # Steps 7 and 8: replay with injected results, resume_ctx hand-off,
  # fork under each supported mutation, and the race. No UI.
  use ExUnit.Case, async: false

  alias Tiller.{Driver, Event, FakeDriver, Lab, Mutation, Session, State, Tools}

  defmodule NoResume do
    # a driver with no resume_ctx/2: its context is used as supplied
    @behaviour Tiller.Driver
    def next_action(%{queue: [a | rest]}), do: {:action, a, %{queue: rest}}
    def next_action(_), do: :halt
  end

  defp act(f, args \\ []), do: Driver.action(f, args)

  setup do
    State.clear()
    :ok
  end

  defp root(script, id \\ "root") do
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: FakeDriver.context(script), id: id)
    {:halted, _} = Session.run_to_halt(pid)
    pid
  end

  test "replay injects the recorded result and runs nothing" do
    # spawn_subagent has a visible side effect: a child under the supervisor
    pid = root([act(:spawn_subagent, [FakeDriver, FakeDriver.context([])]), act(:echo, ["x"])])
    [%Event{result: {:ok, {:subagent_started, sub, _}}} | _] = State.events("root")
    {:halted, 0} = Session.await(sub)
    children_before = DynamicSupervisor.count_children(Tiller.Supervisor).active

    {:ok, b} = Session.fork(pid, 2, {:whitelist, Tiller.Actions.root_whitelist()}, id: "b")
    assert {:halted, 2} = Session.run_to_halt(b)

    # the branch's spawn turn carries the parent's exact result (same pid), marked replay
    assert [
             %Event{turn: 0, origin: :replay, result: {:ok, {:subagent_started, ^sub, _}}, parent_id: "root"},
             %Event{turn: 1, origin: :replay, action: {:call, Tools, :echo, ["x"]}},
             %Event{turn: 2, action: :halt}
           ] = State.events("b")

    # only the fork itself was added under the supervisor: no second subagent
    assert DynamicSupervisor.count_children(Tiller.Supervisor).active == children_before + 1
    assert :identical = Tiller.Divergence.first_diff(State.events("root"), State.events("b"))
  end

  test "resume_ctx positions the delegate at the fork turn" do
    pid = root([act(:echo, [1]), act(:echo, [2]), act(:echo, [3])])
    {:ok, b} = Session.fork(pid, 1, {:whitelist, Tiller.Actions.root_whitelist()}, id: "b")
    assert {:halted, 3} = Session.run_to_halt(b)

    assert [
             %Event{turn: 0, origin: :replay, action: {:call, _, :echo, [1]}},
             %Event{turn: 1, origin: :live, action: {:call, _, :echo, [2]}},
             %Event{turn: 2, origin: :live, action: {:call, _, :echo, [3]}},
             %Event{action: :halt}
           ] = State.events("b")
  end

  test "whitelist mutation diverges at the first forbidden live turn" do
    pid = root([act(:echo, ["plan"]), act(:fail), act(:echo, ["recover"])])
    wl = List.delete(Tiller.Actions.root_whitelist(), {:fail, 0})
    {:ok, b} = Session.fork(pid, 1, {:whitelist, wl}, id: "b")
    {:halted, 3} = Session.run_to_halt(b)

    assert {:diverged, 1, %Event{result: {:error, {:error, %RuntimeError{}, _}}}, %Event{result: {:error, :not_whitelisted}}} =
             Tiller.Divergence.first_diff(State.events("root"), State.events("b"))
  end

  test "result_override replaces a replayed result; the delegate sees the altered past" do
    pid = root([act(:echo, ["a"]), act(:fail), act(:echo, ["b"])])
    {:ok, b} = Session.fork(pid, 2, {:result_override, 1, {:ok, "no crash"}}, id: "b")
    {:halted, 3} = Session.run_to_halt(b)

    assert [_, %Event{turn: 1, origin: :replay, result: {:ok, "no crash"}}, %Event{turn: 2, origin: :live} | _] = State.events("b")
    assert {:diverged, 1, _, %Event{result: {:ok, "no crash"}}} = Tiller.Divergence.first_diff(State.events("root"), State.events("b"))

    # an override outside the replayed prefix is refused, not silently ignored
    assert {:error, {:override_outside_prefix, 2, 2}} = Session.fork(pid, 2, {:result_override, 2, {:ok, 1}})
  end

  test "driver mutation hands off to the new driver, with or without resume_ctx" do
    pid = root([act(:echo, [1]), act(:echo, [2])])

    # FakeDriver resumes: give it the parent's full script and it skips the replayed turn
    {:ok, b1} = Session.fork(pid, 1, {:driver, FakeDriver, FakeDriver.context([act(:echo, [1]), act(:echo, ["swapped"])])}, id: "b1")
    {:halted, 2} = Session.run_to_halt(b1)
    assert [%Event{origin: :replay}, %Event{origin: :live, action: {:call, _, :echo, ["swapped"]}}, _] = State.events("b1")

    # NoResume does not: its context is taken as already positioned
    {:ok, b2} = Session.fork(pid, 1, {:driver, NoResume, %{queue: [act(:echo, ["as supplied"])]}}, id: "b2")
    {:halted, 2} = Session.run_to_halt(b2)
    assert [%Event{origin: :replay}, %Event{origin: :live, action: {:call, _, :echo, ["as supplied"]}}, _] = State.events("b2")
  end

  test "latency delays live turns only" do
    pid = root([act(:echo, [1]), act(:echo, [2]), act(:echo, [3])])
    {:ok, b} = Session.fork(pid, 1, {:latency, 40}, id: "b")
    {t, {:halted, 3}} = :timer.tc(fn -> Session.run_to_halt(b) end)
    # two live turns plus the halt turn, each scheduled after 40ms
    assert div(t, 1000) >= 100
    assert %{latency: 40, fork_turn: 1, mutation: {:latency, 40}} = Map.take(Session.info(b), [:latency, :fork_turn, :mutation])
  end

  test "kill_at is refused until open question 5 is answered; turns beyond the log too" do
    pid = root([act(:echo, [1])])
    assert {:error, {:unsupported, :kill_at}} = Session.fork(pid, 1, {:kill_at, 0})
    assert {:error, {:turn_beyond_log, 5, 1}} = Session.fork(pid, 5, {:latency, 1})
    refute Mutation.supported?({:kill_at, 0})
    assert Mutation.supported?({:latency, 1})
  end

  test "race forks N branches at one turn, runs them concurrently, and reports each" do
    pid = root([act(:echo, ["plan"]), act(:fail), act(:echo, ["recover"]), act(:echo, ["done"])])

    results =
      Lab.race(pid, 1, [
        {:whitelist, Tiller.Actions.root_whitelist()},
        {:whitelist, List.delete(Tiller.Actions.root_whitelist(), {:fail, 0})},
        {:result_override, 0, {:ok, "different plan"}},
        {:driver, FakeDriver, FakeDriver.context([act(:echo, ["plan"]), act(:echo, ["skip the crash"])])},
        {:latency, 5},
        {:kill_at, 2}
      ])

    assert [
             %{mutation: {:whitelist, _}, verdict: :identical, outcome: {:halted, 4}},
             %{mutation: {:whitelist, _}, verdict: {:diverged, 1, _, %Event{result: {:error, :not_whitelisted}}}},
             %{mutation: {:result_override, 0, _}, verdict: {:diverged, 0, _, _}},
             %{mutation: {:driver, FakeDriver, _}, verdict: {:diverged, 1, _, %Event{action: {:call, _, :echo, ["skip the crash"]}}}, outcome: {:halted, 2}},
             %{mutation: {:latency, 5}, verdict: :identical},
             %{mutation: {:kill_at, 2}, error: {:unsupported, :kill_at}}
           ] = results

    # every branch is attributed to the parent and shares its replayed prefix
    for %{id: id} <- results do
      assert [%Event{parent_id: "root", turn: 0, origin: :replay} | _] = State.events(id)
    end

    assert Lab.format(results) =~ "diverged at turn 1: fail/0"
    assert Lab.format(results) =~ "kill@2: not run"
  end
end
