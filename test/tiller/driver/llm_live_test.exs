defmodule Tiller.Driver.LLMLiveTest do
  @moduledoc """
  The same driver against the real Messages API. Opt-in, like the
  open-seed engine test: it needs a credential and it spends money.

      TILLER_ANTHROPIC_API_KEY=sk-... mix test --include integration

  What it proves that the scripted tests cannot: the request shape is
  one the API accepts, a real model's `tool_use` maps onto tiller's
  whitelist, and asking for summarized thinking actually returns some.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Tiller.{Event, Session, State}
  alias Tiller.Driver.LLM

  setup do
    Tiller.reset()
  end

  test "a real model stores a value, reads it back, and finishes" do
    key =
      System.get_env("TILLER_ANTHROPIC_API_KEY") ||
        raise "set TILLER_ANTHROPIC_API_KEY to run the live driver test"

    goal = """
    Store the value "hello" under the key "greeting" using the put tool, then read it
    back with get to confirm it, then call done with a one-sentence summary.
    """

    ctx = LLM.context(goal, api_key: key, max_turns: 6)
    {:ok, pid} = Session.start_link(driver: LLM, ctx: ctx, id: "live")
    Session.run(pid)

    assert {:halted, turns} = Session.await("live", 180_000)
    events = State.events("live")

    calls = for %Event{action: {:call, _m, f, args}} <- events, do: {f, args}

    assert {:put, ["greeting", "hello"]} in calls
    assert Enum.any?(calls, &match?({:get, ["greeting"]}, &1))
    assert Enum.any?(calls, &match?({:done, [_]}, &1))

    # the run ended by finishing, not by a cap or a refusal
    assert %Event{action: :halt, result: {:halted, ^turns}} = List.last(events)

    # `display: "summarized"` is only worth sending if it comes back: the
    # default returns thinking blocks whose text is empty, and a fake API
    # cannot tell the two apart.
    assert Enum.any?(events, &Event.rationale/1),
           "no turn came back with summarized thinking"
  end
end
