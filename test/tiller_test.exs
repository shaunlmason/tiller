defmodule TillerTest do
  use ExUnit.Case, async: false

  alias Tiller.{Actions, Driver, Event, FakeDriver, Session, State, Tools}

  setup do
    Tiller.Lab.reset()
    :ok
  end

  test "echo round-trips through state" do
    ctx = FakeDriver.context([Driver.action(:echo, ["hi"])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx, id: "root")
    assert {:halted, 1} = Session.run_to_halt(pid)
    assert [{a, {:ok, "echo: \"hi\""}}, {:halt, 1}] = State.log("root")
    assert a == {:call, Tools, :echo, ["hi"]}
  end

  test "events are attributed and ordered" do
    ctx = FakeDriver.context([Driver.action(:echo, ["a"]), Driver.action(:echo, ["b"])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx, id: "root")
    assert {:halted, 2} = Session.run_to_halt(pid)

    assert [
             %Event{seq: 1, session_id: "root", parent_id: nil, turn: 0, action: {:call, Tools, :echo, ["a"]}},
             %Event{seq: 2, turn: 1, action: {:call, Tools, :echo, ["b"]}},
             %Event{seq: 3, turn: 2, action: :halt, result: {:halted, 2}}
           ] = State.events("root")

    assert %{id: "root", parent_id: nil, turns: 2, status: :halted} = Map.drop(Session.info(pid), [:state])
  end

  test "a tool crash is contained and logged" do
    ctx = FakeDriver.context([Driver.action(:fail, []), Driver.action(:echo, ["after crash"])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx, id: "root")
    assert {:halted, 2} = Session.run_to_halt(pid)

    assert [{_, {:error, _}}, {_, {:ok, _}}, {:halt, 2}] = State.log("root")
  end

  test "run is a cast: the process is observable mid-run and await sees the halt" do
    # a driver that never halts on its own until told: 3 echoes then halt
    ctx = FakeDriver.context(for i <- 1..3, do: Driver.action(:echo, [i]))
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx, id: "root")
    assert %{status: :idle, turns: 0} = Session.info(pid)
    :ok = Session.run(pid)
    assert {:halted, 3} = Session.await(pid)
    # awaiting again is immediate: the halt is in the store
    assert {:halted, 3} = Session.await(pid, 0)
  end

  test "subscribers receive every event live" do
    State.subscribe("root")
    ctx = FakeDriver.context([Driver.action(:echo, ["x"])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx, id: "root")
    :ok = Session.run(pid)
    assert_receive {:tiller_event, %Event{session_id: "root", turn: 0, action: {:call, _, :echo, ["x"]}}}
    assert_receive {:tiller_event, %Event{session_id: "root", action: :halt}}
    State.unsubscribe("root")
  end

  test "subagent runs under the supervisor, concurrently, attributed to its parent" do
    sub = FakeDriver.context([Driver.action(:echo, ["sub"])])
    ctx = FakeDriver.context([Driver.action(:spawn_subagent, [FakeDriver, sub]), Driver.action(:echo, ["root goes on"])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx, id: "root")
    assert {:halted, 2} = Session.run_to_halt(pid)

    [%Event{result: {:ok, {:subagent_started, sub_pid, sub_id}}} | _] = State.events("root")
    assert is_pid(sub_pid)
    assert {:halted, 1} = Session.await(sub_pid)

    assert [
             %Event{session_id: ^sub_id, parent_id: "root", turn: 0, action: {:call, Tools, :echo, ["sub"]}},
             %Event{session_id: ^sub_id, action: :halt}
           ] = State.events(sub_id)

    # the parent did not block on the child: its second turn is in the log either way
    assert Enum.any?(State.events("root"), &match?(%Event{action: {:call, _, :echo, ["root goes on"]}}, &1))
  end

  test "a crashing subagent does not take the parent down" do
    sub = FakeDriver.context([Driver.action(:fail, [])])
    ctx = FakeDriver.context([Driver.action(:spawn_subagent, [FakeDriver, sub]), Driver.action(:echo, ["still here"])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx, id: "root")
    assert {:halted, 2} = Session.run_to_halt(pid)
    [%Event{result: {:ok, {:subagent_started, sub_pid, sub_id}}} | _] = State.events("root")
    assert {:halted, 1} = Session.await(sub_pid)
    assert [%Event{result: {:error, _}}, %Event{action: :halt}] = State.events(sub_id)
    assert Process.alive?(pid)
  end

  test "subagent tools cannot spawn (depth limit)" do
    sub = FakeDriver.context([Driver.action(:spawn_subagent, [FakeDriver, FakeDriver.context([])])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: sub, id: "sub", whitelist: Actions.sub_whitelist())
    assert {:halted, 1} = Session.run_to_halt(pid)
    assert [{_, {:error, :not_whitelisted}}, {:halt, 1}] = State.log("sub")
  end

  test "bad action term is rejected, not evaluated" do
    assert {:error, {:bad_action, 42}} = Actions.eval(42, Actions.root_whitelist())
  end
end
