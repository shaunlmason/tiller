defmodule Tiller.Driver.ClaudeTest do
  # The Claude driver against a scripted transport: no network, no key.
  # The wire shapes (tools, tool_use, tool_result, stop_reason, refusal)
  # follow the Messages API; the live test at the bottom checks them
  # against the real API when a key is present.
  use ExUnit.Case, async: false

  alias Tiller.{Driver, Event, Lab, Session, State, Tools}
  alias Tiller.Driver.Claude

  setup do
    Lab.reset()
    :ok
  end

  # a transport that answers from a queue and records every request
  defp scripted(replies) do
    {:ok, agent} = Agent.start_link(fn -> %{replies: replies, requests: []} end)

    http = fn req ->
      Agent.get_and_update(agent, fn %{replies: [r | rest], requests: rs} = s ->
        {r, %{s | replies: rest, requests: rs ++ [req]}}
      end)
    end

    {http, fn -> Agent.get(agent, & &1.requests) end}
  end

  defp tool_use(name, args, id \\ "toolu_1", text \\ nil) do
    content = if text, do: [%{"type" => "text", "text" => text}], else: []

    {:ok,
     %{
       status: 200,
       body: %{
         "stop_reason" => "tool_use",
         "content" => content ++ [%{"type" => "tool_use", "id" => id, "name" => name, "input" => %{"args" => args}}]
       }
     }}
  end

  defp end_turn(text),
    do: {:ok, %{status: 200, body: %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => text}]}}}

  test "offers the whitelist as tools, one args array each, ambiguous arities disambiguated" do
    ctx = Claude.context("do a thing", http: fn _ -> end_turn("ok") end)
    names = Enum.map(ctx.tools, &elem(&1, 0))
    assert "echo" in names and "seed_claim_1" in names and "seed_claim_2" in names
    refute "spawn_subagent" in names

    req = Claude.request(ctx)
    assert req["model"] == "claude-opus-5"
    assert req["fallbacks"] == "default"
    assert [%{"role" => "user", "content" => "do a thing"}] = req["messages"]
    echo = Enum.find(req["tools"], &(&1["name"] == "echo"))
    assert echo["input_schema"]["required"] == ["args"]
    assert echo["description"] =~ "Echo"
  end

  test "a tool_use becomes the quoted action; the result is fed back with the raw assistant blocks" do
    {http, requests} = scripted([tool_use("echo", ["hi"], "toolu_a", "calling echo"), end_turn("done")])
    ctx = Claude.context("say hi", http: http)

    assert {:action, {:call, Tools, :echo, ["hi"]}, ctx} = Claude.next_action(ctx)
    assert %{pending: %{turn: 0, id: "toolu_a"}} = ctx

    ev = %Event{turn: 0, action: Driver.action(:echo, ["hi"]), result: {:ok, "echo: \"hi\""}, origin: :live}
    ctx = Claude.observe(ctx, ev)
    assert ctx.pending == nil and ctx.turns == 1

    assert {:action, {:call, Tools, :note, ["done"]}, ctx} = Claude.next_action(ctx)
    assert :halt = Claude.next_action(ctx)

    [_, second] = requests.()

    assert [
             %{"role" => "user", "content" => "say hi"},
             %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "calling echo"}, %{"type" => "tool_use", "id" => "toolu_a"}]},
             %{"role" => "user", "content" => [%{"type" => "tool_result", "tool_use_id" => "toolu_a", "is_error" => false, "content" => content}]}
           ] = second["messages"]

    assert content =~ "echo: \\\"hi\\\""
  end

  test "an invented tool name is still an action, refused by the whitelist as data" do
    {http, _} = scripted([tool_use("rm_rf", ["/"]), end_turn("oh well")])
    {:ok, pid} = Session.start_link(driver: Claude, ctx: Claude.context("clean up", http: http), id: "c")
    assert {:halted, 2} = Session.run_to_halt(pid)

    assert [
             %Event{action: {:call, Tools, :rm_rf, ["/"]}, result: {:error, :not_whitelisted}},
             %Event{action: {:call, Tools, :note, ["oh well"]}, result: {:ok, :ok}},
             %Event{action: :halt}
           ] = State.events("c")
  end

  test "a refusal, an http error, and a transport error each end the session as a note" do
    refusal = {:ok, %{status: 200, body: %{"stop_reason" => "refusal", "stop_details" => %{"category" => "cyber"}, "content" => []}}}
    {http, _} = scripted([refusal])
    assert {:action, {:call, _, :note, [{:refused, "cyber", ""}]}, %{done: true}} = Claude.next_action(Claude.context("x", http: http))

    {http, _} = scripted([{:ok, %{status: 429, body: %{"error" => "rate"}}}])
    assert {:action, {:call, _, :note, [{:driver_error, {:http, 429, _}}]}, %{done: true}} = Claude.next_action(Claude.context("x", http: http))

    {http, _} = scripted([{:error, :no_api_key}])
    assert {:action, {:call, _, :note, [{:driver_error, :no_api_key}]}, %{done: true}} = Claude.next_action(Claude.context("x", http: http))
  end

  test "max_turns halts with a note" do
    {http, _} = scripted(List.duplicate(tool_use("echo", [1]), 5))
    {:ok, pid} = Session.start_link(driver: Claude, ctx: Claude.context("loop", http: http, max_turns: 2), id: "m")
    assert {:halted, 3} = Session.run_to_halt(pid)
    assert [%Event{action: {:call, _, :echo, _}}, %Event{action: {:call, _, :echo, _}}, %Event{action: {:call, _, :note, ["halting: 2 turns reached"]}}, _] = State.events("m")
  end

  test "a Claude-driven session forks and resumes: the prefix is synthesised, then the model continues" do
    {http, requests} = scripted([tool_use("echo", ["a"], "toolu_a"), tool_use("echo", ["b"], "toolu_b"), end_turn("done")])
    {:ok, root} = Session.start_link(driver: Claude, ctx: Claude.context("two echoes", http: http), id: "root")
    assert {:halted, 3} = Session.run_to_halt(root)

    # fork at turn 1 under a whitelist mutation: turn 0 replays, the model is asked for turn 1 onward
    {http2, requests2} = scripted([tool_use("echo", ["b2"], "toolu_b2"), end_turn("done again")])
    {:ok, b} = Session.fork(root, 1, {:driver, Claude, Claude.context("two echoes", http: http2)}, id: "b")
    assert {:halted, 3} = Session.run_to_halt(b)

    assert [%Event{origin: :replay, action: {:call, _, :echo, ["a"]}}, %Event{origin: :live, action: {:call, _, :echo, ["b2"]}}, %Event{action: {:call, _, :note, ["done again"]}}, _] =
             State.events("b")

    # the branch's first request carried the replayed turn as a synthesised assistant turn + result
    [first | _] = requests2.()

    assert [
             %{"role" => "user"},
             %{"role" => "assistant", "content" => [%{"type" => "tool_use", "id" => "toolu_turn_0", "name" => "echo", "input" => %{"args" => ["a"]}}]},
             %{"role" => "user", "content" => [%{"tool_use_id" => "toolu_turn_0"}]}
           ] = first["messages"]

    assert length(requests.()) == 3
  end

  @tag :live
  test "live: one real turn against the API when ANTHROPIC_API_KEY is set" do
    {:ok, pid} = Session.start_link(driver: Claude, ctx: Claude.context("Call echo with the single argument \"ping\", then stop.", max_turns: 3), id: "live")
    assert {:halted, n} = Session.run_to_halt(pid, 120_000)
    events = State.events("live")
    assert n >= 1
    assert Enum.any?(events, &match?(%Event{action: {:call, _, :echo, ["ping"]}, result: {:ok, _}}, &1)), inspect(events)
  end
end
