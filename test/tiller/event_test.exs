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

  test "identity and position fields are required" do
    assert_raise ArgumentError, fn ->
      Code.eval_quoted(quote do: %Tiller.Event{action: :halt})
    end
  end
end
