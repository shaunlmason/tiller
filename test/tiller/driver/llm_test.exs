defmodule Tiller.Driver.LLMTest do
  @moduledoc """
  The LLM driver against `Tiller.FakeMessages`: real HTTP, real request
  and response shapes, no network and no credential.
  """
  use ExUnit.Case, async: false

  alias Tiller.{Actions, Driver, Event, FakeDriver, FakeMessages, Race, Session, State}
  alias Tiller.Driver.LLM

  setup do
    Tiller.reset()
  end

  defp start_api(script) do
    {:ok, api} = FakeMessages.start(script)
    on_exit(fn -> FakeMessages.stop(api) end)
    api
  end

  defp run(api, goal, opts \\ []) do
    id = Keyword.get(opts, :id, "llm")
    ctx = LLM.context(goal, Keyword.merge([base_url: api.base_url], opts))

    {:ok, pid} =
      Session.start_link([driver: LLM, ctx: ctx, id: id] ++ Keyword.take(opts, [:whitelist]))

    Session.run(pid)
    {:halted, _} = Session.await(id, 15_000)
    {pid, State.events(id)}
  end

  defp actions(events) do
    for %Event{action: {:call, _m, f, args}} <- events, do: {f, args}
  end

  test "a run: the model's tool calls become actions, and results go back to it" do
    api =
      start_api([
        FakeMessages.tool_use("put", %{"key" => "greeting", "value" => "hi"}, text: "storing it"),
        FakeMessages.tool_use("get", %{"key" => "greeting"}),
        FakeMessages.done("stored and read back")
      ])

    {_pid, events} = run(api, "Store a greeting, read it back, then finish.")

    assert [
             {:put, ["greeting", "hi"]},
             {:get, ["greeting"]},
             {:done, ["stored and read back"]}
           ] = actions(events)

    assert %Event{action: :halt, result: {:halted, 3}} = List.last(events)

    # the conversation the model saw: its own turn, then the result of it
    [_first, second, third] = FakeMessages.requests(api)

    assert [
             %{"role" => "user", "content" => "Store a greeting, read it back, then finish."},
             %{
               "role" => "assistant",
               "content" => [%{"type" => "text"}, %{"type" => "tool_use"}]
             },
             %{"role" => "user", "content" => [%{"type" => "tool_result", "is_error" => false}]}
           ] = second["messages"]

    # get of a stored key came back with the value, not an error
    result = third["messages"] |> List.last() |> Map.get("content") |> hd()
    assert result["content"] =~ "hi"
    refute result["is_error"]
  end

  test "the request carries the whitelist as strict tools, one action per turn" do
    api = start_api([FakeMessages.done("nothing to do")])
    run(api, "Finish immediately.")

    [request] = FakeMessages.requests(api)

    assert request["model"] == "claude-opus-5"
    assert request["tool_choice"] == %{"type" => "auto", "disable_parallel_tool_use" => true}
    assert request["output_config"] == %{"effort" => "low"}

    names = Enum.map(request["tools"], & &1["name"])
    assert names == Enum.sort(names)
    assert "spend" in names and "done" in names
    # not offered: no schema a model could fill in
    refute "spawn_subagent" in names
    refute "fail" in names
  end

  test "the next action depends on the previous result: a refused spend changes the plan" do
    # One script, two runs. The only difference is whether the budget can
    # cover the spend, and the model reacts to the refusal.
    script = fn request ->
      case FakeMessages.last_result(request) do
        nil ->
          FakeMessages.tool_use("spend", %{"amount" => request["_amount"] || 4})

        result ->
          if result =~ "budget_exceeded",
            do: FakeMessages.tool_use("get", %{"key" => "fallback"}),
            else: FakeMessages.tool_use("sleep", %{"ms" => 1})
      end
    end

    affordable = start_api(fn r -> script.(Map.put(r, "_amount", 4)) end)
    {_p, ok_events} = run(affordable, "Spend four.", id: "affordable", max_turns: 2)

    Tiller.reset()

    too_much = start_api(fn r -> script.(Map.put(r, "_amount", 99)) end)
    {_p, refused_events} = run(too_much, "Spend ninety-nine.", id: "refused", max_turns: 2)

    assert [{:spend, [4]}, {:sleep, [1]}] = actions(ok_events)
    assert [{:spend, [99]}, {:get, ["fallback"]}] = actions(refused_events)

    # the refusal reached the model as an error, which is why it changed course
    assert %Event{result: {:error, :budget_exceeded}} = hd(refused_events)
  end

  test "a fork with spend removed is decisive: the model plans without the tool" do
    # The model plans from the tools it was offered, and ends somewhere
    # else when the budget tool is not among them.
    script = fn request ->
      tools = Enum.map(request["tools"], & &1["name"])

      case FakeMessages.last_result(request) do
        nil ->
          if "spend" in tools,
            do: FakeMessages.tool_use("spend", %{"amount" => 4}),
            else: FakeMessages.tool_use("echo", %{"value" => "no budget tool"})

        result ->
          if result =~ "remaining",
            do: FakeMessages.done("spent four"),
            else: FakeMessages.done("could not spend")
      end
    end

    api = start_api(script)
    {pid, original} = run(api, "Spend four if you can.", id: "orig", max_turns: 3)

    no_spend = List.delete(Actions.root_whitelist(), {:spend, 1})
    {:ok, branch} = Session.fork(pid, 0, {:whitelist, no_spend})
    {:ok, branch_id} = Session.id_of(branch)
    Session.run(branch)
    {:halted, _} = Session.await(branch_id, 15_000)
    branched = State.events(branch_id)

    assert [{:spend, [4]}, {:done, ["spent four"]}] = actions(original)
    assert [{:echo, ["no budget tool"]}, {:done, ["could not spend"]}] = actions(branched)

    # the run ended somewhere else, which is what makes the mutation
    # decisive rather than merely a different path
    assert Race.decisive?(original, branched)
  end

  test "a refusal ends the run with its category in the log" do
    api = start_api([FakeMessages.refusal("cyber")])
    {_pid, events} = run(api, "Something declined.")

    assert [%Event{action: :halt, result: {:halted, 0, {:refusal, "cyber"}}}] = events
    assert Event.halt_reason(List.last(events).result) == {:refusal, "cyber"}
  end

  test "a turn cap ends the run with a reason, so it diverges from finishing" do
    api = start_api(fn _ -> FakeMessages.tool_use("echo", %{"value" => "again"}) end)
    {_pid, events} = run(api, "Loop forever.", max_turns: 2)

    assert [{:echo, ["again"]}, {:echo, ["again"]}] = actions(events)
    assert %Event{action: :halt, result: {:halted, 2, :max_turns}} = List.last(events)
  end

  test "a retryable status is retried, and a hard failure ends the run" do
    api = start_api([FakeMessages.status(429), FakeMessages.done("after the retry")])
    {_pid, events} = run(api, "Retry once.")
    assert [{:done, ["after the retry"]}] = actions(events)
    assert length(FakeMessages.requests(api)) == 2

    Tiller.reset()

    hard = start_api([FakeMessages.status(400)])
    {_pid, events} = run(hard, "Fail hard.", id: "hard")
    assert [%Event{action: :halt, result: {:halted, 0, {:api, {:status, 400, _}}}}] = events
  end

  test "text with no tool call is the run's answer" do
    api = start_api([FakeMessages.text("There was nothing to do.")])
    {_pid, events} = run(api, "Say something.")
    assert [{:done, ["There was nothing to do."]}] = actions(events)
  end

  test "the fake API rejects request drift, which the driver reports" do
    api = start_api([FakeMessages.done("unused")])
    ctx = LLM.context("drifted", base_url: api.base_url)
    # the session's whitelist is what the request offers, and nothing on
    # this one has a schema
    {:ok, pid} = Session.start_link(driver: LLM, ctx: ctx, id: "drift", whitelist: [{:fail, 0}])
    Session.run(pid)
    {:halted, _} = Session.await("drift", 15_000)

    # no tool has a schema, so the request offers none and the fake refuses it
    assert [%Event{action: :halt, result: {:halted, 0, {:api, {:status, 400, message}}}}] =
             State.events("drift")

    assert message =~ "no tools offered"
  end

  test "forking a branch again with an override reaches the model, not just the log" do
    # A branch's driver is Replay, so this fork aims override/3 at Replay
    # rather than at the driver underneath it.
    script = fn request ->
      case FakeMessages.last_result(request) do
        nil -> FakeMessages.tool_use("spend", %{"amount" => 4})
        result -> FakeMessages.done("saw #{result}")
      end
    end

    api = start_api(script)
    {pid, _events} = run(api, "Spend four.", id: "orig", max_turns: 3)

    {:ok, branch} = Session.fork(pid, 1, nil)
    {:ok, branch_id} = Session.id_of(branch)
    Session.run(branch)
    {:halted, _} = Session.await(branch_id, 15_000)

    {:ok, rebranch} = Session.fork(branch, 1, {:result_override, 0, {:error, :budget_exceeded}})
    {:ok, rebranch_id} = Session.id_of(rebranch)
    Session.run(rebranch)
    {:halted, _} = Session.await(rebranch_id, 15_000)

    summary =
      State.events(rebranch_id)
      |> Enum.find_value(fn
        %Event{action: {:call, _m, :done, [s]}} -> s
        _ -> nil
      end)

    assert summary =~ "budget_exceeded",
           "the model answered from a history that never happened: #{inspect(summary)}"
  end

  describe "override/3" do
    test "rewrites the remembered result and strips thinking after it" do
      ctx = %{
        LLM.context("goal", base_url: "http://unused")
        | messages: [
            %{"role" => "user", "content" => "goal"},
            %{
              "role" => "assistant",
              "content" => [
                %{"type" => "tool_use", "id" => "t0", "name" => "spend", "input" => %{}}
              ]
            },
            %{
              "role" => "user",
              "content" => [
                %{
                  "type" => "tool_result",
                  "tool_use_id" => "t0",
                  "content" => "{:remaining, 6}",
                  "is_error" => false
                }
              ]
            },
            %{
              "role" => "assistant",
              "content" => [
                %{"type" => "thinking", "thinking" => "..."},
                %{"type" => "text", "text" => "next"}
              ]
            }
          ]
      }

      overridden = LLM.override(ctx, 0, {:error, :budget_exceeded})

      assert %{
               "content" => [
                 %{"tool_use_id" => "t0", "content" => ":budget_exceeded", "is_error" => true}
               ]
             } =
               Enum.at(overridden.messages, 2)

      # editing a turn invalidates later thinking blocks, so they go
      assert %{"content" => [%{"type" => "text"}]} = Enum.at(overridden.messages, 3)
    end

    test "a turn the conversation does not have is left alone" do
      ctx = LLM.context("goal", base_url: "http://unused")
      assert LLM.override(ctx, 7, {:ok, :x}) == ctx
    end
  end

  describe "the reason for a turn" do
    test "the request asks for the summary, and the answer lands on the event" do
      api =
        start_api([
          FakeMessages.tool_use("put", %{"key" => "k", "value" => 1},
            thinking: "Storing first: the read at the end has nothing to find until it has."
          ),
          # a response with no thinking at all: some turns simply have none
          FakeMessages.tool_use("get", %{"key" => "k"}),
          FakeMessages.done("stored and read back", thinking: "Both steps are in the log.")
        ])

      {_pid, events} = run(api, "Store a key, read it back, then finish.", id: "why")

      # Asked for explicitly: the default is `omitted`, whose thinking
      # blocks come back with empty text.
      for request <- FakeMessages.requests(api) do
        assert request["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
      end

      assert [put, get, done, _halt] = events
      assert Event.rationale(put) =~ "Storing first"
      assert Event.rationale(get) == nil
      assert Event.rationale(done) =~ "Both steps"
    end

    test "a driver told not to ask does not, and its events carry no reason" do
      api =
        start_api([
          FakeMessages.done("finished", thinking: nil)
        ])

      {_pid, events} = run(api, "Finish.", id: "quiet", display: :omitted)

      assert [request] = FakeMessages.requests(api)
      assert request["thinking"]["display"] == "omitted"
      assert [done, _halt] = events
      assert Event.rationale(done) == nil
    end

    test "a branch replays the source's reasons and gives its own past the fork point" do
      api = start_api(&answer/1)

      ctx = LLM.context("Store a key, read it back, then finish.", base_url: api.base_url)
      {:ok, pid} = Session.start_link(driver: LLM, ctx: ctx, id: "orig-why")
      Session.run(pid)
      assert {:halted, _} = Session.await("orig-why", 15_000)

      original = State.events("orig-why")

      {:ok, branch} = Session.fork("orig-why", 2, nil)
      {:ok, id} = Session.id_of(branch)
      Session.run(branch)
      assert {:halted, _} = Session.await(id, 15_000)

      branch_events = State.events(id)

      # The replayed prefix reads the way the source's did: those turns
      # were not decided again, and reporting the fork point's reasoning
      # for them would attribute it to a turn that happened before it.
      for turn <- 0..1 do
        assert Event.rationale(Enum.at(branch_events, turn)) ==
                 Event.rationale(Enum.at(original, turn))

        assert Event.rationale(Enum.at(branch_events, turn)) != nil
      end

      # Its own turns are its own: it asked the API for them.
      assert Event.rationale(Enum.at(branch_events, 2)) != nil
    end

    test "a scripted driver records no reason rather than an invented one" do
      ctx = FakeDriver.context([Driver.action(:echo, ["hi"])])
      {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx, id: "no-why")
      Session.run(pid)
      assert {:halted, 1} = Session.await(pid)
      assert [echo, _halt] = State.events("no-why")
      assert Event.rationale(echo) == nil
    end
  end

  # A stand-in model for the fork test: answers from what the conversation
  # has already done, so the branch's own turns get coherent answers too.
  defp answer(request) do
    called =
      for %{"role" => "assistant", "content" => blocks} <- Map.get(request, "messages", []),
          %{"type" => "tool_use", "name" => name} <- List.wrap(blocks),
          do: name

    cond do
      "put" not in called ->
        FakeMessages.tool_use("put", %{"key" => "k", "value" => 1}, thinking: "Store it first.")

      "get" not in called ->
        FakeMessages.tool_use("get", %{"key" => "k"}, thinking: "Now read it back.")

      true ->
        FakeMessages.done("stored and read back", thinking: "Nothing is left to do.")
    end
  end

  test "usage is reported through the session, and a fork pays only past its fork point" do
    {:ok, api} =
      FakeMessages.start([
        FakeMessages.tool_use("put", %{"key" => "k", "value" => 1},
          input_tokens: 100,
          output_tokens: 20
        ),
        FakeMessages.tool_use("get", %{"key" => "k"}, input_tokens: 200, output_tokens: 30),
        FakeMessages.done("done", input_tokens: 300, output_tokens: 40)
      ])

    on_exit(fn -> FakeMessages.stop(api) end)

    ctx = LLM.context("store and read", base_url: api.base_url, api_key: "x")
    {:ok, pid} = Session.start_link(driver: LLM, ctx: ctx, id: "orig")
    Session.run(pid)
    assert {:halted, 3} = Session.await(pid)

    # Three turns billed, accumulated across them.
    assert %{usage: %{input: 600, output: 90}} = Session.info("orig")

    # A branch forked at turn 2 replays two turns without asking the API, so
    # it is billed only for what it decides itself. The context it inherits
    # already carries the source's 300 in / 50 out by that turn; that is the
    # original's bill, not the branch's, and must not appear here.
    {:ok, branch} = Session.fork("orig", 2, nil)
    {:ok, id} = Session.id_of(branch)
    Session.run(branch)
    assert {:halted, _} = Session.await(id)

    # One decision past the fork, at the fake's default rate.
    assert %{usage: %{input: 10, output: 5}} = Session.info(id)
  end

  test "a scripted driver reports no usage at all, rather than a zero it did not earn" do
    ctx = FakeDriver.context([Driver.action(:echo, ["hi"])])
    {:ok, pid} = Session.start_link(driver: FakeDriver, ctx: ctx, id: "scripted")
    Session.run(pid)
    assert {:halted, 1} = Session.await(pid)
    assert %{usage: nil} = Session.info("scripted")
  end
end
