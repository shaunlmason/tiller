defmodule Tiller.PersistenceTest do
  @moduledoc """
  The durable store: what a restart does, and what can be picked up
  afterwards. `Tiller.State.reopen/1` is the restart, so no VM has to
  die for the test to mean something.
  """
  use ExUnit.Case, async: false

  alias Tiller.{Divergence, Driver, Event, FakeDriver, Session, State}

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
