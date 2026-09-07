defmodule Tiller.State.Log do
  @moduledoc """
  The store's durable form: an append-only file of length-prefixed
  `:erlang.term_to_binary/1` frames, one per write.

  Read whole at start, appended to on every write. A frame torn by a
  crash mid-write is dropped rather than refused, because a half-written
  tail is the normal way this file ends.

  Frames: `{:event, event}`, `{:snapshot, id, turn, snap}`,
  `{:profile, id, profile}` and `{:resumes, id, n}`. That is everything
  `Tiller.State` holds except subscriptions, which are pids and mean
  nothing after a restart.
  """

  @doc "Every frame in order; a partial final frame is ignored."
  @spec read(Path.t()) :: [term]
  def read(path) do
    case File.read(path) do
      {:ok, bin} -> frames(bin, [])
      {:error, :enoent} -> []
    end
  end

  @doc "Open for appending, creating the directory."
  @spec open(Path.t()) :: File.io_device()
  def open(path) do
    File.mkdir_p!(Path.dirname(path))
    File.open!(path, [:append, :binary, :raw])
  end

  @doc "Append one frame."
  @spec append(File.io_device(), term) :: :ok
  def append(io, frame) do
    bin = :erlang.term_to_binary(frame)
    IO.binwrite(io, <<byte_size(bin)::32, bin::binary>>)
  end

  @doc "Empty the file and hand back a fresh handle."
  @spec truncate(File.io_device(), Path.t()) :: File.io_device()
  def truncate(io, path) do
    File.close(io)
    File.write!(path, "")
    open(path)
  end

  defp frames(<<size::32, bin::binary-size(size), rest::binary>>, acc) do
    frames(rest, [:erlang.binary_to_term(bin) | acc])
  end

  defp frames(_partial_or_empty, acc), do: Enum.reverse(acc)
end
