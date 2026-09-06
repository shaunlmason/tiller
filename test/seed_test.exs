defmodule Tiller.SeedTest do
  # Drives Tiller.Seed and the seed_* tools against the scripted fake in
  # test/support/fake_seed_mcp.exs: same wire format as the engine, no
  # engine. Sessions run against it exactly as they would against seed.
  use ExUnit.Case, async: false

  alias Tiller.{Actions, Driver, FakeDriver, Seed, Session, State, Tools}

  @fake Path.expand("support/fake_seed_mcp.exs", __DIR__)

  setup do
    State.clear()
    {:ok, pid} = Seed.start_link(command: ["elixir", @fake], cd: File.cwd!(), actor: "tiller-test")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    :ok
  end

  test "handshake completes and tools/list returns the verb surface" do
    {:ok, tools} = Seed.tools(Seed)
    assert "task_claim" in Enum.map(tools, & &1["name"])
    assert Seed.actor(Seed) == "tiller-test"
  end

  test "an accepted verb returns {:ok, envelope}" do
    assert {:ok, %{"ok" => true, "verb" => "ready", "tasks" => [%{"task" => "os-1"}]}} =
             Seed.call(Seed, "task_ready", %{actor: "tiller-test"})
  end

  test "a refusal is data: {:refused, envelope} with error and exit intact" do
    assert {:refused, %{"ok" => false, "error" => "not_found", "exit" => 4}} =
             Seed.call(Seed, "task_get", %{task: "os-nope"})
  end

  test "a JSON-RPC error (unknown tool) raises TransportError, never a refusal" do
    e = assert_raise Seed.TransportError, fn -> Seed.call(Seed, "no_such_tool", %{}) end
    assert {:rpc, -32602, "unknown tool no_such_tool"} = e.reason
  end

  test "claim, renew, transition, release through the tools with the token threaded" do
    assert {:ok, %{"claim_token" => tok}} = Tools.seed_claim("os-1")
    assert {:ok, %{"verb" => "lease_renew"}} = Tools.seed_lease_renew("os-1", tok)
    assert {:ok, %{"verb" => "attach_evidence", "kind" => "pr"}} =
             Tools.seed_attach_evidence("os-1", "pr", "https://example/pr/1", tok)
    assert {:ok, %{"verb" => "transition", "to" => "review"}} = Tools.seed_transition("os-1", "review", tok)
    assert {:ok, %{"verb" => "release"}} = Tools.seed_release("os-1", tok)
  end

  test "the port's exit classes come back as results: contention, fenced, invalid" do
    assert {:ok, _} = Tools.seed_claim("os-1")
    assert {:refused, %{"error" => "contention", "exit" => 2}} = Tools.seed_claim("os-1")
    assert {:refused, %{"error" => "fenced_out", "exit" => 6}} = Tools.seed_lease_renew("os-1", "stale")
    assert {:refused, %{"error" => "invalid_transition", "exit" => 3}} = Tools.seed_claim("os-blocked")
  end

  test "a session logs seed verbs as actions; refusals are {:ok, {:refused, _}}, not crashes" do
    ctx =
      FakeDriver.context([
        Driver.action(:seed_ready, []),
        Driver.action(:seed_claim, ["os-1", "45m"]),
        Driver.action(:seed_claim, ["os-1"]),
        Driver.action(:seed_transition, ["os-1", "blocked", "tok-1", "plan:12"])
      ])

    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx)
    assert {:halted, 4} = Session.run_to_halt(pid)

    assert [
             {{:call, Tools, :seed_ready, []}, {:ok, {:ok, %{"verb" => "ready"}}}},
             {{:call, Tools, :seed_claim, ["os-1", "45m"]}, {:ok, {:ok, %{"claim_token" => "tok-1", "lease" => "45m"}}}},
             {{:call, Tools, :seed_claim, ["os-1"]}, {:ok, {:refused, %{"exit" => 2}}}},
             {{:call, Tools, :seed_transition, ["os-1", "blocked", "tok-1", "plan:12"]},
              {:ok, {:ok, %{"blocked_on" => "plan:12"}}}},
             {:halt, 4}
           ] = State.log()
  end

  test "a subagent may read but never claim, renew, or transition" do
    sub =
      FakeDriver.context([
        Driver.action(:seed_get, ["os-1"]),
        Driver.action(:seed_claim, ["os-1"]),
        Driver.action(:seed_transition, ["os-1", "review", "tok-1"])
      ])

    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: sub, whitelist: Actions.sub_whitelist())
    assert {:halted, 3} = Session.run_to_halt(pid)

    assert [
             {_, {:ok, {:ok, %{"verb" => "get"}}}},
             {_, {:error, :not_whitelisted}},
             {_, {:error, :not_whitelisted}},
             {:halt, 3}
           ] = State.log()

    # the card is still claimable: the subagent's refused claim never reached the port
    assert {:ok, %{"claim_token" => _}} = Tools.seed_claim("os-1")
  end

  test "operator verbs are on no whitelist" do
    for wl <- [Actions.root_whitelist(), Actions.sub_whitelist()],
        {f, _} <- wl do
      refute f in [:seed_accept, :seed_reject, :seed_close, :seed_promote, :seed_cancel]
    end
  end

  test "a dead engine surfaces as a transport error, contained by the session" do
    GenServer.stop(Seed)
    ctx = FakeDriver.context([Driver.action(:seed_ready, [])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx)
    assert {:halted, 1} = Session.run_to_halt(pid)
    assert [{_, {:error, {:error, %Seed.TransportError{reason: :not_started}, _}}}, {:halt, 1}] = State.log()
  end
end
