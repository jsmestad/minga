defmodule Minga.Buffer.ReviewRibbon do
  @moduledoc "Projects pending history units into source-line ribbons without changing decision authority."

  alias Minga.Buffer.Document
  alias Minga.Buffer.Lines
  alias Minga.Buffer.Position
  alias Minga.Buffer.Provenance
  alias Minga.Buffer.ReviewDamage
  alias Minga.Buffer.UndoHistory

  @type t :: {[non_neg_integer()], non_neg_integer(), non_neg_integer()}
  @type head :: {:text | :gap, pos_integer(), Document.position()}
  @type extent :: {:lines, pos_integer()} | {:removed_bytes, pos_integer()} | :none
  @typep bounds :: {non_neg_integer(), non_neg_integer(), boolean()}
  @typep piece :: UndoHistory.review_region()
  @typep members :: %{Provenance.group_id() => Provenance.group_id()}

  @doc "Returns ribbons touching the sparse byte ranges, extending clipped ribbons to their real ends."
  @spec regions(UndoHistory.t(), Document.t(), [bounds()]) :: [t()]
  def regions(history, document, bounds) do
    {groups, _members} = Enum.map_reduce(bounds, %{}, &regions_in(history, document, &1, &2))

    groups
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort_by(fn {_units, first, stop} -> {first, stop} end)
  end

  @spec regions_in(UndoHistory.t(), Document.t(), bounds(), members()) :: {[t()], members()}
  defp regions_in(history, document, bounds, members) do
    case UndoHistory.review_regions(history, [bounds], members) do
      {[], members} ->
        {[], members}

      {[first | _] = pieces, members} ->
        [last | reversed] = Enum.reverse(pieces)
        {start, members} = extend(history, document, first, :left, [], members)
        {finish, members} = extend(history, document, last, :right, [], members)

        ordered = :lists.reverse(reversed, [last | Enum.reverse(finish)])
        {fold_pieces(start ++ ordered, history, document), members}
    end
  end

  @spec fold_pieces([piece()], UndoHistory.t(), Document.t()) :: [t()]
  defp fold_pieces(pieces, history, document) do
    pieces
    |> Enum.reduce([], fn piece, acc -> append(acc, piece, history, document) end)
    |> Enum.reverse()
    |> Enum.map(fn {units, first, stop, _last} -> {Enum.reverse(units), first, stop} end)
  end

  @spec append(
          [{[non_neg_integer()], non_neg_integer(), non_neg_integer(), piece()}],
          piece(),
          UndoHistory.t(),
          Document.t()
        ) ::
          [{[non_neg_integer()], non_neg_integer(), non_neg_integer(), piece()}]
  defp append([{units, first, _, prev} | rest] = acc, {unit, _, stop} = piece, history, document) do
    if connected?(history, document, prev, piece) do
      [{[unit | units], first, stop, piece} | rest]
    else
      append_piece(acc, piece)
    end
  end

  defp append([], piece, _history, _document), do: append_piece([], piece)

  defp append_piece(acc, {unit, start, stop} = piece), do: [{[unit], start, stop, piece} | acc]

  @spec extend(UndoHistory.t(), Document.t(), piece(), :left | :right, [piece()], members()) ::
          {[piece()], members()}
  defp extend(history, document, piece, direction, acc, members) do
    case neighbors(history, document, piece, direction, members) do
      {[], members} ->
        {acc, members}

      {pieces, members} ->
        case walk_chunk(history, document, piece, direction, pieces, acc) do
          {:more, edge, acc} -> extend(history, document, edge, direction, acc, members)
          {:done, acc} -> {acc, members}
        end
    end
  end

  # Consume the ordered chunk rather than re-querying the same long row for each site.
  defp walk_chunk(_history, _document, edge, _direction, [], acc), do: {:more, edge, acc}

  defp walk_chunk(history, document, piece, direction, [other | rest], acc) do
    {left, right} = if direction == :left, do: {other, piece}, else: {piece, other}

    if connected?(history, document, left, right),
      do: walk_chunk(history, document, other, direction, rest, [other | acc]),
      else: {:done, acc}
  end

  @spec neighbors(UndoHistory.t(), Document.t(), piece(), :left | :right, members()) ::
          {[piece()], members()}
  defp neighbors(_history, _document, {_, point, point}, _direction, members), do: {[], members}

  defp neighbors(history, document, {_, start, _}, :left, members) do
    row = row_at(document, start)
    from = Lines.start_of(document, max(0, row - 1))

    {pieces, members} = UndoHistory.review_regions(history, [{from, start, false}], members)
    {Enum.reverse(pieces), members}
  end

  defp neighbors(history, document, {_, _, stop}, :right, members) do
    after_row = row_at(document, stop - 1) + 2
    eof? = after_row >= Document.line_count(document)

    to =
      if eof?, do: Document.content_byte_size(document), else: Lines.start_of(document, after_row)

    UndoHistory.review_regions(history, [{stop, to, eof?}], members)
  end

  @spec connected?(UndoHistory.t(), Document.t(), piece(), piece()) :: boolean()
  defp connected?(history, document, {left, start, stop}, {right, next, finish}) do
    start < stop and next < finish and stop <= next and
      row_at(document, next) <= row_at(document, stop - 1) + 1 and
      UndoHistory.same_review_task?(history, left, right) and
      is_nil(first_gap_after(history, start, next))
  end

  defp first_gap_after(history, left, right) do
    history
    |> UndoHistory.provenance()
    |> Provenance.review_sites_from(left, :next)
    |> Enum.reduce_while(nil, fn
      {_group, from, _to}, _ when from > right -> {:halt, nil}
      {_group, point, point}, _ when point > left -> {:halt, point}
      _site, _ -> {:cont, nil}
    end)
  end

  @doc "Finds the ribbon under an exact pending byte, with direct deletion anchors taking precedence."
  @spec at(UndoHistory.t(), Document.t(), non_neg_integer()) :: t() | nil
  def at(history, document, point) do
    if UndoHistory.pending_at?(history, point) do
      size = Document.content_byte_size(document)

      ribbons = regions(history, document, [{point, min(point + 1, size), point == size}])

      ribbon_at(ribbons, history, point)
    end
  end

  defp ribbon_at(ribbons, history, point) do
    case Enum.filter(ribbons, fn {_units, first, stop} -> first == stop and first == point end) do
      [] ->
        Enum.find(ribbons, fn {_units, first, stop} -> first <= point and point < stop end)

      [gap] ->
        gap

      [fallback | _] = gaps ->
        unit = UndoHistory.review_unit_at(history, point)
        Enum.find(gaps, fallback, fn {units, _, _} -> unit in units end)
    end
  end

  @doc "Moves through distinct visible heads, preserving standalone deletion stops."
  @spec move(UndoHistory.t(), Document.t(), non_neg_integer(), :next | :previous, pos_integer()) ::
          non_neg_integer() | nil
  def move(history, document, point, direction, count),
    do: move_heads(history, document, point, direction, count, nil)

  defp move_heads(_history, _doc, _point, _direction, 0, result), do: result

  defp move_heads(history, doc, point, direction, count, result) do
    case next_head(history, doc, point, direction) do
      nil -> result
      head -> move_heads(history, doc, head, direction, count - 1, head)
    end
  end

  defp next_head(history, doc, point, direction) do
    with raw when is_integer(raw) <- UndoHistory.review_motion(history, point, direction, 1),
         {_, _, _} = ribbon <- at(history, doc, raw) do
      visible_head(history, doc, point, direction, raw, ribbon)
    else
      _ -> nil
    end
  end

  defp visible_head(history, doc, point, :next, raw, {units, head, stop}) when head <= point do
    skip_to = if match?([_, _ | _], units), do: max(raw, stop - 1), else: raw
    first_gap_after(history, point, skip_to) || next_head(history, doc, skip_to, :next)
  end

  defp visible_head(_history, _doc, _point, _direction, _raw, {_, head, _}), do: head

  @doc "Prepares the current ribbon and additional ribbons with previously unselected units."
  @spec prepare(UndoHistory.t(), Document.t(), non_neg_integer(), pos_integer()) ::
          {:ok, UndoHistory.review_target()} | :empty
  def prepare(history, document, point, count) do
    case at(history, document, point) do
      nil -> :empty
      ribbon -> collect_units(history, document, ribbon, point, count, MapSet.new(), [])
    end
  end

  @doc "Prepares the whole units of the exact displayed text or deletion head."
  @spec prepare_presented(UndoHistory.t(), Document.t(), head()) ::
          {:ok, UndoHistory.review_target()} | :empty
  def prepare_presented(history, document, {kind, unit, {row, column} = position}) do
    case Document.line_at(document, row) do
      text when is_binary(text) and column <= byte_size(text) ->
        point = Position.point_for(document, position)
        size = Document.content_byte_size(document)

        history
        |> regions(document, [{point, min(point + 1, size), point == size}])
        |> Enum.find_value(:empty, fn
          {[^unit | _] = units, ^point, stop}
          when (kind == :gap and stop == point) or (kind == :text and stop > point) ->
            UndoHistory.prepare_review_units(history, units)

          _other ->
            nil
        end)

      _outside ->
        :empty
    end
  end

  defp collect_units(history, doc, {units, head, stop}, point, count, seen, acc) do
    {seen, acc, added?} =
      Enum.reduce(units, {seen, acc, false}, fn unit, {seen, acc, added?} ->
        if MapSet.member?(seen, unit),
          do: {seen, acc, added?},
          else: {MapSet.put(seen, unit), [unit | acc], true}
      end)

    remaining = if added?, do: count - 1, else: count

    with n when n > 0 <- remaining,
         {_, next, _} = ribbon <- next_decision_ribbon(history, doc, point, head, stop) do
      collect_units(history, doc, ribbon, next, n, seen, acc)
    else
      _ -> UndoHistory.prepare_review_units(history, Enum.reverse(acc))
    end
  end

  defp next_decision_ribbon(history, doc, head, head, head) do
    size = Document.content_byte_size(doc)

    history
    |> regions(doc, [{head, min(head + 1, size), head == size}])
    |> Enum.find(fn {_units, first, stop} -> first == head and stop > head end)
    |> case do
      nil -> next_decision_ribbon(history, doc, head, head, nil)
      ribbon -> ribbon
    end
  end

  defp next_decision_ribbon(history, doc, point, _head, _stop) do
    with next when is_integer(next) <- next_head(history, doc, point, :next),
         do: at(history, doc, next)
  end

  @doc "Returns the inclusive source rows occupied by a ribbon or a standalone anchor."
  @spec source_rows(Document.t(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def source_rows(document, start, stop),
    do: {row_at(document, start), row_at(document, max(start, stop - 1))}

  @doc "Counts distinct written source rows, or the retained preimage size of a deletion-only offer."
  @spec extent(Document.t(), [Provenance.keep_source()]) :: extent()
  def extent(document, sources) do
    {ranges, removed} =
      Enum.reduce(sources, {[], 0}, fn
        {:written, _origin, start, bytes}, {ranges, removed} ->
          {[source_rows(document, start, start + bytes) | ranges], removed}

        {:removed, _origin, _point, text}, {ranges, removed} ->
          {ranges, removed + byte_size(text)}
      end)

    case ranges do
      [] when removed > 0 ->
        {:removed_bytes, removed}

      [] ->
        :none

      ranges ->
        lines =
          ranges
          |> ReviewDamage.merge_ranges([])
          |> Enum.reduce(0, fn {first, last}, total -> total + last - first + 1 end)

        {:lines, lines}
    end
  end

  @doc "Expands byte damage to source rows on either side of each potential join."
  @spec damage_rows(Document.t(), [{non_neg_integer(), non_neg_integer()}]) ::
          [{non_neg_integer(), non_neg_integer()}]
  def damage_rows(document, sites) do
    last_row = Document.line_count(document) - 1

    ranges =
      for {start, stop} <- sites do
        {max(0, row_at(document, start) - 1),
         min(last_row, row_at(document, max(start, stop - 1)) + 1)}
      end

    ReviewDamage.merge_ranges(ranges, [])
  end

  @doc "Converts a source row range to a half-open byte window including any final deletion anchor."
  @spec byte_bounds(Document.t(), non_neg_integer(), non_neg_integer()) :: bounds()
  def byte_bounds(document, first, last) do
    from = Lines.start_of(document, first)

    if last + 1 < Document.line_count(document),
      do: {from, Lines.start_of(document, last + 1), false},
      else: {from, Document.content_byte_size(document), true}
  end

  defp row_at(document, byte), do: elem(Lines.containing(document, byte), 0)
end
