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
