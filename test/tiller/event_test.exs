defmodule Tiller.EventTest do
  use ExUnit.Case, async: true

  alias Tiller.{Driver, Event}

  test "halt/4 builds the terminal record" do
    e = Event.halt(9, "root", nil, 3)
    assert %Event{seq: 9, session_id: "root", parent_id: nil, turn: 3, action: :halt} = e
    assert e.result == {:halted, 3}
    assert Event.halt?(e)
    assert Event.halt?({:halt, 3})
  end

  test "key/1 ignores identity fields and accepts legacy tuples" do
    a = Driver.action(:echo, ["hi"])
    r = {:ok, "echo: \"hi\""}
    e = %Event{seq: 1, session_id: "a", parent_id: nil, turn: 0, action: a, result: r}
    refute Event.halt?(e)
    assert Event.key(e) == {a, r}
    assert Event.key(%{e | seq: 5, session_id: "b", parent_id: "a"}) == {a, r}
    assert Event.key({a, r}) == {a, r}
  end

  test "rationale/1 reads a reason, a missing one, and an event older than the field" do
    a = Driver.action(:spend, [4])
    e = %Event{seq: 1, session_id: "a", parent_id: nil, turn: 0, action: a, result: {:ok, 6}}

    assert Event.rationale(e) == nil
    assert Event.rationale(%{e | rationale: "spending leaves room"}) == "spending leaves room"

    # An event read back from a log written before the field existed has
    # no key for it. A trajectory outliving the build that wrote it is the
    # point of the log, so this must not raise.
    legacy = Map.delete(e, :rationale)
    assert Event.rationale(legacy) == nil
  end

  test "two branches that reasoned differently and acted the same are the same trajectory" do
    a = Driver.action(:get, ["k"])
    r = {:ok, "v"}
    e = %Event{seq: 1, session_id: "a", parent_id: nil, turn: 0, action: a, result: r}

    assert Event.key(%{e | rationale: "reading it back proves the store kept it"}) ==
             Event.key(%{e | rationale: "I have nothing better to do"})
  end

  test "identity and position fields are required" do
    assert_raise ArgumentError, fn ->
      Code.eval_quoted(quote do: %Tiller.Event{action: :halt})
    end
  end
end
