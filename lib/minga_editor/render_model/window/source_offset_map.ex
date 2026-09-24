defmodule MingaEditor.RenderModel.Window.SourceOffsetMap do
  @moduledoc """
  Maps source UTF-8 byte boundaries to composed UTF-16 boundaries and back.

  The map stores one span per composition edit plus the unchanged source spans
  between edits. It does not allocate an entry per grapheme, so an unmodified
  long line has one span.
  """

  alias Minga.Core.Decorations
  alias Minga.Core.Decorations.ConcealRange
  alias Minga.Core.Decorations.VirtualText
  alias Minga.Core.Unicode

  @type affinity :: :start | :end
  @type span_kind :: :source | :insertion | :replacement
  @type span ::
          {span_kind(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer()}
  @type insertion :: {non_neg_integer(), non_neg_integer()}
  @type replacement :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @typep piece :: {String.t(), span_kind(), non_neg_integer(), non_neg_integer()}

  @enforce_keys [
    :source_text,
    :source_start_byte,
    :source_end_byte,
    :composed_start_utf16,
    :composed_end_utf16,
    :spans,
    :insertions,
    :replacements
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source_text: String.t(),
          source_start_byte: non_neg_integer(),
          source_end_byte: non_neg_integer(),
          composed_start_utf16: non_neg_integer(),
          composed_end_utf16: non_neg_integer(),
          spans: [span()],
          insertions: [insertion()],
          replacements: [replacement()]
        }

  @doc "Creates a map for composition without tab expansion."
  @spec new(String.t(), String.t(), Decorations.t(), non_neg_integer()) :: t()
  def new(source_text, composed_text, %Decorations{} = decorations, line) do
    new(source_text, composed_text, decorations, line, [])
  end

  @doc """
  Creates a map for one composed logical line.

  `:tab_width` records source tabs as replacements expanded to the next tab
  stop. Omit it when `composed_text` retains raw tabs.
  """
  @spec new(String.t(), String.t(), Decorations.t(), non_neg_integer(), keyword()) :: t()
  def new(source_text, composed_text, %Decorations{} = decorations, line, opts) do
    tab_width = Keyword.get(opts, :tab_width)

    pieces =
      source_text
      |> conceal_pieces(decorations, line)
      |> insert_virtual_text(decorations, source_text, line)
      |> maybe_expand_tabs(tab_width)
      |> coalesce_pieces()

    {reversed_spans, built_utf16} = reversed_spans_from_pieces(pieces)
    composed_utf16 = utf16_length(composed_text)

    spans =
      reversed_spans
      |> prepend_unmapped_suffix(byte_size(source_text), built_utf16, composed_utf16)
      |> Enum.reverse()

    %__MODULE__{
      source_text: source_text,
      source_start_byte: 0,
      source_end_byte: byte_size(source_text),
      composed_start_utf16: 0,
      composed_end_utf16: composed_utf16,
      spans: spans,
      insertions: insertion_summaries(spans),
      replacements: replacement_summaries(spans)
    }
  end

  @spec slice(t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          t()
  def slice(%__MODULE__{} = map, source_start, source_end, composed_start, composed_end) do
    %{
      map
      | source_start_byte: source_start,
        source_end_byte: source_end,
        composed_start_utf16: composed_start,
        composed_end_utf16: composed_end
    }
  end

  @doc """
  Maps a source byte boundary to a composed UTF-16 boundary.

  At an insertion anchor, `:start` returns the boundary after inserted text and
  `:end` returns the boundary before it. This keeps inserted presentation out
  of source-backed accessibility ranges.
  """
  @spec source_to_composed_utf16(t(), non_neg_integer(), affinity()) :: non_neg_integer()
  def source_to_composed_utf16(%__MODULE__{} = map, source_byte, affinity) do
    source_byte = min(source_byte, byte_size(map.source_text))
    base = source_boundary(map, source_byte)

    map.spans
    |> Enum.filter(fn
      {:insertion, ^source_byte, ^source_byte, _start_utf16, _end_utf16} -> true
      _other -> false
    end)
    |> insertion_boundary(base, affinity)
  end

  @doc """
  Maps a composed UTF-16 boundary to a source UTF-8 byte boundary.

  Inserted text resolves to its source anchor. Inside replacement text,
  `:start` resolves to the replaced range start and `:end` resolves to its end.
  Inside a UTF-16 surrogate pair, affinity chooses the preceding or following
  source boundary. Offsets outside the line are clamped.
  """
  @spec composed_utf16_to_source_byte(t(), non_neg_integer(), affinity()) :: non_neg_integer()
  def composed_utf16_to_source_byte(%__MODULE__{} = map, composed_utf16, affinity) do
    composed_utf16 = min(composed_utf16, map.composed_end_utf16)

    candidates =
      map.spans
      |> Enum.flat_map(&source_candidates(&1, map.source_text, composed_utf16, affinity))

    choose_source_candidate(candidates, map, composed_utf16, affinity)
  end

  @doc """
  Resolves nondecreasing composed boundaries in one forward scan.

  This is the wrapping path for long lines. It preserves the semantics of
  `composed_utf16_to_source_byte/3` without rescanning an unchanged source
  prefix for every visual row boundary.
  """
  @spec composed_utf16_to_source_bytes(t(), [{non_neg_integer(), affinity()}]) ::
          [non_neg_integer()]
  def composed_utf16_to_source_bytes(%__MODULE__{} = map, boundaries) do
    {source_bytes, _cache} =
      Enum.map_reduce(boundaries, nil, fn {composed_utf16, affinity}, cache ->
        composed_utf16 = min(composed_utf16, map.composed_end_utf16)
        resolve_composed_boundary(map, composed_utf16, affinity, cache)
      end)

    source_bytes
  end

  @typep inverse_cache ::
           {span(), source_byte :: non_neg_integer(), composed_utf16 :: non_neg_integer()} | nil

  @spec resolve_composed_boundary(t(), non_neg_integer(), affinity(), inverse_cache()) ::
          {non_neg_integer(), inverse_cache()}
  defp resolve_composed_boundary(%__MODULE__{} = map, composed_utf16, affinity, cache) do
    case source_span_interior(map.spans, composed_utf16) do
      nil ->
        {composed_utf16_to_source_byte(map, composed_utf16, affinity), nil}

      {:source, _start_byte, end_byte, _start_utf16, _end_utf16} = span ->
        {scan_start_byte, scan_start_utf16} = inverse_scan_start(span, cache, composed_utf16)

        {source_byte, snapped_local_utf16} =
          utf16_to_byte_with_offset(
            map.source_text,
            scan_start_byte,
            end_byte,
            composed_utf16 - scan_start_utf16,
            affinity
          )

        snapped_utf16 = scan_start_utf16 + snapped_local_utf16
        {source_byte, {span, source_byte, snapped_utf16}}
    end
  end

  @spec source_span_interior([span()], non_neg_integer()) :: span() | nil
  defp source_span_interior(spans, composed_utf16) do
    Enum.find(spans, fn
      {:source, _start_byte, _end_byte, start_utf16, end_utf16} ->
        composed_utf16 > start_utf16 and composed_utf16 < end_utf16

      _other ->
        false
    end)
  end

  @spec inverse_scan_start(span(), inverse_cache(), non_neg_integer()) ::
          {source_byte :: non_neg_integer(), composed_utf16 :: non_neg_integer()}
  defp inverse_scan_start(span, {span, source_byte, cached_utf16}, composed_utf16)
       when cached_utf16 <= composed_utf16,
       do: {source_byte, cached_utf16}

  defp inverse_scan_start(
         {:source, start_byte, _end_byte, start_utf16, _end_utf16},
         _cache,
         _composed_utf16
       ),
       do: {start_byte, start_utf16}

  @spec source_boundary(t(), non_neg_integer()) :: non_neg_integer()
  defp source_boundary(%__MODULE__{} = map, source_byte) do
    Enum.find_value(map.spans, map.composed_end_utf16, fn
      {:source, start_byte, end_byte, start_utf16, _end_utf16}
      when source_byte >= start_byte and source_byte <= end_byte ->
        start_utf16 + utf16_offset_between(map.source_text, start_byte, source_byte)

      {:replacement, start_byte, _end_byte, start_utf16, _end_utf16}
      when source_byte == start_byte ->
        start_utf16

      {:replacement, start_byte, end_byte, _start_utf16, end_utf16}
      when source_byte > start_byte and source_byte <= end_byte ->
        end_utf16

      _other ->
        nil
    end)
  end

  @spec insertion_boundary([span()], non_neg_integer(), affinity()) :: non_neg_integer()
  defp insertion_boundary([], base, _affinity), do: base

  defp insertion_boundary(insertions, base, :start) do
    Enum.reduce(insertions, base, fn {:insertion, _, _, _, end_utf16}, boundary ->
      max(boundary, end_utf16)
    end)
  end

  defp insertion_boundary(insertions, base, :end) do
    Enum.reduce(insertions, base, fn {:insertion, _, _, start_utf16, _}, boundary ->
      min(boundary, start_utf16)
    end)
  end

  @spec source_candidates(span(), String.t(), non_neg_integer(), affinity()) :: [
          non_neg_integer()
        ]
  defp source_candidates(
         {:source, start_byte, end_byte, start_utf16, end_utf16},
         source_text,
         composed_utf16,
         affinity
       )
       when composed_utf16 >= start_utf16 and composed_utf16 <= end_utf16 do
    local_utf16 = composed_utf16 - start_utf16
    [utf16_to_byte(source_text, start_byte, end_byte, local_utf16, affinity)]
  end

  defp source_candidates(
         {:insertion, anchor_byte, anchor_byte, start_utf16, end_utf16},
         _source_text,
         composed_utf16,
         _affinity
       )
       when composed_utf16 >= start_utf16 and composed_utf16 <= end_utf16,
       do: [anchor_byte]

  defp source_candidates(
         {:replacement, start_byte, end_byte, start_utf16, end_utf16},
         _source_text,
         composed_utf16,
         affinity
       )
       when composed_utf16 >= start_utf16 and composed_utf16 <= end_utf16 do
    replacement_source_candidate(
      start_byte,
      end_byte,
      start_utf16,
      end_utf16,
      composed_utf16,
      affinity
    )
  end

  defp source_candidates(_span, _source_text, _composed_utf16, _affinity), do: []

  @spec replacement_source_candidate(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          affinity()
        ) :: [non_neg_integer()]
  defp replacement_source_candidate(
         start_byte,
         _end_byte,
         start_utf16,
         _end_utf16,
         start_utf16,
         _
       ),
       do: [start_byte]

  defp replacement_source_candidate(_start_byte, end_byte, _start_utf16, end_utf16, end_utf16, _),
    do: [end_byte]

  defp replacement_source_candidate(start_byte, _end_byte, _start, _end, _offset, :start),
    do: [start_byte]

  defp replacement_source_candidate(_start_byte, end_byte, _start, _end, _offset, :end),
    do: [end_byte]

  @spec choose_source_candidate([non_neg_integer()], t(), non_neg_integer(), affinity()) ::
          non_neg_integer()
  defp choose_source_candidate([], %__MODULE__{} = map, composed_utf16, _affinity) do
    if composed_utf16 >= map.composed_end_utf16, do: byte_size(map.source_text), else: 0
  end

  defp choose_source_candidate(candidates, _map, _composed_utf16, :start),
    do: Enum.min(candidates)

  defp choose_source_candidate(candidates, _map, _composed_utf16, :end), do: Enum.max(candidates)

  @spec conceal_pieces(String.t(), Decorations.t(), non_neg_integer()) :: [piece()]
  defp conceal_pieces(source_text, decorations, line) do
    line_width = Unicode.display_width(source_text)

    {pieces, source_byte} =
      decorations
      |> Decorations.conceals_for_line(line)
      |> Enum.reduce({[], 0}, fn conceal, {pieces, source_byte} ->
        {start_byte, end_byte} = conceal_bytes(conceal, source_text, line, line_width)
        start_byte = max(start_byte, source_byte)
        pieces = append_source_piece(pieces, source_text, source_byte, start_byte)
        pieces = append_replacement_piece(pieces, conceal.replacement, start_byte, end_byte)
        {pieces, max(source_byte, end_byte)}
      end)

    pieces =
      pieces
      |> append_source_piece(source_text, source_byte, byte_size(source_text))
      |> Enum.reverse()

    case pieces do
      [] -> [{"", :source, 0, 0}]
      _other -> pieces
    end
  end

  @spec conceal_bytes(ConcealRange.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp conceal_bytes(%ConcealRange{} = conceal, source_text, line, line_width) do
    {start_line, start_col} = conceal.start_pos
    {end_line, end_col} = conceal.end_pos
    effective_start = if start_line < line, do: 0, else: min(start_col, line_width)
    effective_end = if end_line > line, do: line_width, else: min(end_col, line_width)

    {
      Unicode.display_col_to_byte(source_text, effective_start),
      Unicode.display_col_to_byte(source_text, max(effective_end, effective_start))
    }
  end

  @spec append_source_piece([piece()], String.t(), non_neg_integer(), non_neg_integer()) :: [
          piece()
        ]
  defp append_source_piece(pieces, _source_text, start_byte, end_byte)
       when start_byte >= end_byte,
       do: pieces

  defp append_source_piece(pieces, source_text, start_byte, end_byte) do
    text = binary_part(source_text, start_byte, end_byte - start_byte)
    [{text, :source, start_byte, end_byte} | pieces]
  end

  @spec append_replacement_piece(
          [piece()],
          String.t() | nil,
          non_neg_integer(),
          non_neg_integer()
        ) ::
          [piece()]
  defp append_replacement_piece(pieces, nil, start_byte, end_byte),
    do: [{"", :replacement, start_byte, end_byte} | pieces]

  defp append_replacement_piece(pieces, replacement, start_byte, end_byte),
    do: [{replacement, :replacement, start_byte, end_byte} | pieces]

  @spec insert_virtual_text([piece()], Decorations.t(), String.t(), non_neg_integer()) :: [
          piece()
        ]
  defp insert_virtual_text(pieces, decorations, source_text, line) do
    line_width = Unicode.display_width(source_text)

    decorations
    |> Decorations.inline_virtual_texts_for_line(line)
    |> Enum.reduce(pieces, fn %VirtualText{anchor: {_line, col}, segments: segments}, pieces ->
      anchor_col = min(col, line_width)
      anchor_byte = Unicode.display_col_to_byte(source_text, anchor_col)
      text = Enum.map_join(segments, fn {segment_text, _face} -> segment_text end)

      insert_piece_at_display_col(
        pieces,
        anchor_col,
        {text, :insertion, anchor_byte, anchor_byte}
      )
    end)
  end

  @spec insert_piece_at_display_col([piece()], non_neg_integer(), piece()) :: [piece()]
  defp insert_piece_at_display_col(pieces, display_col, insertion) do
    do_insert_piece(pieces, display_col, insertion, 0, [])
  end

  @spec do_insert_piece([piece()], non_neg_integer(), piece(), non_neg_integer(), [piece()]) ::
          [piece()]
  defp do_insert_piece([], _display_col, insertion, _col, acc),
    do: Enum.reverse(acc, [insertion])

  defp do_insert_piece(
         [{"", _kind, _start, _end} = piece | rest],
         display_col,
         insertion,
         col,
         acc
       ),
       do: do_insert_piece(rest, display_col, insertion, col, [piece | acc])

  defp do_insert_piece(
         [{_text, :insertion, _start, _end} = piece | rest],
         display_col,
         insertion,
         col,
         acc
       ),
       do: do_insert_piece(rest, display_col, insertion, col, [piece | acc])

  defp do_insert_piece([piece | rest] = remaining, display_col, insertion, col, acc) do
    width = piece |> elem(0) |> Unicode.display_width()
    piece_end = col + width

    insert_piece_by_position(
      display_col,
      insertion,
      col,
      piece_end,
      piece,
      rest,
      remaining,
      acc
    )
  end

  @spec insert_piece_by_position(
          non_neg_integer(),
          piece(),
          non_neg_integer(),
          non_neg_integer(),
          piece(),
          [piece()],
          [piece()],
          [piece()]
        ) :: [piece()]
  defp insert_piece_by_position(
         display_col,
         insertion,
         col,
         _piece_end,
         _piece,
         _rest,
         remaining,
         acc
       )
       when display_col <= col,
       do: Enum.reverse(acc, [insertion | remaining])

  defp insert_piece_by_position(
         display_col,
         insertion,
         col,
         piece_end,
         piece,
         rest,
         _remaining,
         acc
       )
       when display_col < piece_end do
    {before_piece, after_piece} = split_piece(piece, display_col - col)
    tail = [before_piece, insertion, after_piece | rest] |> Enum.reject(&empty_source_piece?/1)
    Enum.reverse(acc, tail)
  end

  defp insert_piece_by_position(
         display_col,
         insertion,
         _col,
         piece_end,
         piece,
         rest,
         _remaining,
         acc
       ) do
    do_insert_piece(rest, display_col, insertion, piece_end, [piece | acc])
  end

  @spec split_piece(piece(), non_neg_integer()) :: {piece(), piece()}
  defp split_piece({text, kind, start_byte, end_byte}, display_col) do
    {before, after_text} = split_text_at_display_col(text, display_col)

    case kind do
      :source ->
        middle_byte = start_byte + byte_size(before)
        {{before, kind, start_byte, middle_byte}, {after_text, kind, middle_byte, end_byte}}

      _other ->
        {{before, kind, start_byte, end_byte}, {after_text, kind, start_byte, end_byte}}
    end
  end

  @spec empty_source_piece?(piece()) :: boolean()
  defp empty_source_piece?({"", :source, start_byte, end_byte}), do: start_byte != end_byte
  defp empty_source_piece?(_piece), do: false

  @spec split_text_at_display_col(String.t(), non_neg_integer()) :: {String.t(), String.t()}
  defp split_text_at_display_col(text, display_col) do
    {before, after_text, _col} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], [], 0}, fn grapheme, {before, after_text, col} ->
        width = Unicode.grapheme_width(grapheme)

        if col < display_col do
          {[grapheme | before], after_text, col + width}
        else
          {before, [grapheme | after_text], col + width}
        end
      end)

    {before |> Enum.reverse() |> Enum.join(), after_text |> Enum.reverse() |> Enum.join()}
  end

  @spec maybe_expand_tabs([piece()], pos_integer() | nil) :: [piece()]
  defp maybe_expand_tabs(pieces, nil), do: pieces

  defp maybe_expand_tabs(pieces, tab_width) do
    {expanded, _col} =
      Enum.reduce(pieces, {[], 0}, fn piece, {acc, col} ->
        {expanded_piece, next_col} = expand_piece_tabs(piece, col, tab_width)
        {Enum.reverse(expanded_piece, acc), next_col}
      end)

    Enum.reverse(expanded)
  end

  @spec expand_piece_tabs(piece(), non_neg_integer(), pos_integer()) ::
          {[piece()], non_neg_integer()}
  defp expand_piece_tabs({text, :source, start_byte, _end_byte} = piece, col, tab_width) do
    if String.contains?(text, "\t") do
      expand_source_tabs(text, start_byte, col, tab_width, [], [], start_byte)
    else
      {[piece], col + Unicode.display_width(text)}
    end
  end

  defp expand_piece_tabs({text, kind, start_byte, end_byte}, col, tab_width) do
    {expanded_text, next_col} = expand_text_tabs(text, col, tab_width)
    {[{expanded_text, kind, start_byte, end_byte}], next_col}
  end

  @spec expand_source_tabs(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          [piece()],
          [String.t()],
          non_neg_integer()
        ) :: {[piece()], non_neg_integer()}
  defp expand_source_tabs("", source_byte, col, _tab_width, pieces, run, run_start) do
    pieces = flush_source_run(pieces, run, run_start, source_byte)
    {Enum.reverse(pieces), col}
  end

  defp expand_source_tabs(text, source_byte, col, tab_width, pieces, run, run_start) do
    {grapheme, rest} = String.next_grapheme(text)
    next_source_byte = source_byte + byte_size(grapheme)

    case grapheme do
      "\t" ->
        pieces = flush_source_run(pieces, run, run_start, source_byte)
        fill = tab_fill(col, tab_width)
        tab_piece = {String.duplicate(" ", fill), :replacement, source_byte, next_source_byte}

        expand_source_tabs(
          rest,
          next_source_byte,
          col + fill,
          tab_width,
          [tab_piece | pieces],
          [],
          next_source_byte
        )

      _other ->
        expand_source_tabs(
          rest,
          next_source_byte,
          col + Unicode.grapheme_width(grapheme),
          tab_width,
          pieces,
          [grapheme | run],
          run_start
        )
    end
  end

  @spec flush_source_run([piece()], [String.t()], non_neg_integer(), non_neg_integer()) :: [
          piece()
        ]
  defp flush_source_run(pieces, [], _start_byte, _end_byte), do: pieces

  defp flush_source_run(pieces, run, start_byte, end_byte),
    do: [{run |> Enum.reverse() |> Enum.join(), :source, start_byte, end_byte} | pieces]

  @spec expand_text_tabs(String.t(), non_neg_integer(), pos_integer()) ::
          {String.t(), non_neg_integer()}
  defp expand_text_tabs(text, col, tab_width) do
    {parts, next_col} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], col}, fn
        "\t", {parts, current_col} ->
          fill = tab_fill(current_col, tab_width)
          {[String.duplicate(" ", fill) | parts], current_col + fill}

        grapheme, {parts, current_col} ->
          {[grapheme | parts], current_col + Unicode.grapheme_width(grapheme)}
      end)

    {parts |> Enum.reverse() |> Enum.join(), next_col}
  end

  @spec tab_fill(non_neg_integer(), pos_integer()) :: pos_integer()
  defp tab_fill(col, tab_width), do: tab_width - rem(col, tab_width)

  @spec coalesce_pieces([piece()]) :: [piece()]
  defp coalesce_pieces(pieces) do
    pieces
    |> Enum.reduce([], &coalesce_piece/2)
    |> Enum.reverse()
  end

  @spec coalesce_piece(piece(), [piece()]) :: [piece()]
  defp coalesce_piece({text, kind, start_byte, end_byte}, [
         {previous_text, kind, previous_start, previous_end} | rest
       ])
       when (kind == :source and previous_end == start_byte) or
              (kind != :source and previous_start == start_byte and previous_end == end_byte) do
    [{previous_text <> text, kind, previous_start, end_byte} | rest]
  end

  defp coalesce_piece(piece, pieces), do: [piece | pieces]

  @spec reversed_spans_from_pieces([piece()]) :: {[span()], non_neg_integer()}
  defp reversed_spans_from_pieces(pieces) do
    {spans, composed_utf16} =
      Enum.reduce(pieces, {[], 0}, fn {text, kind, start_byte, end_byte}, {spans, offset} ->
        next_offset = offset + utf16_length(text)
        {[{kind, start_byte, end_byte, offset, next_offset} | spans], next_offset}
      end)

    {spans, composed_utf16}
  end

  @spec prepend_unmapped_suffix(
          [span()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [span()]
  defp prepend_unmapped_suffix(spans, source_end, built_utf16, composed_utf16)
       when composed_utf16 > built_utf16 do
    [{:insertion, source_end, source_end, built_utf16, composed_utf16} | spans]
  end

  defp prepend_unmapped_suffix(spans, _source_end, _built_utf16, _composed_utf16), do: spans

  @spec insertion_summaries([span()]) :: [insertion()]
  defp insertion_summaries(spans) do
    Enum.flat_map(spans, fn
      {:insertion, anchor, anchor, start_utf16, end_utf16} -> [{anchor, end_utf16 - start_utf16}]
      _other -> []
    end)
  end

  @spec replacement_summaries([span()]) :: [replacement()]
  defp replacement_summaries(spans) do
    Enum.flat_map(spans, fn
      {:replacement, start_byte, end_byte, start_utf16, end_utf16} ->
        [{start_byte, end_byte, end_utf16 - start_utf16}]

      _other ->
        []
    end)
  end

  @spec utf16_to_byte(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          affinity()
        ) :: non_neg_integer()
  defp utf16_to_byte(text, start_byte, end_byte, target_utf16, affinity) do
    {source_byte, _snapped_utf16} =
      utf16_to_byte_with_offset(text, start_byte, end_byte, target_utf16, affinity)

    source_byte
  end

  @spec utf16_to_byte_with_offset(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          affinity()
        ) :: {non_neg_integer(), non_neg_integer()}
  defp utf16_to_byte_with_offset(text, start_byte, end_byte, target_utf16, affinity) do
    source = binary_part(text, start_byte, end_byte - start_byte)
    do_utf16_to_byte(source, start_byte, target_utf16, affinity, 0)
  end

  @spec do_utf16_to_byte(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          affinity(),
          non_neg_integer()
        ) ::
          {non_neg_integer(), non_neg_integer()}
  defp do_utf16_to_byte("", source_byte, _target_utf16, _affinity, utf16),
    do: {source_byte, utf16}

  defp do_utf16_to_byte(text, source_byte, target_utf16, affinity, utf16) do
    {grapheme, rest} = String.next_grapheme(text)
    units = utf16_length(grapheme)
    next_utf16 = utf16 + units
    next_source_byte = source_byte + byte_size(grapheme)

    case {target_utf16 == utf16, target_utf16 < next_utf16, affinity} do
      {true, _inside, _affinity} ->
        {source_byte, utf16}

      {false, true, :start} ->
        {source_byte, utf16}

      {false, true, :end} ->
        {next_source_byte, next_utf16}

      {false, false, _affinity} ->
        do_utf16_to_byte(rest, next_source_byte, target_utf16, affinity, next_utf16)
    end
  end

  @spec utf16_offset_between(String.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp utf16_offset_between(_text, start_byte, end_byte) when start_byte >= end_byte, do: 0

  defp utf16_offset_between(text, start_byte, end_byte) do
    text
    |> binary_part(start_byte, end_byte - start_byte)
    |> utf16_length()
  end

  @spec utf16_length(String.t()) :: non_neg_integer()
  defp utf16_length(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce(0, fn codepoint, units -> units + if(codepoint > 0xFFFF, do: 2, else: 1) end)
  end
end
