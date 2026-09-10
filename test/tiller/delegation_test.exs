defmodule Tiller.DelegationTest.RecordingStore do
  @moduledoc """
  A store of the kind `Tiller.Session`'s `:state` option advertises: the
  real one, with a note of which sessions were written through it. A child
  started by a parent on this store must land here, or the parent cannot
  see the child it started.
  """
  alias Tiller.State

  def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)
  def written, do: Agent.get(__MODULE__, & &1)

  def put_profile(id, profile) do
    Agent.update(__MODULE__, &[id | &1])
    State.put_profile(id, profile)
  end

  defdelegate append(session_id, parent_id, turn, action, result, extra), to: State
  defdelegate append(session_id, parent_id, turn, action, result), to: State
  defdelegate events(session_id), to: State
  defdelegate snapshot(session_id, turn), to: State
  defdelegate snapshot(session_id, turn, snap), to: State
  defdelegate profile(id), to: State
  defdelegate bump_resumes(id), to: State
  defdelegate subscribe(id), to: State
  defdelegate unsubscribe(id), to: State
end

defmodule Tiller.DelegationTest do
  @moduledoc """
  Spawning a subagent and waiting for it: the parent uses the child's
  answer inside its own run, and waiting does not stop it being a session
  while it waits.
  """
  use ExUnit.Case, async: false

  alias Tiller.{Actions, Driver, Event, FakeDriver, FakeMessages, Session, State}
  alias Tiller.Driver.LLM

  setup do
    Tiller.reset()
  end

  defp start(id, actions, opts \\ []) do
    spec =
      Session.child_spec([driver: FakeDriver, ctx: FakeDriver.context(actions), id: id] ++ opts)

    {:ok, pid} = DynamicSupervisor.start_child(Application.fetch_env!(:tiller, :supervisor), spec)
    Session.run(pid)
    pid
  end

  defp results(id),
    do: for(%Event{action: {:call, _, f, _}, result: r} <- State.events(id), do: {f, r})

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  test "a parent waits for the subagent it spawned and gets its answer" do
    child = FakeDriver.context([Driver.action(:done, ["the child's answer"])])

    pid =
      start("root", [
        Driver.action(:spawn_subagent, [FakeDriver, child]),
        Driver.action(:await, [0]),
        Driver.action(:done, ["used it"])
      ])

    assert {:halted, 3} = Session.await(pid, 5_000)

    assert [
             {:spawn_subagent, {:ok, {:subagent_started, 0}}},
             {:await, {:ok, {:done, "the child's answer"}}},
             {:done, {:ok, {:done, "used it"}}}
           ] = results("root")

    # The child ran as its own session, under the parent, with its own log.
    assert [%Event{parent_id: "root"} | _] = State.events("root.0")
  end

  test "waiting does not stop the session being one" do
    # A child that takes its time, so the parent is parked while we ask it
    # things. A wait that blocked the process would time out these calls.
    child = FakeDriver.context([Driver.action(:sleep, [300]), Driver.action(:done, ["slow"])])

    pid =
      start("root", [
        Driver.action(:spawn_subagent, [FakeDriver, child]),
        Driver.action(:await, [0]),
        Driver.action(:done, ["waited"])
      ])

    wait_until(fn -> length(State.events("root")) == 1 end)

    # Parked on turn 1, and still answering for itself.
    assert %{id: "root", turns: 1, status: :running} = Session.info(pid)
    assert {:ok, _branch} = Session.fork(pid, 1, nil)

    assert {:halted, 3} = Session.await(pid, 5_000)
    assert [_spawn, {:await, {:ok, {:done, "slow"}}}, _done] = results("root")
  end

  test "a child that already finished is not waited for" do
    child = FakeDriver.context([Driver.action(:done, ["quick"])])

    pid =
      start("root", [
        Driver.action(:spawn_subagent, [FakeDriver, child]),
        # let the child finish first
        Driver.action(:sleep, [80]),
        Driver.action(:await, [0])
      ])

    assert {:halted, 3} = Session.await(pid, 5_000)
    assert [_spawn, _sleep, {:await, {:ok, {:done, "quick"}}}] = results("root")
  end

  test "a subagent that stopped without an answer says why" do
    # No done: the script runs out and the run halts on its own.
    child = FakeDriver.context([Driver.action(:echo, ["nothing to report"])])

    pid =
      start("root", [
        Driver.action(:spawn_subagent, [FakeDriver, child]),
        Driver.action(:await, [0])
      ])

    assert {:halted, 2} = Session.await(pid, 5_000)
    assert [_spawn, {:await, {:ok, {:halted, 1}}}] = results("root")
  end

  test "a wait with nothing to wait for is a result, not a hang" do
    pid = start("root", [Driver.action(:await, [3]), Driver.action(:done, ["moved on"])])

    assert {:halted, 2} = Session.await(pid, 5_000)
    assert [{:await, {:error, {:no_subagent_at, 3}}}, _done] = results("root")
  end

  test "a child that never finishes parks its parent only as long as it is allowed" do
    child = FakeDriver.context([Driver.action(:sleep, [5_000])])

    pid =
      start(
        "root",
        [Driver.action(:spawn_subagent, [FakeDriver, child]), Driver.action(:await, [0])],
        await_timeout: 60
      )

    assert {:halted, 2} = Session.await(pid, 5_000)
    assert [_spawn, {:await, {:error, {:await_timeout, "root.0"}}}] = results("root")
  end

  test "a subagent cannot delegate: neither verb is on its whitelist" do
    refute {:spawn, 1} in Actions.sub_whitelist()
    refute {:await, 1} in Actions.sub_whitelist()
    assert {:spawn, 1} in Actions.root_whitelist()
    assert {:await, 1} in Actions.root_whitelist()

    child = FakeDriver.context([Driver.action(:spawn, ["delegate further"])])

    pid =
      start("root", [
        Driver.action(:spawn_subagent, [FakeDriver, child]),
        Driver.action(:await, [0])
      ])

    assert {:halted, 2} = Session.await(pid, 5_000)
    assert [{:spawn, {:error, :not_whitelisted}} | _] = results("root.0")
  end

  test "a run killed at the turn it was waiting on comes back and still has its child" do
    # The kill the lab's own sweep generates for an await turn. A restart
    # keeps the turns and the context, so it has to keep the handles too.
    child = FakeDriver.context([Driver.action(:done, ["child answer"])])

    pid =
      start(
        "root",
        [
          Driver.action(:spawn_subagent, [FakeDriver, child]),
          Driver.action(:await, [0]),
          Driver.action(:done, ["used it"])
        ],
        kill_at: 1
      )

    assert {:halted, 3} = Session.await(pid, 5_000)
    assert %{resumed: true} = Session.info("root")
    assert [_spawn, {:await, {:ok, {:done, "child answer"}}}, _done] = results("root")
  end

  test "a child is started on the store its parent reads" do
    start_supervised!(%{
      id: :recording_store,
      start: {Tiller.DelegationTest.RecordingStore, :start_link, []}
    })

    child = FakeDriver.context([Driver.action(:done, ["through the same store"])])

    pid =
      start(
        "root",
        [Driver.action(:spawn_subagent, [FakeDriver, child]), Driver.action(:await, [0])],
        state: Tiller.DelegationTest.RecordingStore
      )

    assert {:halted, 2} = Session.await(pid, 5_000)

    # The child wrote its profile through the parent's store, which is the
    # only reason the parent could find it to wait on.
    assert "root.0" in Tiller.DelegationTest.RecordingStore.written()
    assert [_spawn, {:await, {:ok, {:done, "through the same store"}}}] = results("root")
  end

  test "however deep the forks nest, the wait finds whose child the replayed spawn started" do
    child = FakeDriver.context([Driver.action(:done, ["from the original"])])

    pid =
      start("root", [
        Driver.action(:spawn_subagent, [FakeDriver, child]),
        Driver.action(:echo, ["between"]),
        Driver.action(:await, [0])
      ])

    assert {:halted, 3} = Session.await(pid, 5_000)

    # Each level forks the level above after its spawn, so the run that
    # started the child gets one hop further away every time. Ten of them
    # is past any number someone would have picked for a cap.
    deepest =
      Enum.reduce(1..10, "root", fn _level, id ->
        {:ok, branch} = Session.fork(id, 1, nil)
        {:ok, branch_id} = Session.id_of(branch)
        Session.run(branch)
        assert {:halted, _} = Session.await(branch_id, 5_000)
        branch_id
      end)

    assert [_spawn, _echo, {:await, {:ok, {:done, "from the original"}}}] = results(deepest)
  end

  test "a driver that cannot make a child refuses rather than inventing one" do
    # FakeDriver reads a script; there is no such thing as a child of it
    # pursuing a goal it was never given.
    pid = start("root", [Driver.action(:spawn, ["do something for me"])])

    assert {:halted, 1} = Session.await(pid, 5_000)
    assert [{:spawn, {:error, :cannot_delegate}}] = results("root")
  end

  describe "a model delegating" do
    defp api_for_delegation do
      {:ok, api} =
        FakeMessages.start(fn request ->
          if subagent?(request), do: child_turn(request), else: parent_turn(request)
        end)

      on_exit(fn -> FakeMessages.stop(api) end)
      api
    end

    defp subagent?(request), do: request["system"] =~ "You are a subagent"

    # A model can only call what the request offered it, so a branch whose
    # whitelist lost a verb plans without it rather than being refused
    # after choosing it.
    defp parent_turn(request) do
      called = called(request)

      cond do
        offered?(request, "spawn") and "spawn" not in called ->
          FakeMessages.tool_use("spawn", %{"goal" => "read the greeting back"},
            thinking: "This is separable, so it goes to a subagent."
          )

        offered?(request, "await") and "spawn" in called and "await" not in called ->
          FakeMessages.tool_use("await", %{"turn" => 0},
            thinking: "Nothing to do until it answers."
          )

        "await" in called ->
          FakeMessages.done(
            "the subagent read it back: " <> (FakeMessages.last_result(request) || "")
          )

        true ->
          FakeMessages.done("no subagent to send, so there is nothing to report")
      end
    end

    defp offered?(request, name), do: Enum.any?(request["tools"] || [], &(&1["name"] == name))

    defp child_turn(request) do
      case called(request) do
        [] -> FakeMessages.tool_use("get", %{"key" => "greeting"})
        _ -> FakeMessages.done("the greeting is " <> (FakeMessages.last_result(request) || ""))
      end
    end

    defp called(request) do
      for %{"role" => "assistant", "content" => blocks} <- Map.get(request, "messages", []),
          %{"type" => "tool_use", "name" => name} <- List.wrap(blocks),
          do: name
    end

    test "the model spawns a subagent, waits for it, and answers with what it said" do
      {:put, "greeting"} = Tiller.Tools.put("greeting", "hello")
      api = api_for_delegation()

      ctx =
        LLM.context("Have a subagent read the greeting, then report it.",
          base_url: api.base_url,
          api_key: "x"
        )

      {:ok, pid} = Session.start_link(driver: LLM, ctx: ctx, id: "root")
      Session.run(pid)
      assert {:halted, 3} = Session.await("root", 15_000)

      assert [
               {:spawn, {:ok, {:spawned, 0}}},
               {:await, {:ok, {:done, child_summary}}},
               {:done, {:ok, {:done, answer}}}
             ] = results("root")

      assert child_summary =~ "hello"
      assert answer =~ "read it back"

      # The child is a session of its own, driven by the model, and what it
      # was offered is the subagent whitelist: it could not have delegated.
      assert [%Event{parent_id: "root"} | _] = State.events("root.0")

      child_request = Enum.find(FakeMessages.requests(api), &subagent?/1)
      offered = Enum.map(child_request["tools"], & &1["name"])
      assert "get" in offered
      refute "spawn" in offered
      refute "await" in offered
    end

    test "the counterfactual the lab gains: what if it could not have delegated" do
      {:put, "greeting"} = Tiller.Tools.put("greeting", "hello")
      api = api_for_delegation()

      ctx =
        LLM.context("Have a subagent read the greeting, then report it.",
          base_url: api.base_url,
          api_key: "x"
        )

      spec = Session.child_spec(driver: LLM, ctx: ctx, id: "root")

      {:ok, pid} =
        DynamicSupervisor.start_child(Application.fetch_env!(:tiller, :supervisor), spec)

      Session.run(pid)
      assert {:halted, 3} = Session.await("root", 15_000)

      # Fork before the spawn with delegation taken away. The tools array
      # the branch's model is offered is the branch's whitelist, so it
      # plans without spawn rather than being refused after choosing it.
      no_delegating = Actions.root_whitelist() -- [{:spawn, 1}, {:await, 1}]
      {:ok, branch} = Session.fork("root", 0, {:whitelist, no_delegating})
      {:ok, id} = Session.id_of(branch)
      Session.run(branch)
      assert {:halted, _} = Session.await(id, 15_000)

      branch_request =
        api
        |> FakeMessages.requests()
        |> Enum.reject(&subagent?/1)
        |> List.last()

      offered = Enum.map(branch_request["tools"], & &1["name"])
      refute "spawn" in offered
      refute "await" in offered

      # And nothing it did was a delegation.
      refute Enum.any?(results(id), &match?({:spawn, _}, &1))
    end

    test "a branch forked between the spawn and the wait waits on the child it inherited" do
      {:put, "greeting"} = Tiller.Tools.put("greeting", "hello")
      api = api_for_delegation()

      ctx =
        LLM.context("Have a subagent read the greeting, then report it.",
          base_url: api.base_url,
          api_key: "x"
        )

      spec = Session.child_spec(driver: LLM, ctx: ctx, id: "root")

      {:ok, pid} =
        DynamicSupervisor.start_child(Application.fetch_env!(:tiller, :supervisor), spec)

      Session.run(pid)
      assert {:halted, 3} = Session.await("root", 15_000)

      # Turn 0 spawned; the branch replays that turn and does the waiting
      # itself. The child it waits on is the one the prefix started.
      {:ok, branch} = Session.fork("root", 1, nil)
      {:ok, id} = Session.id_of(branch)
      Session.run(branch)
      assert {:halted, _} = Session.await(id, 15_000)

      assert [
               {:spawn, {:ok, {:spawned, 0}}},
               {:await, {:ok, {:done, summary}}} | _
             ] = results(id)

      assert summary =~ "hello"
    end
  end
end
