defmodule Tiller.Driver.ReplayTest do
  use ExUnit.Case, async: false

  alias Tiller.{Divergence, Driver, Event, FakeDriver, Session, State, ToolState}
  alias Tiller.Driver.Replay

  setup do
    Tiller.reset()
  end

  defp record(id, actions) do
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: FakeDriver.context(actions), id: id)
    Session.run(pid)
    {:halted, _} = Session.await(pid)
    State.events(id)
  end

  defp replay(id, ctx) do
    {:ok, pid} = Session.start_link(driver: Replay, ctx: ctx, id: id)
    Session.run(pid)
    {:halted, _} = Session.await(pid)
    State.events(id)
  end

  @script [
    Driver.action(:put, [:k, 1]),
    Driver.action(:spend, [4]),
    Driver.action(:get, [:k])
  ]

  test "a full replay reproduces the trajectory without running any tool" do
    original = record("orig", @script)
    ToolState.reset()

    replayed = replay("branch", Replay.context(original, FakeDriver, FakeDriver.context([])))

    assert :identical = Divergence.first_diff(original, replayed)
    assert [%Event{seq: 5, session_id: "branch", turn: 0} | _] = replayed
    assert %Event{action: :halt, result: {:halted, 3}} = List.last(replayed)
    assert ToolState.snapshot() == ToolState.initial()
  end

  test "replays a prefix, then the delegate takes over" do
    original = record("orig", @script)
    ToolState.reset()
    delegate = FakeDriver.context([Driver.action(:echo, ["forked"])])

    replayed = replay("branch", Replay.context(original, FakeDriver, delegate, turn: 1))

    assert {:diverged, 1, %Event{action: {:call, _, :spend, _}}, %Event{action: fork}} =
             Divergence.first_diff(original, replayed)

    assert fork == Driver.action(:echo, ["forked"])
    # Only the delegate's action ran; the replayed put did not touch ToolState.
    assert [%Event{result: {:ok, {:put, :k}}}, %Event{result: {:ok, "echo: \"forked\""}}, _halt] =
             replayed

    assert ToolState.snapshot() == ToolState.initial()
  end

  test "a result override changes one replayed turn" do
    original = record("orig", @script)
    override = %{1 => {:error, :budget_exceeded}}

    replayed =
      replay(
        "branch",
        Replay.context(original, FakeDriver, FakeDriver.context([]), overrides: override)
      )

    assert {:diverged, 1, %Event{result: {:ok, {:remaining, 6}}},
            %Event{result: {:error, :budget_exceeded}}} =
             Divergence.first_diff(original, replayed)

    assert Enum.map(replayed, & &1.action) == Enum.map(original, & &1.action)
  end
end
