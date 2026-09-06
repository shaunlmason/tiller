defmodule Tiller.State.Log do
  @moduledoc """
  The store's durable form: an append-only file of length-prefixed
  `:erlang.term_to_binary/1` frames, one per event or packet write. On
  open the whole file is read back and replayed into the store, so a VM
  restart loses nothing recorded, and a truncated tail (a crash mid-write)
  is dropped rather than refused.

  Frames: `{:event, %Tiller.Event{}}` and `{:session, id, packet}`. Clear
  truncates the file.
  """

  @doc "Every frame in order; a partial final frame is ignored."
  @spec read(Path.t()) :: [term]
  def read(path) do
    case File.read(path) do
      {:ok, bin} -> frames(bin, [])
      {:error, :enoent} -> []
    end
  end

  @doc "Append one frame."
  @spec append(File.io_device(), term) :: :ok
  def append(io, term) do
    bin = :erlang.term_to_binary(term)
    IO.binwrite(io, <<byte_size(bin)::32, bin::binary>>)
  end

  @doc "Open for appending, creating the directory."
  def open(path) do
    File.mkdir_p!(Path.dirname(path))
    File.open!(path, [:append, :binary, :raw])
  end

  @doc "Truncate and reopen."
  def truncate(io, path) do
    File.close(io)
    File.write!(path, "")
    open(path)
  end

  defp frames(<<size::32, bin::binary-size(size), rest::binary>>, acc),
    do: frames(rest, [:erlang.binary_to_term(bin) | acc])

  defp frames(_partial_or_empty, acc), do: Enum.reverse(acc)
end
