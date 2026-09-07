defmodule Tiller.DecisionsTest do
  @moduledoc """
  The decision log is documentation, but it is machine-readable
  documentation, and both files are appended to on nearly every branch.
  That makes them the most conflict-prone files in the repo, and nothing
  else here would notice if a merge left markers behind or dropped an
  entry: this suite is what noticed, the once it happened.

  The marker and parse checks sweep every machine-readable file under
  docs/, not just the two decision files, because the property that got
  us is shared by all of them: appended to on every branch, read by
  nothing, so a bad merge is invisible until someone opens the file.
  """
  use ExUnit.Case, async: true

  @jsonl "docs/decisions.jsonl"
  @active "docs/decisions.active.json"

  defp read!(path), do: File.read!(Path.join(File.cwd!(), path))

  defp machine_readable_docs do
    cwd = File.cwd!()

    ["docs/*.json", "docs/*.jsonl"]
    |> Enum.flat_map(&Path.wildcard(Path.join(cwd, &1)))
    |> Enum.map(&Path.relative_to(&1, cwd))
    |> Enum.sort()
  end

  test "no machine-readable doc carries a conflict marker" do
    paths = machine_readable_docs()
    assert @jsonl in paths and @active in paths

    for path <- paths, line <- String.split(read!(path), "\n") do
      refute String.starts_with?(line, ["<<<<<<<", "=======", ">>>>>>>"]),
             "#{path} still has a merge conflict in it: #{line}"
    end
  end

  test "every machine-readable doc parses" do
    for path <- machine_readable_docs() do
      contents = read!(path)

      decoded =
        case Path.extname(path) do
          ".jsonl" -> Enum.map(String.split(contents, "\n", trim: true), &JSON.decode/1)
          ".json" -> [JSON.decode(contents)]
        end

      for {result, i} <- Enum.with_index(decoded, 1) do
        assert match?({:ok, _}, result),
               "#{path} does not parse (entry #{i}): #{inspect(result)}"
      end
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
