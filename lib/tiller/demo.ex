defmodule Tiller.Demo do
  @moduledoc "End-to-end demo: root session spawns a subagent; a tool crash is contained."

  def run do
    Tiller.State.clear()

    sub_ctx = Tiller.FakeDriver.context([Tiller.Driver.action(:echo, ["from subagent"])])

    root_ctx = Tiller.FakeDriver.context([
      Tiller.Driver.action(:echo, ["hello from root"]),
      Tiller.Driver.action(:spawn_subagent, [Tiller.FakeDriver, sub_ctx]),
      Tiller.Driver.action(:fail, [])  # tool crashes; must become data, not kill the session
    ])

    {:ok, pid} =
      Tiller.Session.start_link(driver: Tiller.FakeDriver, ctx: root_ctx)

    Tiller.Session.run(pid)

    IO.puts("=== tiller demo: action log ===")

    for {a, r} <- Tiller.State.log() do
      IO.puts(inspect(a))
      IO.puts("  -> " <> inspect(r))
    end

    IO.puts("=== done ===")
  end
end
