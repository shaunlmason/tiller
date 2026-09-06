defmodule Tiller.Demo do
  @moduledoc """
  End-to-end demos.

    * `run/0`: root session spawns a subagent; a tool crash is contained.
    * `seed/1`: the same loop driving open-seed through `Tiller.Seed`:
      claim a ready card, renew, comment, release, and log the port's
      answer to a stale token as data.
  """

  def run do
    Tiller.State.clear()

    sub_ctx = Tiller.FakeDriver.context([Tiller.Driver.action(:echo, ["from subagent"])])

    root_ctx = Tiller.FakeDriver.context([
      Tiller.Driver.action(:echo, ["hello from root"]),
      Tiller.Driver.action(:spawn_subagent, [Tiller.FakeDriver, sub_ctx]),
      Tiller.Driver.action(:fail, [])  # tool crashes; must become data, not kill the session
    ])

    {:ok, pid} = Tiller.Session.start_link(driver: Tiller.FakeDriver, ctx: root_ctx, id: "root")
    {:halted, _} = Tiller.Session.run_to_halt(pid)

    # the subagent runs concurrently; wait for it before printing
    for %Tiller.Event{result: {:ok, {:subagent_started, sub, _}}} <- Tiller.State.events("root"),
        do: Tiller.Session.await(sub)

    print_log("tiller demo")
  end

  @doc """
  Drive the open-seed port. `opts` go to `Tiller.Seed.start_link/1`:
  `cd:` an instantiated open-seed repo, `command:` (default
  `["scripts/seed", "mcp", "serve"]`), `actor:`. `task` is a ready card id.

      mix run -e 'Tiller.Demo.seed("os-1a2b3c4d", cd: "../my-seed-repo", actor: "tiller-1")'
  """
  def seed(task, opts) do
    Tiller.State.clear()
    {:ok, client} = Tiller.Seed.start_link(opts)

    # The driver keeps the token: it is data the port handed back, and
    # every later worker verb is fenced on it. A scripted driver cannot
    # read its own log, so claim first and script the rest around it.
    {:ok, %{"claim_token" => tok}} = Tiller.Tools.seed_claim(task)

    ctx = Tiller.FakeDriver.context([
      Tiller.Driver.action(:seed_get, [task]),
      Tiller.Driver.action(:seed_lease_renew, [task, "stale-token"]),  # exit 6: fenced out, logged, not fatal
      Tiller.Driver.action(:seed_lease_renew, [task, tok]),
      Tiller.Driver.action(:seed_comment, [task, "tiller was here", tok]),
      Tiller.Driver.action(:seed_release, [task, tok])
    ])

    {:ok, pid} = Tiller.Session.start_link(driver: Tiller.FakeDriver, ctx: ctx, id: "root")
    {:halted, _} = Tiller.Session.run_to_halt(pid)
    GenServer.stop(client)
    print_log("tiller seed demo")
  end

  defp print_log(title) do
    IO.puts("=== #{title}: event log (seq session/turn) ===")

    for %Tiller.Event{seq: seq, session_id: sid, turn: t, action: a, result: r} <- Tiller.State.events() do
      IO.puts("#{seq} #{sid}/#{t} " <> inspect(a))
      IO.puts("  -> " <> inspect(r, limit: 12))
    end

    IO.puts("=== done ===")
  end
end
