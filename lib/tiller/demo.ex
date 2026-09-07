defmodule Tiller.Demo do
  @moduledoc """
  End-to-end demos.

    * `run/0`: records a run (root spawns a subagent, a tool crashes), then
      forks it at one turn into racing branches, each with one thing
      different, and reports where each first diverges from the original.
    * `seed/2`: the same loop driving open-seed through `Tiller.Seed`:
      claim a ready card, renew, comment, release, and log the port's
      answer to a stale token as data.
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

  @doc """
  The same lab, driven by a model instead of a script.

  Records session "root" with `Tiller.Driver.LLM` against a scripted
  stand-in for the Messages API, so it needs no credential and costs
  nothing, and against the real API when one is configured. This is the
  run that makes the model-only parts of the lab visible: token cost per
  branch, and a control band that can actually be non-zero.

  Options: `:base_url` and `:api_key` to point at the real API instead.
  Returns `{pid, api}`, where `api` is `nil` when it went to the network.
  """
  def record_model(opts \\ []) do
    {api, opts} =
      if Keyword.has_key?(opts, :api_key) or Keyword.has_key?(opts, :base_url) do
        {nil, opts}
      else
        {:ok, api} = Tiller.FakeMessages.start(&toy_goal/1)
        {api, Keyword.put(opts, :base_url, api.base_url)}
      end

    ctx =
      Tiller.Driver.LLM.context(
        "Store the greeting \"hello from a model\" under the key greeting, " <>
          "spend 4 from the budget, read the greeting back, then finish.",
        Keyword.put_new(opts, :api_key, "fake")
      )

    sup = Application.fetch_env!(:tiller, :supervisor)
    spec = Session.child_spec(driver: Tiller.Driver.LLM, ctx: ctx, id: "root")
    {:ok, pid} = DynamicSupervisor.start_child(sup, spec)
    Session.run(pid)
    {pid, api}
  end

  # A stand-in model: it answers from what the conversation has already
  # done, not from a fixed list, so branches racing concurrently against
  # one fake API each get their own coherent run.
  defp toy_goal(request) do
    called = tools_called(request)

    cond do
      "put" not in called ->
        Tiller.FakeMessages.tool_use(
          "put",
          %{"key" => "greeting", "value" => "hello from a model"},
          text: "Storing it first."
        )

      "spend" not in called ->
        Tiller.FakeMessages.tool_use("spend", %{"amount" => 4})

      "get" not in called ->
        Tiller.FakeMessages.tool_use("get", %{"key" => "greeting"})

      true ->
        Tiller.FakeMessages.done("stored the greeting, spent 4, read it back")
    end
  end

  defp tools_called(request) do
    for %{"role" => "assistant", "content" => blocks} <- Map.get(request, "messages", []),
        %{"type" => "tool_use", "name" => name} <- List.wrap(blocks),
        do: name
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

  @doc """
  Drive the open-seed port. `opts` go to `Tiller.Seed.start_link/1`:
  `cd:` an instantiated open-seed repo, `command:` (default
  `["scripts/seed", "mcp", "serve"]`), `actor:`. `task` is a ready card id.

      mix run -e 'Tiller.Demo.seed("os-1a2b3c4d", cd: "../my-seed-repo", actor: "tiller-1")'
  """
  def seed(task, opts) do
    Tiller.reset()
    {:ok, client} = Tiller.Seed.start_link(opts)

    # The driver keeps the token: it is data the port handed back, and
    # every later worker verb is fenced on it. A scripted driver cannot
    # read its own log, so claim first and script the rest around it.
    {:ok, %{"claim_token" => tok}} = Tiller.Tools.seed_claim(task)

    ctx =
      FakeDriver.context([
        Driver.action(:seed_get, [task]),
        # exit 6: fenced out, logged, not fatal
        Driver.action(:seed_lease_renew, [task, "stale-token"]),
        Driver.action(:seed_lease_renew, [task, tok]),
        Driver.action(:seed_comment, [task, "tiller was here", tok]),
        Driver.action(:seed_release, [task, tok])
      ])

    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx, id: "seed")
    Session.run(pid)
    {:halted, _} = Session.await(pid)
    GenServer.stop(client)

    IO.puts("=== tiller seed demo: event log ===")
    print_events(State.events("seed"))
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
