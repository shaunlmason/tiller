defmodule Tiller.State.LogTest do
  @moduledoc """
  The durable log as a file format: what it stores, what it stores only
  once, and what it does with a tail a crash cut in half.
  """
  use ExUnit.Case, async: true

  alias Tiller.State.Log

  setup do
    path = Path.join(System.tmp_dir!(), "tiller-log-#{System.unique_integer([:positive])}.log")
    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, path: path}
  end

  defp message(n), do: %{"role" => "assistant", "content" => String.duplicate("m#{n}", 120)}

  defp snapshot(id, turn, messages),
    do:
      {:snapshot, id, turn, %{ctx: %{messages: messages, turn: turn}, tool_state: %{budget: 10}}}

  defp size(path), do: File.stat!(path).size

  test "every frame comes back the way it went in", %{path: path} do
    event = %Tiller.Event{
      seq: 1,
      session_id: "root",
      turn: 0,
      action: Tiller.Driver.action(:echo, ["hi"]),
      result: {:ok, "echo"},
      rationale: "because"
    }

    frames = [
      {:event, event},
      snapshot("root", 1, Enum.map(1..40, &message/1)),
      {:profile, "root", %{driver: Tiller.FakeDriver, whitelist: [{:echo, 1}]}},
      {:resumes, "root", 2},
      # the shapes the sharing walks: nested lists, tuples, maps, and
      # something small enough to be left alone
      {:snapshot, "b", 0, %{ctx: %{nested: [Enum.map(1..20, &message/1), {:pair, [1, 2, 3]}]}}}
    ]

    log = Log.open(path)
    Log.append_all(log, frames)

    assert Log.read(path) == frames
  end

  test "an element is stored once, however many frames name it", %{path: path} do
    # A conversation: each frame holds every message the last one held,
    # plus one. Storing that inline is what made the log grow with the
    # square of the run.
    messages = Enum.map(1..60, &message/1)

    unique =
      messages |> Enum.map(&:erlang.term_to_binary/1) |> Enum.map(&byte_size/1) |> Enum.sum()

    log =
      Enum.reduce(1..60, Log.open(path), fn turn, log ->
        Log.append_all(log, [snapshot("root", turn, Enum.take(messages, turn))])
      end)

    # Inline, the sixty snapshots would hold about 60 * 61 / 2 messages.
    inline = div(unique * 61, 2)
    assert size(path) < div(inline, 10), "expected well under a tenth of #{inline} bytes"

    # And the frames still describe the same run.
    assert Log.read(path) ==
             for(turn <- 1..60, do: snapshot("root", turn, Enum.take(messages, turn)))

    # One more turn costs about one more message, not one more run.
    before = size(path)
    Log.append_all(log, [snapshot("root", 61, messages ++ [message(61)])])
    assert size(path) - before < 4 * byte_size(:erlang.term_to_binary(message(61)))
  end

  test "a list consumed from the front shares as well as one grown at the end", %{path: path} do
    # A replayed prefix shrinks by one a turn, which is the other shape a
    # driver context has. Boundaries that moved with every edit would
    # rewrite every group.
    messages = Enum.map(1..60, &message/1)

    log =
      Enum.reduce(0..59, Log.open(path), fn turn, log ->
        Log.append_all(log, [snapshot("branch", turn, Enum.drop(messages, turn))])
      end)

    unique =
      messages |> Enum.map(&:erlang.term_to_binary/1) |> Enum.map(&byte_size/1) |> Enum.sum()

    assert size(path) < 3 * unique

    assert Log.read(path) ==
             for(turn <- 0..59, do: snapshot("branch", turn, Enum.drop(messages, turn)))

    assert %Log{} = log
  end

  test "a list of identical elements stays bounded rather than rewriting itself", %{path: path} do
    # Identical elements hash identically, so content alone never names a
    # boundary. Without a cap this is the quadratic case again.
    same = List.duplicate(message(:same), 200)

    log =
      Enum.reduce(1..40, Log.open(path), fn turn, log ->
        Log.append_all(log, [snapshot("same", turn, Enum.take(same, 5 * turn))])
      end)

    assert size(path) < 100_000

    assert Log.read(path) ==
             for(turn <- 1..40, do: snapshot("same", turn, Enum.take(same, 5 * turn)))

    assert %Log{} = log
  end

  test "reopening does not rewrite what the file already holds", %{path: path} do
    messages = Enum.map(1..40, &message/1)
    log = Log.open(path)
    Log.append_all(log, [snapshot("root", 1, messages)])
    first = size(path)

    # What a restart does: the frames come back, and the handle that comes
    # with them knows which elements are already on disk.
    {frames, log} = Log.restore(path)
    assert frames == [snapshot("root", 1, messages)]

    Log.append_all(log, [snapshot("root", 2, messages)])
    added = size(path) - first

    assert added < 2_000, "a snapshot of unchanged messages cost #{added} bytes"
    assert Log.read(path) == [snapshot("root", 1, messages), snapshot("root", 2, messages)]
  end

  test "a tail a crash cut in half is dropped, and the next append lands where it is read",
       %{path: path} do
    messages = Enum.map(1..30, &message/1)
    log = Log.open(path)
    Log.append_all(log, [snapshot("root", 1, messages)])
    whole = size(path)

    # a write that did not finish
    File.write!(path, File.read!(path) <> <<255, 255, 255, 255, 1, 2, 3>>)

    assert Log.read(path) == [snapshot("root", 1, messages)]

    log = Log.open(path)
    assert size(path) == whole
    Log.append_all(log, [{:resumes, "root", 1}])

    assert Log.read(path) == [snapshot("root", 1, messages), {:resumes, "root", 1}]
  end

  test "truncate empties the file and forgets what was in it", %{path: path} do
    messages = Enum.map(1..40, &message/1)
    log = Log.append_all(Log.open(path), [snapshot("root", 1, messages)])

    log = Log.truncate(log, path)
    assert Log.read(path) == []

    # The elements are gone from the file, so they are written again
    # rather than referenced into nothing.
    Log.append_all(log, [snapshot("root", 1, messages)])
    assert Log.read(path) == [snapshot("root", 1, messages)]
  end
end
