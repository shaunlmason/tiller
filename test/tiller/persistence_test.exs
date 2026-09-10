defmodule Tiller.PersistenceTest.Conversation do
  @moduledoc """
  A driver whose context grows the way a model's does: every turn holds
  every message the last turn held, plus one.
  """
  @behaviour Tiller.Driver

  @impl true
  def next_action(%{left: 0}), do: :halt

  def next_action(%{left: n, messages: messages}) do
    message = %{"role" => "assistant", "content" => String.duplicate("turn #{n} ", 60)}

    {:action, Tiller.Driver.action(:echo, ["turn"]),
     %{left: n - 1, messages: messages ++ [message]}}
  end

  def context(turns), do: %{left: turns, messages: []}
end

defmodule Tiller.PersistenceTest do
  @moduledoc """
  The durable store: what a restart does, and what can be picked up
  afterwards. `Tiller.State.reopen/1` is the restart, so no VM has to
  die for the test to mean something.
  """
  use ExUnit.Case, async: false

  alias Tiller.{Divergence, Driver, Event, FakeDriver, FakeMessages, Session, State, ToolState}
  alias Tiller.Driver.LLM
  alias Tiller.PersistenceTest.Conversation

  setup do
    Tiller.reset()
    path = Path.join(System.tmp_dir!(), "tiller-state-#{System.unique_integer([:positive])}.log")
    State.reopen(path)

    on_exit(fn ->
      State.reopen(nil)
      File.rm(path)
    end)

    {:ok, path: path}
  end

  @script [
    Driver.action(:put, [:k, 1]),
    Driver.action(:spend, [4]),
    Driver.action(:get, [:k])
  ]

  # Kill a run once it has recorded a turn but before it can finish. The
  # latency the callers use makes the gap wide; polling makes it certain.
  #
  # A session is a permanent child, so the supervisor puts it straight
  # back (that is what the kill_at axis rides on). We wait for that to
  # land before returning, so the caller's reset_processes/0 is not
  # racing a restart that is still in flight: on a real VM restart there
  # is no supervisor left to race.
  defp kill_mid_run(pid, id) do
    wait_until(fn -> State.events(id) != [] end)
    Process.exit(pid, :kill)
    wait_until(fn -> not Process.alive?(pid) end)
    wait_until(fn -> is_pid(Session.whereis(id)) end)

    events = State.events(id)
    refute Enum.any?(events, &Event.halt?/1), "the run finished before it could be killed"
    events
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  defp record(id, actions \\ @script, opts \\ []) do
    spec =
      Session.child_spec([driver: FakeDriver, ctx: FakeDriver.context(actions), id: id] ++ opts)

    {:ok, pid} = DynamicSupervisor.start_child(Tiller.Supervisor, spec)
    Session.run(pid)
    pid
  end

  test "frames round-trip, and a tail torn by a crash is dropped", %{path: path} do
    io = Tiller.State.Log.open(path)
    Tiller.State.Log.append(io, {:profile, "a", %{driver: FakeDriver}})
    Tiller.State.Log.append(io, {:resumes, "a", 2})
    File.close(io)
    File.write!(path, <<0, 0, 0, 64, "half a frame">>, [:append])

    assert [{:profile, "a", %{driver: FakeDriver}}, {:resumes, "a", 2}] =
             Tiller.State.Log.read(path)
  end

  test "events, snapshots and profiles survive a restart", %{path: path} do
    pid = record("keep")
    assert {:halted, 3} = Session.await(pid)

    events = State.events("keep")
    {:ok, snap} = State.snapshot("keep", 1)
    {:ok, profile} = State.profile("keep")

    # what a restart does: nothing in memory, everything from the file
    State.reopen(path)

    assert State.events("keep") == events
    assert {:ok, ^snap} = State.snapshot("keep", 1)
    assert {:ok, ^profile} = State.profile("keep")
    assert State.log_path() == path

    # seq keeps going from where the log left off, so a new event never
    # collides with a recorded one
    {:ok, next} = State.append("other", nil, 0, Driver.action(:echo, [1]), {:ok, 1})
    assert next.seq == List.last(events).seq + 1
  end

  test "a long run with a growing context costs the file its turns, not their square",
       %{path: path} do
    # What a model-driven run looks like to the store: a context that
    # holds everything it held last turn, plus one message. Written whole
    # each turn, sixty turns of this cost about sixty times the average
    # context; the store shares what did not change instead.
    turns = 60

    {:ok, pid} =
      Session.start_link(driver: Conversation, ctx: Conversation.context(turns), id: "long")

    Session.run(pid)
    assert {:halted, ^turns} = Session.await(pid, 30_000)

    events = State.events("long")
    snapshots = for t <- 0..turns, {:ok, snap} <- [State.snapshot("long", t)], do: {t, snap}
    {:ok, last} = State.snapshot("long", turns)
    context_bytes = byte_size(:erlang.term_to_binary(last.ctx))

    # Inline, the snapshots alone would come to about turns/2 contexts.
    inline = div(context_bytes * turns, 2)

    assert File.stat!(path).size < div(inline, 5),
           "log is #{File.stat!(path).size} bytes against #{inline} written whole"

    # And it is still the same run: what a restart reads back is what the
    # run put in, message for message.
    State.reopen(path)
    assert State.events("long") == events

    assert for(t <- 0..turns, {:ok, snap} <- [State.snapshot("long", t)], do: {t, snap}) ==
             snapshots
  end

  test "the reason a turn was chosen survives the restart with the turn", %{path: path} do
    {:ok, _} =
      State.append("why", nil, 0, Driver.action(:spend, [4]), {:ok, 6}, %{
        rationale: "spending 4 leaves room for the read"
      })

    State.reopen(path)

    assert [event] = State.events("why")
    assert Event.rationale(event) == "spending 4 leaves room for the read"
  end

  test "a run the restart interrupted is picked up where it stopped", %{path: path} do
    # a slow run, killed part-way with no chance to halt
    pid =
      record(
        "cut",
        [Driver.action(:put, [:k, 1]), Driver.action(:spend, [4]), Driver.action(:get, [:k])],
        latency: 300
      )

    before = kill_mid_run(pid, "cut")

    # the restart: processes gone, store re-read from the file
    Tiller.reset_processes()
    State.reopen(path)

    assert "cut" in Tiller.dead()
    assert [{"cut", {:ok, _pid}}] = Tiller.resume_dead()
    assert {:halted, 3} = Session.await("cut", 10_000)

    resumed = State.events("cut")
    # every turn recorded before the kill is still there, in place
    assert Enum.take(resumed, length(before)) == before
    assert %Event{action: {:call, _, :get, [:k]}} = Enum.at(resumed, 2)
  end

  test "a resumed run reaches the same place an uninterrupted one does", %{path: path} do
    reference = record("reference")
    assert {:halted, 3} = Session.await(reference)
    expected = State.events("reference")

    # both runs draw on the same global budget, so the second starts where
    # the first left off unless the world is put back
    Tiller.ToolState.reset()

    pid = record("cut", @script, latency: 300)
    kill_mid_run(pid, "cut")
    Tiller.reset_processes()
    State.reopen(path)

    Tiller.resume_dead()
    assert {:halted, 3} = Session.await("cut", 10_000)

    # same actions and results, only the session id differs
    assert :identical =
             Divergence.first_diff(expected, State.events("cut"))
  end

  test "resume refuses a session that is running, finished, or unknown" do
    pid = record("done")
    assert {:halted, 3} = Session.await(pid)
    assert {:error, :halted} = Session.resume("done")
    assert {:error, :unknown} = Session.resume("never-existed")

    running = record("live", [Driver.action(:sleep, [200])], latency: 200)
    assert {:error, :alive} = Session.resume("live")
    Process.exit(running, :kill)
  end

  test "a resumed run keeps the world it had, not a fresh one", %{path: path} do
    pid =
      record(
        "world",
        [
          Driver.action(:put, [:k, "kept"]),
          Driver.action(:spend, [4]),
          Driver.action(:get, [:k])
        ],
        latency: 300
      )

    kill_mid_run(pid, "world")
    Tiller.reset_processes()
    # a real VM restart loses the global tool state too, which is what
    # makes the snapshot the only copy of this run's world
    ToolState.reset()
    State.reopen(path)

    Tiller.resume_dead()
    assert {:halted, 3} = Session.await("world", 10_000)

    read_back =
      Enum.find_value(State.events("world"), fn
        %Event{action: {:call, _m, :get, _}, result: r} -> r
        _ -> nil
      end)

    assert {:ok, "kept"} = read_back
  end

  test "frames written after a torn tail are still readable", %{path: path} do
    {:ok, _} = State.append("t", nil, 0, Driver.action(:echo, [1]), {:ok, 1})
    # what a crash mid-write leaves behind
    File.write!(path, <<0, 0, 0, 99, "torn">>, [:append])

    State.reopen(path)
    {:ok, _} = State.append("t", nil, 1, Driver.action(:echo, [2]), {:ok, 2})

    State.reopen(path)
    assert length(State.events("t")) == 2
  end

  test "a run killed before its first action is still a run to pick up", %{path: path} do
    pid = record("early", [Driver.action(:sleep, [400])], latency: 400)
    wait_until(fn -> match?({:ok, _}, State.snapshot("early", 0)) end)
    assert State.events("early") == []

    Process.exit(pid, :kill)
    wait_until(fn -> not Process.alive?(pid) end)
    wait_until(fn -> is_pid(Session.whereis("early")) end)
    Tiller.reset_processes()
    State.reopen(path)

    # nothing was recorded, but the profile and snapshot say what to
    # start again
    assert "early" in Tiller.dead()
  end

  test "an event is never durable without the snapshot that follows it", %{path: path} do
    pid = record("paired")
    assert {:halted, 3} = Session.await(pid)
    State.reopen(path)

    # every recorded turn has somewhere to resume from
    for turn <- 0..3 do
      assert {:ok, _snap} = State.snapshot("paired", turn)
    end
  end

  test "TILLER_STATE_LOG wins over config, and empty turns the log off" do
    Application.put_env(:tiller, :state_log, "/tmp/from-config.log")
    env_path = Path.join(System.tmp_dir!(), "from-env-#{System.unique_integer([:positive])}.log")
    System.put_env("TILLER_STATE_LOG", env_path)

    on_exit(fn ->
      System.delete_env("TILLER_STATE_LOG")
      Application.delete_env(:tiller, :state_log)
      File.rm(env_path)
    end)

    assert State.configured_log_path() == env_path

    System.put_env("TILLER_STATE_LOG", "")
    assert State.configured_log_path() == nil
  end

  test "resume refuses when the store has no point to resume from" do
    {:ok, _} = State.append("headless", nil, 0, Driver.action(:echo, [1]), {:ok, 1})

    State.put_profile("headless", %{
      driver: FakeDriver,
      parent_id: nil,
      whitelist: [],
      latency: 0,
      kill_at: nil,
      mutation: nil
    })

    # an event with no snapshot after it: better to say so than to start a
    # session that would sit idle forever
    assert {:error, :no_resume_point} = Session.resume("headless")
  end

  test "a model-driven run resumes with the results it had already seen", %{path: path} do
    # The seam where persistence meets the driver: a snapshot must hold the
    # context *after* the result was folded in, or a resumed model wakes up
    # having forgotten the answer it was reacting to. A scripted driver
    # cannot show this, because it never looks at a result.
    script = fn request ->
      case FakeMessages.last_result(request) do
        nil -> FakeMessages.tool_use("put", %{"key" => "k", "value" => "stored"})
        _ -> FakeMessages.done("read it back")
      end
    end

    {:ok, api} = FakeMessages.start(script)
    on_exit(fn -> FakeMessages.stop(api) end)

    ctx = LLM.context("Store something, then finish.", base_url: api.base_url)

    spec = Session.child_spec(driver: LLM, ctx: ctx, id: "model", latency: 300)
    {:ok, pid} = DynamicSupervisor.start_child(Tiller.Supervisor, spec)
    Session.run(pid)

    kill_mid_run(pid, "model")
    Tiller.reset_processes()
    ToolState.reset()
    State.reopen(path)

    Tiller.resume_dead()
    assert {:halted, 2} = Session.await("model", 15_000)

    # the run finished by deciding, not by starting over
    assert [
             %Event{action: {:call, _, :put, ["k", "stored"]}},
             %Event{action: {:call, _, :done, ["read it back"]}},
             %Event{action: :halt}
           ] = State.events("model")

    # and the request that decided it carried the earlier tool result, so
    # the conversation survived the restart intact
    last = List.last(FakeMessages.requests(api))

    assert Enum.any?(last["messages"], fn
             %{"content" => [%{"type" => "tool_result"} | _]} -> true
             _ -> false
           end)
  end

  test "clear empties the log too, so a restart after it starts blank", %{path: path} do
    pid = record("gone")
    assert {:halted, 3} = Session.await(pid)

    Tiller.reset()
    State.reopen(path)

    assert State.events() == []
    assert Tiller.dead() == []
  end

  test "with no log configured nothing is written and everything still works" do
    State.reopen(nil)
    pid = record("memory")
    assert {:halted, 3} = Session.await(pid)
    assert length(State.events("memory")) == 4
    assert State.log_path() == nil
  end
end
