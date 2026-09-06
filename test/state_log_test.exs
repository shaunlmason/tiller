defmodule Tiller.StateLogTest do
  # Persistence: the store survives a reopen (what a VM restart does), and
  # a session that died with it is brought back by Session.resume/1.
  use ExUnit.Case, async: false

  alias Tiller.{Driver, Event, FakeDriver, Lab, Session, State}

  @path Path.join(System.tmp_dir!(), "tiller-state-test-#{System.unique_integer([:positive])}.log")

  setup do
    Lab.reset()
    State.reopen(@path)
    State.clear()
    on_exit(fn -> State.reopen(nil); File.rm(@path) end)
    :ok
  end

  defp act(f, args), do: Driver.action(f, args)

  test "frames round-trip and a torn tail is dropped" do
    io = Tiller.State.Log.open(@path)
    Tiller.State.Log.append(io, {:event, 1})
    Tiller.State.Log.append(io, {:session, "a", %{x: 1}})
    File.close(io)
    File.write!(@path, <<0, 0, 0, 99, "partial">>, [:append])
    assert [{:event, 1}, {:session, "a", %{x: 1}}] = Tiller.State.Log.read(@path)
  end

  test "events, seq, and packets survive a reopen" do
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: FakeDriver.context([act(:echo, [1]), act(:echo, [2])]), id: "p")
    {:halted, 2} = Session.run_to_halt(pid)
    before = State.events("p")
    packet = State.get_session("p")

    State.reopen(@path)
    assert State.events("p") == before
    assert State.get_session("p") == packet
    assert State.log_path() == @path

    # seq continues from where the log ended
    {:ok, ev} = State.append("q", nil, 0, act(:echo, [3]), {:ok, 3})
    assert ev.seq == List.last(before).seq + 1
  end

  test "a session that died with the VM resumes from the log" do
    # a supervised root killed mid-run, with no kill_at and :temporary restart: it stays dead
    spec = Session.child_spec(driver: FakeDriver, ctx: FakeDriver.context(for(i <- 1..4, do: act(:echo, [i]))), id: "v", latency: 30)
    {:ok, pid} = DynamicSupervisor.start_child(Tiller.Supervisor, spec)
    :ok = Session.run(pid)
    Process.sleep(80)
    Process.exit(pid, :kill)
    Process.sleep(20)
    assert Session.whereis("v") == nil
    n_before = length(State.events("v"))
    assert n_before in 1..3

    # "restart the VM": the processes are gone, the log is re-read
    State.reopen(@path)
    assert ["v"] = Lab.dead()
    assert [{"v", {:ok, _}}] = Lab.resume_dead()
    assert {:halted, 4} = Session.await("v")
    [r] = Session.lineage("v") -- ["v"]
    events = State.events(r)
    assert Enum.count(events, &(&1.origin == :replay)) == n_before
    assert [%Event{action: :halt, result: {:halted, 4}}] = Enum.filter(events, &(&1.action == :halt))
    assert :identical = Tiller.Divergence.first_diff(Enum.map(1..4, &{act(:echo, [&1]), {:ok, "echo: #{&1}"}}) ++ [{:halt, 4}], events)

    assert {:error, :halted} = Session.resume("v")
    assert {:error, :unknown} = Session.resume("nope")
  end

  test "clear truncates the log" do
    {:ok, _} = State.append("z", nil, 0, act(:echo, [1]), {:ok, 1})
    State.clear()
    State.reopen(@path)
    assert State.events() == []
  end
end
