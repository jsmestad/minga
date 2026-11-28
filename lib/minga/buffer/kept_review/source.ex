defmodule Minga.Buffer.KeptReview.Source do
  @moduledoc """
  A byte splice backed by direct provenance in one Keep projection. The point is in the saved postimage, not a later live document or a Git blob. Insertions can retain disjoint visible fragments. A replacement is evidence only when both complete sides survive as one splice.
  """

  alias Minga.Buffer.Provenance

  @enforce_keys [:kind, :id, :offset, :point, :old, :new]
  defstruct [:kind, :id, :offset, :point, :old, :new]

  @type t :: %__MODULE__{
          kind: :insert | :replace | :delete,
          id: pos_integer(),
          offset: non_neg_integer(),
          point: non_neg_integer(),
          old: binary(),
          new: binary()
        }

  @doc "Collects ordered operation witnesses whose byte extents still exist in this postimage."
  @spec project([Provenance.keep_source()], binary()) :: [t()]
  def project(fragments, content) when is_binary(content) do
    fragments
    |> Enum.group_by(fn {_, {kind, id, _, _}, _, _} -> {kind, id} end)
    |> Enum.flat_map(fn {{kind, id}, parts} -> project_operation(kind, id, parts, content) end)
    |> in_postimage_order()
  end

  @doc "Orders witnesses and excludes sites whose inverses conflict."
  @spec in_postimage_order([t()]) :: [t()]
  def in_postimage_order(sources) do
    sources |> Enum.sort_by(&{&1.point, byte_size(&1.new)}) |> reject_overlapping()
  end

  @spec key(t()) :: Provenance.source_key()
  def key(%__MODULE__{id: id, kind: kind}), do: {kind, id}

  @doc "Binds surviving written fragments or a retained deletion gap to a new exact saved image."
  @spec rebind(t(), binary(), Provenance.kept_placements()) :: [t()]
  def rebind(%__MODULE__{} = source, content, placements) do
    bind_placements(source, content, Map.get(placements, key(source), []))
  end

  @spec bind_placements(t(), binary(), [Provenance.kept_placement()]) :: [t()]
  defp bind_placements(%__MODULE__{kind: :delete, old: old} = source, content, placements) do
    total = byte_size(old)

    gaps =
      for {:gap, {:delete, _, _, ^total}, point} <- placements,
          point <= byte_size(content),
          uniq: true,
          do: point

    case gaps do
      [point] -> [%{source | point: point}]
      _uncertain -> []
    end
  end

  defp bind_placements(%__MODULE__{kind: :replace, new: new} = source, content, placements) do
    case complete(rebound_written(source, content, placements), :written) do
      {:ok, point, total} when total == byte_size(new) -> [%{source | point: point}]
      _uncertain -> []
    end
  end

  defp bind_placements(%__MODULE__{kind: :insert} = source, content, placements) do
    source
    |> rebound_written(content, placements)
    |> Enum.reduce([], &join_written_part/2)
    |> Enum.map(fn {offset, point, _length, parts} ->
      %{source | offset: offset, point: point, new: join(parts)}
    end)
  end

  @spec rebound_written(t(), binary(), [Provenance.kept_placement()]) :: [part(binary())]
  defp rebound_written(source, content, placements) do
    Enum.sort(
      for {:visible, {_, _, at, total}, point, count} <- placements,
          first = max(at, source.offset),
          until = min(at + count, source.offset + byte_size(source.new)),
          first < until,
          start = point + first - at,
          length = until - first,
          start + length <= byte_size(content),
          bytes = binary_part(content, start, length),
          bytes == binary_part(source.new, first - source.offset, length),
          do: {first, start, bytes, total}
    )
  end

  @doc "Checks the stored source shape and, if bound, its bytes in the saved image."
  @spec valid?(term(), binary() | nil) :: boolean()
  def valid?(%__MODULE__{} = source, content) do
    case source do
      %__MODULE__{kind: :insert, old: "", new: new} when is_binary(new) and new != "" ->
        valid_position?(source, content)

      %__MODULE__{kind: :delete, old: old, new: "", offset: 0}
      when is_binary(old) and old != "" ->
        valid_position?(source, content)

      %__MODULE__{kind: :replace, old: old, new: new, offset: 0}
      when is_binary(old) and old != "" and is_binary(new) and new != "" ->
        valid_position?(source, content)

      _invalid ->
        false
    end
  end

  def valid?(_invalid, _content), do: false

  @spec valid_position?(t(), binary() | nil) :: boolean()
  defp valid_position?(%__MODULE__{id: id, offset: offset, point: point, new: new}, content)
       when is_integer(id) and id > 0 and is_integer(offset) and offset >= 0 and
              is_integer(point) and point >= 0 do
    is_nil(content) or
      (point + byte_size(new) <= byte_size(content) and
         binary_part(content, point, byte_size(new)) == new)
  end

  defp valid_position?(_invalid, _content), do: false

  @spec project_operation(
          :insert | :replace | :delete,
          pos_integer(),
          [Provenance.keep_source()],
          binary()
        ) :: [t()]
  defp project_operation(:insert, id, fragments, content) do
    fragments
    |> written_parts(content)
    |> Enum.reduce([], &join_written_part/2)
    |> Enum.map(fn {offset, point, _length, parts} ->
      %__MODULE__{kind: :insert, id: id, offset: offset, point: point, old: "", new: join(parts)}
    end)
  end

  defp project_operation(:replace, id, fragments, content) do
    written = written_extents(fragments, byte_size(content))

    with {:ok, point, written_total} <- complete(written, :written),
         removed = removed_parts(fragments),
         {:ok, old_point, _removed_total} <- complete(removed, :removed),
         :ok <- follows_written(point, written_total, old_point) do
      new = :binary.copy(binary_part(content, point, written_total))
      old = join_removed(removed)

      [%__MODULE__{kind: :replace, id: id, offset: 0, point: point, old: old, new: new}]
    else
      :inexact -> []
    end
  end

  defp project_operation(:delete, id, fragments, _content) do
    removed = removed_parts(fragments)

    case complete(removed, :removed) do
      {:ok, point, _total} ->
        old = join_removed(removed)
        [%__MODULE__{kind: :delete, id: id, offset: 0, point: point, old: old, new: ""}]

      :inexact ->
        []
    end
  end

  @typep chunk :: {non_neg_integer(), non_neg_integer(), pos_integer(), [binary()]}

  @spec join_written_part(part(binary()), [chunk()]) :: [chunk()]
  defp join_written_part({offset, point, bytes, _total}, [{left, start, length, parts} | rest])
       when offset == left + length and point == start + length,
       do: [{left, start, length + byte_size(bytes), [bytes | parts]} | rest]

  defp join_written_part({offset, point, bytes, _total}, acc),
    do: [{offset, point, byte_size(bytes), [bytes]} | acc]

  @spec join([binary()]) :: binary()
  defp join([bytes]), do: :binary.copy(bytes)
  defp join(parts), do: parts |> Enum.reverse() |> :erlang.iolist_to_binary()

  @spec follows_written(non_neg_integer(), pos_integer(), non_neg_integer()) :: :ok | :inexact
  defp follows_written(point, total, old_point) do
    if point + total == old_point, do: :ok, else: :inexact
  end

  @typep part(payload) :: {non_neg_integer(), non_neg_integer(), payload, pos_integer()}

  @spec written_extents([Provenance.keep_source()], non_neg_integer()) :: [part(pos_integer())]
  defp written_extents(fragments, size) do
    Enum.sort(
      for {:written, {_, _, offset, total}, point, length} <- fragments,
          point + length <= size,
          do: {offset, point, length, total}
    )
  end

  @spec written_parts([Provenance.keep_source()], binary()) :: [part(binary())]
  defp written_parts(fragments, content) do
    size = byte_size(content)

    Enum.sort(
      for {:written, {_, _, offset, total}, point, length} <- fragments,
          point + length <= size,
          do: {offset, point, binary_part(content, point, length), total}
    )
  end

  @spec removed_parts([Provenance.keep_source()]) :: [part(binary())]
  defp removed_parts(fragments) do
    Enum.sort(
      for {:removed, {_, _, offset, total}, point, bytes} <- fragments,
          do: {offset, point, bytes, total}
    )
  end

  @spec join_removed([part(binary())]) :: binary()
  defp join_removed([{_, _, bytes, _}]), do: :binary.copy(bytes)

  defp join_removed(parts) do
    parts |> Enum.map(fn {_, _, bytes, _} -> bytes end) |> :erlang.iolist_to_binary()
  end

  @spec complete([part(binary() | pos_integer())], :written | :removed) ::
          {:ok, non_neg_integer(), pos_integer()} | :inexact
  defp complete([{0, point, _, total} | _] = parts, side) do
    consumed =
      Enum.reduce_while(parts, 0, fn {offset, at, payload, declared}, consumed ->
        expected = if side == :written, do: point + consumed, else: point

        if offset == consumed and at == expected and total == declared,
          do: {:cont, consumed + payload_size(payload)},
          else: {:halt, :inexact}
      end)

    if consumed == total, do: {:ok, point, total}, else: :inexact
  end

  defp complete(_fragmentary, _side), do: :inexact

  @spec payload_size(binary() | pos_integer()) :: non_neg_integer()
  defp payload_size(bytes) when is_binary(bytes), do: byte_size(bytes)
  defp payload_size(length), do: length

  # Different deletions at one zero-width point have no proven relative order.
  # A source spanning a different source's point also has no independent inverse.
  @spec reject_overlapping([t()]) :: [t()]
  defp reject_overlapping([]), do: []

  defp reject_overlapping([first | rest]),
    do: reject_overlapping(rest, first, first.point + byte_size(first.new), true, [])

  @spec reject_overlapping([t()], t(), non_neg_integer(), boolean(), [t()]) :: [t()]
  defp reject_overlapping([], last, _stop, usable?, acc),
    do: Enum.reverse(maybe_append(last, usable?, acc))

  defp reject_overlapping([next | rest], previous, stop, usable?, acc) do
    conflict? =
      next.point < stop or
        (previous.new == "" and next.new == "" and previous.point == next.point)

    acc = maybe_append(previous, usable? and not conflict?, acc)
    next_stop = next.point + byte_size(next.new)
    stop = if conflict?, do: max(stop, next_stop), else: next_stop
    reject_overlapping(rest, next, stop, not conflict?, acc)
  end

  @spec maybe_append(t(), boolean(), [t()]) :: [t()]
  defp maybe_append(source, true, acc), do: [source | acc]
  defp maybe_append(_source, false, acc), do: acc
end
