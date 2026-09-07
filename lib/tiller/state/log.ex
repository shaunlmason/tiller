defmodule Tiller.State.Log do
  @moduledoc """
  The store's durable form: an append-only file of length-prefixed
  `:erlang.term_to_binary/1` frames, one per write.

  Read whole at start, appended to on every write. A frame torn by a
  crash mid-write is dropped rather than refused, because a half-written
  tail is the normal way this file ends, and the file is truncated back
  to the last whole frame before anything is appended: otherwise the new
  frames would sit behind the torn one where no reader would ever reach
  them.

  Frames that must survive together are written together, in one call, so
  a crash leaves either both or a tail the truncation above removes.

  Frames: `{:event, event}`, `{:snapshot, id, turn, snap}`,
  `{:profile, id, profile}` and `{:resumes, id, n}`. That is everything
  `Tiller.State` holds except subscriptions, which are pids and mean
  nothing after a restart.
  """

  @doc "Every frame in order; a partial final frame is ignored."
  @spec read(Path.t()) :: [term]
  def read(path), do: path |> load() |> elem(0)

  @doc """
  Every whole frame, and how many bytes they occupy.

  The byte count is what separates a file that ends cleanly from one with
  a torn tail, which is what `open/1` needs in order to append somewhere a
  reader will look.
  """
  @spec load(Path.t()) :: {[term], non_neg_integer}
  def load(path) do
    case File.read(path) do
      {:ok, bin} -> frames(bin, [], 0)
      {:error, :enoent} -> {[], 0}
    end
  end

  @doc """
  Open for appending, creating the directory and dropping any torn tail.

  Appending after a partial frame would put every later frame behind it,
  where `load/1` stops, so the file is cut back to the last whole frame
  first.
  """
  @spec open(Path.t()) :: File.io_device()
  def open(path) do
    File.mkdir_p!(Path.dirname(path))
    trim(path)
    File.open!(path, [:append, :binary, :raw])
  end

  defp trim(path) do
    case File.read(path) do
      {:ok, bin} ->
        {_frames, whole} = frames(bin, [], 0)
        if byte_size(bin) > whole, do: File.write!(path, binary_part(bin, 0, whole))

      {:error, :enoent} ->
        :ok
    end
  end

  @doc "Append one frame."
  @spec append(File.io_device(), term) :: :ok
  def append(io, frame), do: append_all(io, [frame])

  @doc """
  Append several frames in one write, for facts that must not be
  separated by a crash.
  """
  @spec append_all(File.io_device(), [term]) :: :ok
  def append_all(io, frames) do
    IO.binwrite(io, Enum.map_join(frames, &encode/1))
  end

  defp encode(frame) do
    bin = :erlang.term_to_binary(frame)
    <<byte_size(bin)::32, bin::binary>>
  end

  @doc "Empty the file and hand back a fresh handle."
  @spec truncate(File.io_device(), Path.t()) :: File.io_device()
  def truncate(io, path) do
    File.close(io)
    File.write!(path, "")
    open(path)
  end

  defp frames(<<size::32, bin::binary-size(size), rest::binary>>, acc, whole) do
    frames(rest, [:erlang.binary_to_term(bin) | acc], whole + 4 + size)
  end

  defp frames(_partial_or_empty, acc, whole), do: {Enum.reverse(acc), whole}
end
