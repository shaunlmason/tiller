defmodule TillerTest do
  use ExUnit.Case, async: false

  alias Tiller.{Actions, Driver, Event, FakeDriver, Session, State, Tools}

  setup do
    Tiller.reset()
  end

  test "echo round-trips through state as an attributed event" do
    ctx = FakeDriver.context([Driver.action(:echo, ["hi"])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx, id: "root")
    assert :ok = Session.run(pid)
    assert {:halted, 1} = Session.await(pid)

    assert [
             %Event{seq: 1, session_id: "root", parent_id: nil, turn: 0, action: a, result: r},
             %Event{seq: 2, session_id: "root", turn: 1, action: :halt, result: {:halted, 1}}
           ] = State.events("root")

    assert a == {:call, Tools, :echo, ["hi"]}
    assert r == {:ok, "echo: \"hi\""}
  end

  test "await is idempotent after halt and times out before it" do
    ctx = FakeDriver.context([Driver.action(:sleep, [100])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx)
    assert {:error, :timeout} = Session.await(pid, 10)
    Session.run(pid)
    assert {:halted, 1} = Session.await(pid)
    assert {:halted, 1} = Session.await(pid)
  end

  test "a tool crash is contained and logged" do
    ctx = FakeDriver.context([Driver.action(:fail, []), Driver.action(:echo, ["after crash"])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx, id: "root")
    Session.run(pid)
    assert {:halted, 2} = Session.await(pid)

    assert [%Event{result: {:error, _}}, %Event{action: after_crash}, %Event{action: :halt}] =
             State.events("root")

    assert after_crash == {:call, Tools, :echo, ["after crash"]}
  end

  test "subagent runs under the supervisor without blocking its parent" do
    sub = FakeDriver.context([Driver.action(:sleep, [50]), Driver.action(:echo, ["sub"])])
    ctx = FakeDriver.context([Driver.action(:spawn_subagent, [FakeDriver, sub])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx, id: "root")
    State.subscribe("root.0")
    Session.run(pid)

    # The parent halts while the child is still sleeping.
    assert {:halted, 1} = Session.await(pid)
    assert [%Event{result: {:ok, {:subagent_started, "root.0"}}}, _halt] = State.events("root")
    assert [] == Enum.filter(State.events("root.0"), &Event.halt?/1)

    assert_receive {:tiller_event, %Event{session_id: "root.0", action: :halt}}, 1_000

    assert [
             %Event{parent_id: "root", turn: 0},
             %Event{turn: 1, action: echo},
             %Event{action: :halt}
           ] =
             State.events("root.0")

    assert echo == {:call, Tools, :echo, ["sub"]}
  end

  test "subagent tools cannot spawn (depth limit)" do
    sub =
      FakeDriver.context([Driver.action(:spawn_subagent, [FakeDriver, FakeDriver.context([])])])

    {:ok, pid} =
      Session.start_link(
        driver: FakeDriver,
        ctx: sub,
        whitelist: Actions.sub_whitelist(),
        id: "sub"
      )

    Session.run(pid)
    assert {:halted, 1} = Session.await(pid)

    assert [%Event{result: {:error, :not_whitelisted}}, %Event{action: :halt}] =
             State.events("sub")
  end

  test "sessions are addressable by id" do
    ctx = FakeDriver.context([])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx, id: "named")
    assert Session.whereis("named") == pid
    Session.run("named")
    assert {:halted, 0} = Session.await("named")
  end

  test "bad action term is rejected, not evaluated" do
    assert {:error, {:bad_action, 42}} = Actions.eval(42, Actions.root_whitelist())
  end
end
