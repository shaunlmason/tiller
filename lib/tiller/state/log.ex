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

  ## Sharing what does not change

  A session parks a snapshot of its driver context every turn, and for a
  model the context is the conversation: turn N holds everything turns
  0..N-1 held, plus one message. Serializing that whole term per turn
  made the file grow with the square of the run — a 200-turn run over an
  80KB conversation wrote 18MB, most of it the same messages over and
  over.

  So a big list is not written inline. Each element that is worth a
  frame of its own is written once as `{:blob, hash, bin}` and the list
  becomes a marker holding hashes; the next turn's list is the same
  hashes plus one, and only the new element reaches the disk. Long
  marker lists are themselves grouped into blobs and the same sharing
  applies to the groups, so what a turn writes is its own new data plus
  a few hashes rather than the run so far. Where a group ends is decided
  by the refs in it rather than by counting, so a list that grows at its
  end and one that shrinks at its front both keep the groups they did
  not touch.

  The elements are content-addressed, so this shares across sessions
  too: a fork's replayed prefix is byte-identical to its source's, and
  the branches of a race store one copy of it between them rather than
  one each.

  Nothing here knows what a driver context is. It walks the term, and a
  list of big things is the shape worth sharing whoever built it.

  What it costs, and what it does not do:

    * Writing is slower in CPU and much smaller on disk: every element is
      serialized to be addressed, where before the frame was serialized
      once in bulk. A 200-turn run takes 408ms rather than 64ms and
      writes 399KB rather than 21MB. A turn of that run is an API call,
      so 2ms of hashing buys 100KB not written.
    * Structs are not walked. An `Event` is small and a driver context is
      a plain map today; a driver that hid its conversation inside a
      struct would be stored whole.
    * Nothing collects a blob no frame names any more. The file only
      grows, which is what an append-only log means, and compaction is
      the answer when a session runs long enough to care.
    * The markers are atoms no ordinary term carries (`:"$tiller_blob"`
      and friends). A context that did carry one, in the shape of a
      marker, would be read back wrong.
  """

  @typedoc "An open log: the file and the blobs already in it."
  @type t :: %__MODULE__{io: File.io_device(), written: MapSet.t(binary)}
  defstruct [:io, :written]

  # An element smaller than this is cheaper to inline than to address.
  @min_element 64
  # Below this a list cannot repeat enough to pay for the machinery.
  @min_length 8
  # Refs per group, on average, once a marker's own list gets long. The
  # groups are blobs like any other, so a run of refs two lists share is
  # stored once between them.
  @fanout 8
  # No group covers more than this, whatever the content says.
  @max_group 32

  @blob :"$tiller_blob"
  @shared :"$tiller_shared"
  @group :"$tiller_group"

  @doc "Every frame in order, blobs resolved; a partial final frame is ignored."
  @spec read(Path.t()) :: [term]
  def read(path), do: path |> load() |> elem(0)

  @doc """
  Every whole frame with its blobs resolved, and how many bytes the file's
  whole frames occupy.

  The byte count is what separates a file that ends cleanly from one with
  a torn tail, which is what `open/1` needs in order to append somewhere a
  reader will look.
  """
  @spec load(Path.t()) :: {[term], non_neg_integer}
  def load(path) do
    {frames, whole, _blobs} = scan(path)
    {frames, whole}
  end

  @doc """
  What a store needs at start: the frames the file describes and a handle
  that appends to it, already knowing which blobs it holds.

  One read rather than two, and the handle it returns will not write an
  element the file already carries.
  """
  @spec restore(Path.t()) :: {[term], t}
  def restore(path) do
    {frames, whole, blobs} = scan(path)
    {frames, open_at(path, whole, MapSet.new(Map.keys(blobs)))}
  end

  @doc """
  Open for appending, creating the directory and dropping any torn tail.

  Appending after a partial frame would put every later frame behind it,
  where `load/1` stops, so the file is cut back to the last whole frame
  first.
  """
  @spec open(Path.t()) :: t
  def open(path) do
    {_frames, whole, blobs} = scan(path)
    open_at(path, whole, MapSet.new(Map.keys(blobs)))
  end

  defp open_at(path, whole, written) do
    File.mkdir_p!(Path.dirname(path))
    trim(path, whole)
    %__MODULE__{io: File.open!(path, [:append, :binary, :raw]), written: written}
  end

  defp trim(path, whole) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > whole ->
        {:ok, bin} = File.read(path)
        File.write!(path, binary_part(bin, 0, whole))

      _ ->
        :ok
    end
  end

  @doc "Append one frame. Returns the handle, which remembers what it wrote."
  @spec append(t, term) :: t
  def append(log, frame), do: append_all(log, [frame])

  @doc """
  Append several frames in one write, for facts that must not be
  separated by a crash.

  Blobs the frames need go in the same write, ahead of them, so a reader
  never meets a marker whose content is missing.
  """
  @spec append_all(t, [term]) :: t
  def append_all(%__MODULE__{} = log, frames) do
    {frames, blobs, written} =
      Enum.reduce(frames, {[], [], log.written}, fn frame, {acc, blobs, written} ->
        {frame, new, written} = share(frame, written)
        {[frame | acc], new ++ blobs, written}
      end)

    payload =
      Enum.map_join(blobs, fn {hash, bin} -> encode({:blob, hash, bin}) end) <>
        (frames |> Enum.reverse() |> Enum.map_join(&encode/1))

    IO.binwrite(log.io, payload)
    %{log | written: written}
  end

  defp encode(frame) do
    bin = :erlang.term_to_binary(frame)
    <<byte_size(bin)::32, bin::binary>>
  end

  @doc "Empty the file and hand back a fresh handle."
  @spec truncate(t, Path.t()) :: t
  def truncate(%__MODULE__{io: io}, path) do
    File.close(io)
    File.write!(path, "")
    open(path)
  end

  ## sharing

  # Walk a term, replacing lists of big things with markers and handing
  # back the blobs the caller must write first. `written` is what the file
  # already holds, so a message survives one write however many snapshots
  # name it.
  defp share(term, written) when is_list(term) do
    {items, blobs, written} = share_each(term, written)

    if length(items) >= @min_length do
      {refs, more, written} = refs_for(items, written)
      {marker, most, written} = collapse(refs, written)
      {marker, most ++ more ++ blobs, written}
    else
      {items, blobs, written}
    end
  end

  defp share(term, written) when is_map(term) and not is_struct(term) do
    {pairs, blobs, written} =
      Enum.reduce(term, {[], [], written}, fn {k, v}, {acc, blobs, written} ->
        {v, new, written} = share(v, written)
        {[{k, v} | acc], new ++ blobs, written}
      end)

    {Map.new(pairs), blobs, written}
  end

  defp share(term, written) when is_tuple(term) do
    {items, blobs, written} = term |> Tuple.to_list() |> share_each(written)
    {List.to_tuple(items), blobs, written}
  end

  defp share(term, written), do: {term, [], written}

  defp share_each(terms, written) do
    {items, blobs, written} =
      Enum.reduce(terms, {[], [], written}, fn item, {acc, blobs, written} ->
        {item, new, written} = share(item, written)
        {[item | acc], new ++ blobs, written}
      end)

    {Enum.reverse(items), blobs, written}
  end

  # One ref per element: a hash for anything big enough to be worth
  # addressing, the element itself for the rest.
  defp refs_for(items, written) do
    {refs, blobs, written} =
      Enum.reduce(items, {[], [], written}, fn item, {acc, blobs, written} ->
        bin = :erlang.term_to_binary(item)

        if byte_size(bin) >= @min_element do
          {ref, new, written} = blob(bin, written)
          {[ref | acc], new ++ blobs, written}
        else
          {[item | acc], blobs, written}
        end
      end)

    {Enum.reverse(refs), blobs, written}
  end

  # A marker's own list of refs grows by one a turn, so past a point it is
  # worth sharing the same way: groups of refs become blobs, and two
  # lists that share a run of refs share the groups covering it.
  defp collapse(refs, written) when length(refs) <= @fanout, do: {{@shared, refs}, [], written}

  defp collapse(refs, written) do
    {grouped, blobs, written} =
      refs
      |> group()
      |> Enum.reduce({[], [], written}, fn group, {acc, blobs, written} ->
        {ref, new, written} = blob(:erlang.term_to_binary({@group, group}), written)
        {[ref | acc], new ++ blobs, written}
      end)

    {marker, more, written} = collapse(Enum.reverse(grouped), written)
    {marker, more ++ blobs, written}
  end

  # Where the groups end is decided by the refs themselves, not by
  # counting: a conversation grows at its end and a replayed prefix
  # shrinks at its front, and a boundary every N refs would move with
  # every one of those edits, changing every group. A boundary that
  # depends only on the ref it follows stays put, so both shapes rewrite
  # the group they touched and no other. Groups average `@fanout` refs.
  defp group(refs) do
    groups =
      Enum.chunk_while(
        refs,
        [],
        fn ref, acc ->
          acc = [ref | acc]

          if boundary?(ref) or length(acc) >= @max_group,
            do: {:cont, Enum.reverse(acc), []},
            else: {:cont, acc}
        end,
        fn
          [] -> {:cont, []}
          acc -> {:cont, Enum.reverse(acc), []}
        end
      )

    # Every ref a boundary means the level below is the same length as
    # this one, and the recursion would never end. Counting is wrong for
    # sharing but right for making progress.
    if length(groups) < length(refs), do: groups, else: Enum.chunk_every(refs, @fanout)
  end

  # A list of identical elements has identical refs, so either every ref
  # is a boundary or none is. None would leave one group covering the
  # whole list, rewritten in full every time the list changed, which is
  # the growth this module exists to avoid. The cap turns that worst case
  # back into a bounded one.
  defp boundary?(ref), do: rem(:erlang.phash2(ref), @fanout) == 0

  defp blob(bin, written) do
    hash = :erlang.md5(bin)

    if MapSet.member?(written, hash) do
      {{@blob, hash}, [], written}
    else
      {{@blob, hash}, [{hash, bin}], MapSet.put(written, hash)}
    end
  end

  ## reading

  defp scan(path) do
    case File.read(path) do
      {:ok, bin} -> frames(bin, [], 0, %{})
      {:error, :enoent} -> {[], 0, %{}}
    end
  end

  defp frames(<<size::32, bin::binary-size(size), rest::binary>>, acc, whole, blobs) do
    case :erlang.binary_to_term(bin) do
      {:blob, hash, content} ->
        frames(rest, acc, whole + 4 + size, Map.put(blobs, hash, content))

      frame ->
        frames(rest, [resolve(frame, blobs) | acc], whole + 4 + size, blobs)
    end
  end

  defp frames(_partial_or_empty, acc, whole, blobs), do: {Enum.reverse(acc), whole, blobs}

  defp resolve({@shared, refs}, blobs), do: Enum.flat_map(refs, &expand(&1, blobs))

  defp resolve(term, blobs) when is_list(term), do: Enum.map(term, &resolve(&1, blobs))

  defp resolve(term, blobs) when is_map(term) and not is_struct(term),
    do: Map.new(term, fn {k, v} -> {k, resolve(v, blobs)} end)

  defp resolve(term, blobs) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.map(&resolve(&1, blobs)) |> List.to_tuple()
  end

  defp resolve(term, _blobs), do: term

  # A blob is either one element or a group of refs standing in for a run
  # of them, which is why expanding produces a list rather than a term.
  defp expand({@blob, hash}, blobs) do
    case :erlang.binary_to_term(Map.fetch!(blobs, hash)) do
      {@group, refs} -> Enum.flat_map(refs, &expand(&1, blobs))
      term -> [resolve(term, blobs)]
    end
  end

  defp expand(term, blobs), do: [resolve(term, blobs)]
end
