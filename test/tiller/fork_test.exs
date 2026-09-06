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
    Session.run(pid)
    {:halted, _} = Session.await(pid)
    State.events(Session.info(pid).id)
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

  test "latency mutation slows the branch; kill_at is refused" do
    {orig, _original} = record()

    {:ok, branch} = Session.fork(orig, 0, {:latency, 30})
    {us, _} = :timer.tc(fn -> run_branch(branch) end)
    assert us >= 3 * 30_000

    assert {:error, {:unsupported, :kill_at}} = Session.fork(orig, 0, {:kill_at, 1})
    assert {:error, {:no_snapshot, 99}} = Session.fork(orig, 99, nil)
  end

  test "branches race concurrently under the supervisor" do
    {orig, original} = record()
    no_spend = List.delete(Actions.root_whitelist(), {:spend, 1})

    mutations = [
      nil,
      {:whitelist, no_spend},
      {:driver, FakeDriver, FakeDriver.context([])},
      {:latency, 20}
    ]

    branches = for m <- mutations, do: elem(Session.fork(orig, 1, m), 1)
    Enum.each(branches, &Session.run/1)
    results = Enum.map(branches, &run_branch/1)

    verdicts =
      for r <- results do
        case Divergence.first_diff(original, r) do
          :identical -> :identical
          {:diverged, i, _, _} -> {:diverged, i}
        end
      end

    assert verdicts == [:identical, {:diverged, 1}, {:diverged, 1}, :identical]

    assert Enum.map(branches, &Session.info(&1).id) == ~w(orig@1.0 orig@1.1 orig@1.2 orig@1.3)
  end
end
