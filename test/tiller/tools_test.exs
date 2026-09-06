defmodule Tiller.ToolsTest do
  use ExUnit.Case, async: false

  alias Tiller.{Driver, FakeDriver, Session, State, ToolState}

  setup do
    State.clear()
    ToolState.reset()
    :ok
  end

  defp run(actions) do
    State.clear()
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: FakeDriver.context(actions))
    {:halted, _} = Session.run(pid)
    State.log() |> Enum.reject(&match?({:halt, _}, &1)) |> Enum.map(&elem(&1, 1))
  end

  test "put then get round-trips; get of a missing key refuses" do
    results =
      run([
        Driver.action(:put, [:greeting, "hi"]),
        Driver.action(:get, [:greeting]),
        Driver.action(:get, [:missing])
      ])

    assert [{:ok, {:put, :greeting}}, {:ok, "hi"}, {:error, :not_found}] = results
  end

  test "spend depletes a budget; overspending refuses without depleting" do
    results =
      run([
        Driver.action(:spend, [4]),
        Driver.action(:spend, [7]),
        Driver.action(:spend, [6])
      ])

    assert [{:ok, {:remaining, 6}}, {:error, :budget_exceeded}, {:ok, {:remaining, 0}}] = results
    assert %{budget: 0} = ToolState.snapshot()
  end

  test "flaky crashes on every third call and the crash is contained" do
    results = run(List.duplicate(Driver.action(:flaky, [:v]), 4))

    assert [{:ok, :v}, {:ok, :v}, {:error, {:error, %RuntimeError{message: msg}, _}}, {:ok, :v}] =
             results

    assert msg == "flaky: call 3 failed"
  end

  test "sleep succeeds slowly and reports the capped duration" do
    {us, results} = :timer.tc(fn -> run([Driver.action(:sleep, [20])]) end)

    assert [{:ok, {:slept, 20}}] = results
    assert us >= 20_000
    assert [{:ok, {:slept, 1_000}}] = run([Driver.action(:sleep, [5_000])])
  end

  test "subagents get the base tools but not spawn" do
    sub = Tiller.Actions.sub_whitelist()
    assert {:spend, 1} in sub
    refute {:spawn_subagent, 2} in sub
    assert {:spawn_subagent, 2} in Tiller.Actions.root_whitelist()
  end
end
