defmodule Tiller.MutationTest do
  use ExUnit.Case, async: true

  alias Tiller.Mutation

  doctest Mutation

  test "one well-formed mutation per axis validates and reports its axis" do
    valid = [
      {:whitelist, [{:echo, 1}, {:spend, 1}]},
      {:driver, Tiller.FakeDriver, %{queue: []}},
      {:result_override, 3, {:ok, :forced}},
      {:latency, 200},
      {:kill_at, 2}
    ]

    for m <- valid do
      assert {:ok, ^m} = Mutation.validate(m)
      assert Mutation.axis(m) in Mutation.axes()
    end

    assert Enum.map(valid, &Mutation.axis/1) == Mutation.axes()
    assert Mutation.mvp_axes() == [:whitelist, :driver]
  end

  test "malformed mutations on a known axis are rejected with the axis named" do
    assert {:error, {:invalid, :whitelist, _}} = Mutation.validate({:whitelist, [:echo]})
    assert {:error, {:invalid, :kill_at, _}} = Mutation.validate({:kill_at, -1})
    assert {:error, {:invalid, :driver, _}} = Mutation.validate({:driver, "not a module"})
    assert {:error, {:unknown_mutation, _}} = Mutation.validate({:teleport, 1})
  end
end
