defmodule Tiller.Demo do
  @moduledoc """
  End-to-end demo. Records a run (root spawns a subagent, a tool crashes),
  then forks it at one turn into four racing branches, each with one thing
  different, and reports where each first diverges from the original.
  """

  alias Tiller.{Actions, Divergence, Driver, Event, FakeDriver, Session, State}

  @doc """
  Start the demo run as session "root" under Tiller's supervisor and run
  it. Returns the pid; the run proceeds asynchronously.
  """
  def record do
    sub_ctx = FakeDriver.context([Driver.action(:echo, ["from subagent"])])

    root_ctx =
      FakeDriver.context([
        Driver.action(:put, [:greeting, "hello from root"]),
        Driver.action(:spawn_subagent, [FakeDriver, sub_ctx]),
        Driver.action(:spend, [4]),
        # tool crashes; must become data, not kill the session
        Driver.action(:fail, []),
        Driver.action(:get, [:greeting])
      ])

    sup = Application.fetch_env!(:tiller, :supervisor)
    spec = Session.child_spec(driver: FakeDriver, ctx: root_ctx, id: "root")
    {:ok, pid} = DynamicSupervisor.start_child(sup, spec)
    Session.run(pid)
    pid
  end

  def run do
    Tiller.reset()
    State.subscribe("root.1")
    pid = record()
    {:halted, _} = Session.await(pid)

    receive do
      {:tiller_event, %Event{session_id: "root.1", action: :halt}} -> :ok
    after
      1_000 -> :ok
    end

    IO.puts("=== recorded run ===")
    print_events(State.events())

    original = State.events("root")
    fork_turn = 2

    mutations = [
      nil,
      {:whitelist, List.delete(Actions.root_whitelist(), {:spend, 1})},
      {:result_override, 0, {:error, :disk_full}},
      {:latency, 40},
      {:kill_at, fork_turn}
    ]

    IO.puts("\n=== fork at turn #{fork_turn}: #{length(mutations)} branches racing ===")
    branches = for m <- mutations, do: elem(Session.fork(pid, fork_turn, m), 1)
    ids = Enum.map(branches, &elem(Session.id_of(&1), 1))
    started = System.monotonic_time(:millisecond)
    Enum.each(branches, &Session.run/1)

    for id <- ids do
      {:halted, _} = Session.await(id)
      %{mutation: m} = Session.info(id)
      ms = System.monotonic_time(:millisecond) - started

      verdict =
        case Divergence.first_diff(original, State.events(id)) do
          :identical -> "identical"
          {:diverged, i, l, r} -> "diverged at turn #{i}: #{short(l)} vs #{short(r)}"
        end

      IO.puts("#{id} [#{inspect(m, limit: 3)}] finished ~#{ms}ms: #{verdict}")
    end

    IO.puts("=== done ===")
  end

  defp print_events(events) do
    for e <- events do
      IO.puts("#{e.seq} [#{e.session_id} t#{e.turn}] #{inspect(e.action, limit: 4)}")
      IO.puts("  -> " <> inspect(e.result, limit: 5))
    end
  end

  defp short(nil), do: "nothing"
  defp short(%Event{action: :halt, result: r}), do: inspect(r)
  defp short(%Event{action: {:call, _, f, _}, result: r}), do: "#{f} -> #{inspect(r, limit: 3)}"
end
