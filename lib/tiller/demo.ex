defmodule Tiller.Demo do
  @moduledoc "End-to-end demo: root session spawns a subagent; a tool crash is contained."

  alias Tiller.{Driver, FakeDriver, Session, State, ToolState}

  def run do
    State.clear()
    ToolState.reset()

    sub_ctx = FakeDriver.context([Driver.action(:echo, ["from subagent"])])

    root_ctx =
      FakeDriver.context([
        Driver.action(:put, [:greeting, "hello from root"]),
        Driver.action(:spawn_subagent, [FakeDriver, sub_ctx]),
        # tool crashes; must become data, not kill the session
        Driver.action(:fail, []),
        Driver.action(:get, [:greeting])
      ])

    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: root_ctx, id: "root")
    State.subscribe("root.0")
    Session.run(pid)
    {:halted, _} = Session.await(pid)

    receive do
      {:tiller_event, %Tiller.Event{session_id: "root.0", action: :halt}} -> :ok
    after
      1_000 -> :ok
    end

    IO.puts("=== tiller demo: event log ===")

    for e <- State.events() do
      IO.puts("#{e.seq} [#{e.session_id} t#{e.turn}] #{inspect(e.action)}")
      IO.puts("  -> " <> inspect(e.result, limit: 5))
    end

    IO.puts("=== done ===")
  end
end
