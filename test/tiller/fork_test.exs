defmodule Tiller.ForkTest.Crasher do
  @moduledoc false
  @behaviour Tiller.Driver
  @impl true
  def next_action(_ctx), do: raise("deterministic driver crash")
end

defmodule Tiller.ForkTest do
  use ExUnit.Case, async: false

  alias Tiller.{Actions, Divergence, Driver, Event, FakeDriver, Session, State, ToolState}

  setup do
    Tiller.reset()
  end

  @script [
    Driver.action(:put, [:k, 1]),
    Driver.action(:spend, [4]),
    Driver.action(:get, [:k])
  ]

  defp record(id \\ "orig", actions \\ @script) do
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: FakeDriver.context(actions), id: id)
    Session.run(pid)
    {:halted, _} = Session.await(pid)
    {pid, State.events(id)}
  end

  defp run_branch(pid) do
    {:ok, id} = Session.id_of(pid)
    Session.run(pid)
    {:halted, _} = Session.await(id)
    State.events(id)
  end

  test "a control fork reproduces the source from its snapshot, in isolation" do
    {orig, original} = record()
    before = ToolState.snapshot()

    assert {:ok, branch} = Session.fork(orig, 1, nil)
    assert %{id: "orig@1.0", parent_id: "orig", mutation: nil} = Session.info(branch)

    replayed = run_branch(branch)

    # put was replayed, spend and get re-ran on the branch's own state
    # seeded from the turn-1 snapshot (k => 1, budget 10), so results match.
    assert :identical = Divergence.first_diff(original, replayed)
    assert [%Event{parent_id: "orig"} | _] = replayed
    assert ToolState.snapshot() == before
  end

  test "whitelist mutation: the branch cannot spend" do
    {orig, original} = record()
    no_spend = List.delete(Actions.root_whitelist(), {:spend, 1})

    {:ok, branch} = Session.fork(orig, 1, {:whitelist, no_spend})
    replayed = run_branch(branch)

    assert {:diverged, 1, %Event{result: {:ok, {:remaining, 6}}},
            %Event{result: {:error, :not_whitelisted}}} =
             Divergence.first_diff(original, replayed)
  end

  test "driver mutation: the branch follows a different script after the fork" do
    {orig, original} = record()
    other = FakeDriver.context([Driver.action(:echo, ["elsewhere"])])

    {:ok, branch} = Session.fork(orig, 2, {:driver, FakeDriver, other})
    replayed = run_branch(branch)

    assert {:diverged, 2, %Event{action: {:call, _, :get, _}},
            %Event{action: {:call, _, :echo, _}}} =
             Divergence.first_diff(original, replayed)
  end

  test "result override mutation: one replayed result changes, later turns still run" do
    {orig, original} = record()

    {:ok, branch} = Session.fork(orig, 2, {:result_override, 1, {:error, :budget_exceeded}})
    replayed = run_branch(branch)

    assert {:diverged, 1, _, %Event{result: {:error, :budget_exceeded}}} =
             Divergence.first_diff(original, replayed)

    assert %Event{action: {:call, _, :get, _}, result: {:ok, 1}} = Enum.at(replayed, 2)

    assert {:error, {:override_outside_prefix, 2, 2}} =
             Session.fork(orig, 2, {:result_override, 2, :x})
  end

  test "latency mutation slows the branch" do
    {orig, _original} = record()

    {:ok, branch} = Session.fork(orig, 0, {:latency, 30})
    {us, _} = :timer.tc(fn -> run_branch(branch) end)
    assert us >= 3 * 30_000

    assert {:error, {:no_snapshot, 99}} = Session.fork(orig, 99, nil)
    assert {:error, {:kill_inside_prefix, 0, 2}} = Session.fork(orig, 2, {:kill_at, 0})
  end

  test "kill mutation: the branch dies after acting, resumes, and the world saw it twice" do
    {orig, original} = record()

    {:ok, branch} = Session.fork(orig, 0, {:kill_at, 1})
    id = Session.info(branch).id
    Session.run(branch)
    assert {:halted, 3} = Session.await(id)

    # Restarted under a new pid, same id, resumed at the killed turn.
    resumed = Session.whereis(id)
    assert is_pid(resumed) and resumed != branch
    assert %{resumed: true, turns: 3, kill_at: 1} = Session.info(id)

    # spend(4) ran before the kill and again after the resume: the log has
    # it once, the budget paid twice.
    replayed = State.events(id)

    assert {:diverged, 1, %Event{result: {:ok, {:remaining, 6}}},
            %Event{result: {:ok, {:remaining, 2}}}} =
             Divergence.first_diff(original, replayed)

    assert Enum.map(replayed, & &1.action) == Enum.map(original, & &1.action)
    assert ToolState.snapshot() == ToolState.snapshot(ToolState)
  end

  test "kill at turn 0 of a turn-0 fork: a branch with nothing logged yet still comes back" do
    # Turn 0 spends, so the double side effect is visible in the budget.
    {orig, original} =
      record("orig", [Driver.action(:spend, [4]), Driver.action(:get, [:k])])

    {:ok, branch} = Session.fork(orig, 0, {:kill_at, 0})
    id = Session.info(branch).id
    Session.run(branch)

    # The branch dies before appending anything, so the event count cannot
    # be what says a turn was in flight. The snapshot parked before the
    # turn is, and the resume runs from it.
    assert {:halted, 2} = Session.await(id)
    assert %{resumed: true, turns: 2, kill_at: 0} = Session.info(id)

    replayed = State.events(id)

    # spend(4) ran before the kill and again after the resume: the log has
    # it once, the budget paid twice.
    assert {:diverged, 0, %Event{result: {:ok, {:remaining, 6}}},
            %Event{result: {:ok, {:remaining, 2}}}} =
             Divergence.first_diff(original, replayed)

    assert Enum.map(replayed, & &1.action) == Enum.map(original, & &1.action)
  end

  test "a session that never ran a turn is not a resume: it has no snapshot to come back to" do
    {:ok, pid} =
      Session.start_link(driver: FakeDriver, ctx: FakeDriver.context(@script), id: "idle")

    # Started, never run: the store has its profile and nothing else.
    assert State.events("idle") == []
    assert State.snapshot("idle", 0) == :error

    Process.unlink(pid)
    Process.exit(pid, :kill)
    wait_until(fn -> is_nil(Session.whereis("idle")) end)

    # Nothing to come back to, so it is not brought back. The snapshot says
    # a turn was in flight; without one there was no turn.
    assert {:error, :no_resume_point} = Session.resume("idle")
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  test "a control fork through a spawn turn stays identical" do
    sub = FakeDriver.context([Driver.action(:echo, ["sub"])])

    {orig, original} =
      record("orig", [
        Driver.action(:put, [:k, 1]),
        Driver.action(:spawn_subagent, [FakeDriver, sub])
      ])

    assert {:halted, 1} = Session.await("orig.1")

    {:ok, branch} = Session.fork(orig, 1, nil)
    replayed = run_branch(branch)

    assert :identical = Divergence.first_diff(original, replayed)
    assert {:halted, 1} = Session.await("orig@1.0.1")
  end

  test "a branch that keeps crashing is halted after a few resumes, not restarted forever" do
    {orig, _original} = record()
    {:ok, branch} = Session.fork(orig, 1, {:driver, Tiller.ForkTest.Crasher, nil})
    {:ok, id} = Session.id_of(branch)
    Session.run(branch)

    assert {:halted, 1} = Session.await(id)
    assert %{resumed: true, status: {:halted, 1}} = Session.info(id)
    assert Enum.count(State.events(id), &Event.halt?/1) == 1
  end

  test "branches race concurrently under the supervisor" do
    {orig, original} = record()
    no_spend = List.delete(Actions.root_whitelist(), {:spend, 1})

    mutations = [
      nil,
      {:whitelist, no_spend},
      {:driver, FakeDriver, FakeDriver.context([])},
      {:latency, 20},
      {:kill_at, 2}
    ]

    branches = for m <- mutations, do: elem(Session.fork(orig, 1, m), 1)
    ids = Enum.map(branches, &elem(Session.id_of(&1), 1))
    Enum.each(branches, &Session.run/1)

    results =
      for id <- ids do
        {:halted, _} = Session.await(id)
        State.events(id)
      end

    verdicts =
      for r <- results do
        case Divergence.first_diff(original, r) do
          :identical -> :identical
          {:diverged, i, _, _} -> {:diverged, i}
        end
      end

    assert verdicts == [:identical, {:diverged, 1}, {:diverged, 1}, :identical, :identical]

    assert Enum.map(results, &List.first(&1).session_id) ==
             ~w(orig@1.0 orig@1.1 orig@1.2 orig@1.3 orig@1.4)
  end
end
