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
    Tiller.Lab.reset()
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

  test "kill_at: the branch dies before the turn and the supervisor brings it back resumed" do
    pid = root([act(:echo, ["plan"]), act(:fail), act(:echo, ["recover"]), act(:echo, ["done"])])
    {:ok, b} = Session.fork(pid, 1, {:kill_at, 2}, id: "b")
    :ok = Session.run(b)

    # await follows the resume chain and reports the final session's turns
    assert {:halted, 4} = Session.await("b")
    refute Process.alive?(b)
    assert Session.whereis("b") == nil

    # the dead session recorded turns 0 (replayed) and 1 (live), then nothing: no halt
    assert [%Event{turn: 0, origin: :replay}, %Event{turn: 1, origin: :live, action: {:call, _, :fail, []}}] = State.events("b")

    # its packet names the successor, and the successor is a fork of it at the death turn
    assert %{resumed_by: r} = State.get_session("b")
    assert String.starts_with?(r, "b/r")
    assert [^r] = Session.lineage("b") -- ["b"]
    assert %{parent_id: "b", resumed_from: "b", fork_turn: 2, mutation: {:resumed, 2}} = Session.info(Session.whereis(r))

    assert [
             %Event{session_id: ^r, parent_id: "b", turn: 0, origin: :replay},
             %Event{turn: 1, origin: :replay, action: {:call, _, :fail, []}},
             %Event{turn: 2, origin: :live, action: {:call, _, :echo, ["recover"]}},
             %Event{turn: 3, origin: :live, action: {:call, _, :echo, ["done"]}},
             %Event{action: :halt, result: {:halted, 4}}
           ] = State.events(r)

    # nothing recorded was lost or re-executed: the resumed trajectory equals the parent's
    assert :identical = Tiller.Divergence.first_diff(State.events("root"), State.events(r))
  end

  test "kill before the fork turn and turns beyond the log are refused" do
    pid = root([act(:echo, [1])])
    assert {:error, {:kill_before_fork, 0, 1}} = Session.fork(pid, 1, {:kill_at, 0})
    assert {:error, {:turn_beyond_log, 5, 1}} = Session.fork(pid, 5, {:latency, 1})
    assert Mutation.supported?({:kill_at, 1})
    assert Mutation.supported?({:latency, 1})
  end

  test "a resumed session under a second kill resumes again from the latest log" do
    # kill the resumed session too: the chain grows and the final trajectory is still whole
    pid = root([act(:echo, [1]), act(:echo, [2]), act(:echo, [3]), act(:echo, [4])])
    {:ok, b} = Session.fork(pid, 0, {:kill_at, 1}, id: "k")
    :ok = Session.run(b)
    {:halted, 4} = Session.await("k")
    [r1] = Session.lineage("k") -- ["k"]

    # a second, external kill while the resumed session is halted: transient restarts it
    Process.exit(Session.whereis(r1), :kill)
    eventually(fn -> length(Session.lineage("k")) == 3 end)
    [^r1, r2] = Session.lineage("k") -- ["k"]
    assert {:halted, 4} = Session.await("k")
    assert Enum.all?(State.events(r2), &(&1.origin == :replay or &1.action == :halt))
    assert :identical = Tiller.Divergence.first_diff(State.events("root"), State.events(r2))
  end

  test "sweep generates one branch per axis point that could matter, and clusters group the outcome" do
    pid = root([act(:echo, ["plan"]), act(:fail), act(:echo, ["recover"]), act(:echo, ["done"])])
    mutations = Lab.sweep(pid, 1)

    # tools the run called at or after turn 1: fail/0 and echo/1 (two branches); one replayed turn to
    # override; live turns 1..3 to kill; two latencies
    assert Enum.count(mutations, &match?({:whitelist, _}, &1)) == 2
    assert [{:result_override, 0, _}] = Enum.filter(mutations, &match?({:result_override, _, _}, &1))
    assert [{:kill_at, 1}, {:kill_at, 2}, {:kill_at, 3}] = Enum.filter(mutations, &match?({:kill_at, _}, &1))
    assert [{:latency, 50}, {:latency, 250}] = Enum.filter(mutations, &match?({:latency, _}, &1))
    assert Lab.sweep(pid, 1, axes: [:kill]) |> length() == 3

    results = Lab.race(pid, 1, mutations, timeout: 10_000)
    clusters = Lab.clusters(results)
    keys = Enum.map(clusters, &elem(&1, 0))
    # the two whitelist removals diverge at turn 1 (fail refused) and turn 2 (echo refused);
    # the override diverges at 0; kills and latencies come back identical
    assert [{:diverged, 2}, {:diverged, 1}, {:diverged, 0}, :identical] = keys
    assert length(Keyword.get(clusters, :identical)) == 5
    assert Enum.all?(results, &(&1.outcome == {:halted, 4} or &1.outcome == {:halted, 4}))
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
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
             %{mutation: {:kill_at, 2}, verdict: :identical, outcome: {:halted, 4}, lineage: [killed, resumed]}
           ] = results

    assert String.starts_with?(resumed, killed <> "/r")

    # every branch's first session is attributed to the parent and shares its replayed prefix
    for %{lineage: [first | _]} <- results do
      assert [%Event{parent_id: "root", turn: 0, origin: :replay} | _] = State.events(first)
    end

    assert Lab.format(results) =~ "diverged at turn 1: fail/0"
    assert Lab.format(results) =~ "kill@2 [#{killed} -> #{resumed}] {:halted, 4}: identical"
  end

  test "rank: later divergence is the smaller change; same turn across axes ties; no effect is unranked" do
    pid = root([act(:echo, ["plan"]), act(:fail), act(:echo, ["recover"]), act(:echo, ["done"])])

    results =
      Lab.race(pid, 1, [
        {:whitelist, Tiller.Actions.root_whitelist()},
        {:whitelist, List.delete(Tiller.Actions.root_whitelist(), {:fail, 0})},
        {:result_override, 0, {:ok, "a different plan"}},
        {:driver, FakeDriver, FakeDriver.context([act(:echo, ["plan"]), act(:echo, ["skip the crash"])])},
        {:kill_at, 2}
      ])

    assert [nil, 1, 2, 1, nil] = Enum.map(results, & &1.rank)

    # ranked/1 sorts by rank, no-effect last, in stable mutation order within a tie
    assert [{:whitelist, _}, {:driver, _, _}, {:result_override, 0, _}, {:whitelist, _}, {:kill_at, 2}] =
             results |> Lab.ranked() |> Enum.map(& &1.mutation)

    assert [%{mutation: {:whitelist, _}}, %{mutation: {:driver, _, _}}] = Lab.smallest(results)
    assert Lab.format(results) =~ ~r/^  #1  whitelist=root-fail\/0/m
    assert Lab.format(results) =~ ~r/^  --  kill@2/m
  end

  test "rank: on one axis and one turn, the smaller mutation ranks first" do
    pid = root([act(:echo, ["a"]), act(:fail), act(:echo, ["b"])])
    wl = Tiller.Actions.root_whitelist()

    results =
      Lab.race(pid, 1, [
        {:whitelist, wl -- [{:fail, 0}, {:echo, 1}]},
        {:whitelist, wl -- [{:fail, 0}]},
        {:latency, 1}
      ])

    # both whitelist branches diverge at turn 1 (fail refused); the one that removed less ranks first
    assert [2, 1, nil] = Enum.map(results, & &1.rank)
    assert [2, 1] = Enum.map(Enum.take(results, 2), &Mutation.size(&1.mutation))
    assert Mutation.size({:latency, 250}) == 250
    assert Mutation.axis({:result_override, 0, :x}) == :result_override
    assert Lab.rank([]) == []
  end
end
