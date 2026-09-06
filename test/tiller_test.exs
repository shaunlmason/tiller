defmodule TillerTest do
  use ExUnit.Case, async: false

  alias Tiller.{Actions, Driver, FakeDriver, Session, State, Tools}

  setup do
    State.clear()
    Tiller.ToolState.reset()
    :ok
  end

  test "echo round-trips through state" do
    ctx = FakeDriver.context([Driver.action(:echo, ["hi"])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx)
    assert {:halted, 1} = Session.run(pid)
    assert [{a, {:ok, "echo: \"hi\""}}, {:halt, 1}] = State.log()
    assert a == {:call, Tools, :echo, ["hi"]}
  end

  test "a tool crash is contained and logged" do
    ctx = FakeDriver.context([Driver.action(:fail, []), Driver.action(:echo, ["after crash"])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx)
    assert {:halted, 2} = Session.run(pid)

    log = State.log()
    assert [{_, {:error, _}}, _] = Enum.take(log, 2)
    assert Enum.any?(log, fn {a, _} -> a == {:call, Tiller.Tools, :echo, ["after crash"]} end)
  end

  test "subagent runs under supervisor and is crash-isolated" do
    sub = FakeDriver.context([Driver.action(:echo, ["sub"])])
    ctx = FakeDriver.context([Driver.action(:spawn_subagent, [FakeDriver, sub])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx)
    assert {:halted, 1} = Session.run(pid)

    spawn_entry = Enum.find(State.log(), fn {a, _} -> a == {:call, Tiller.Tools, :spawn_subagent, [FakeDriver, sub]} end)
    assert {_, {:ok, {:subagent_done, pid2}}} = spawn_entry
    assert is_pid(pid2)
  end

  test "subagent tools cannot spawn (depth limit)" do
    sub = FakeDriver.context([Driver.action(:spawn_subagent, [FakeDriver, FakeDriver.context([])])])
    {:ok, pid} =
      Session.start_link(
        driver: FakeDriver,
        ctx: sub,
        whitelist: Actions.sub_whitelist()
      )

    assert {:halted, 1} = Session.run(pid)
    assert [{_, {:error, :not_whitelisted}}, {:halt, 1}] = State.log()
  end

  test "bad action term is rejected, not evaluated" do
    assert {:error, {:bad_action, 42}} = Actions.eval(42, Actions.root_whitelist())
  end
end
