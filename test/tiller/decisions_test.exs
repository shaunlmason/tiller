defmodule Tiller.DecisionsTest do
  @moduledoc """
  The decision log is documentation, but it is machine-readable
  documentation, and both files are appended to on nearly every branch.
  That makes them the most conflict-prone files in the repo, and nothing
  else here would notice if a merge left markers behind or dropped an
  entry: this suite is what noticed, the once it happened.
  """
  use ExUnit.Case, async: true

  @jsonl "docs/decisions.jsonl"
  @active "docs/decisions.active.json"

  defp read!(path), do: File.read!(Path.join(File.cwd!(), path))

  test "neither decision file carries a conflict marker" do
    for path <- [@jsonl, @active], line <- String.split(read!(path), "\n") do
      refute String.starts_with?(line, ["<<<<<<<", "=======", ">>>>>>>"]),
             "#{path} still has a merge conflict in it: #{line}"
    end
  end

  test "every line of the log is one decision" do
    entries =
      @jsonl
      |> read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert entries != []

    for entry <- entries do
      assert is_binary(entry["id"])
      assert is_binary(entry["decision"])
    end

    ids = Enum.map(entries, & &1["id"])
    assert ids == Enum.uniq(ids), "the log repeats an id"
  end

  test "the active set is a JSON array with no repeats" do
    active = JSON.decode!(read!(@active))

    assert is_list(active)
    ids = Enum.map(active, & &1["id"])
    assert ids == Enum.uniq(ids), "the active set repeats an id"
  end

  test "the active set and the log agree" do
    logged = @jsonl |> read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    active = @active |> read!() |> JSON.decode!()

    # a merge that keeps one side of a tail append and not the other shows
    # up here, which is the failure this file exists for
    assert MapSet.new(active, & &1["id"]) == MapSet.new(logged, & &1["id"])
  end
end
