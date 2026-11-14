defmodule MingaEditor.Agent.View.PromptProjection do
  @moduledoc """
  One source-backed, byte-correct projection for prompt wrapping, geometry and input.

  Row topology depends on source content and physical capacity, never the cursor.
  A full final row reserves an EOF insertion continuation even away from EOF.
  Explicit newlines already provide subsequent source rows; interior line ends retain the ordinary wrapped-editor right-edge position without extra blank rows.
  """

  alias Minga.Buffer
  alias Minga.Core.Decorations
  alias Minga.Core.Unicode
  alias Minga.Core.WidthOracle
  alias Minga.Core.WidthOracle.Monospace
  alias Minga.Core.WrapMap
  alias MingaEditor.Agent.PromptViewport
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.RenderModel.Window.SourceOffsetMap

  @type position :: PromptViewport.position()
  @type visual_row :: %{
          text: String.t(),
          logical_line: non_neg_integer(),
          visual_index: non_neg_integer(),
          offset_map: SourceOffsetMap.t(),
          start_col: non_neg_integer(),
          end_col: non_neg_integer(),
          pill?: boolean()
        }
  @enforce_keys [
    :buffer,
    :version,
    :lines,
    :cursor,
    :columns,
    :visible_rows,
    :rows,
    :scroll,
    :oracle
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          buffer: pid(),
          version: non_neg_integer(),
          lines: [String.t()],
          cursor: position(),
          columns: pos_integer(),
          visible_rows: pos_integer(),
          rows: [visual_row()],
          scroll: non_neg_integer(),
          oracle: WidthOracle.t()
        }

  @spec build(Panel.t(), pos_integer(), keyword()) :: t()
  def build(%Panel{} = panel, fallback_columns, opts \\ []) do
    # The range is clamped by Buffer's line store, not allocated at this size.
    snapshot = Buffer.render_snapshot(panel.prompt_buffer, 0, 0xFFFFFFFF)
    {columns, capacity} = PromptViewport.capacity(panel.prompt_viewport, fallback_columns)
    oracle = Keyword.get(opts, :oracle, %Monospace{})

    rows =
      snapshot.lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {source, line} ->
        {text, offset_map, pill?} = compose_line(source, line, panel)
        [wrapped] = WrapMap.compute([text], columns, breakindent: false, oracle: oracle)

        wrapped =
          if line == snapshot.line_count - 1,
            do: insertion_row(wrapped, text, columns, oracle),
            else: wrapped

        {segments, _end_position} =
          wrapped
          |> Enum.with_index()
          |> Enum.map_reduce({0, 0}, fn {row, visual_index}, {utf16, column} ->
            end_utf16 = utf16 + utf16_length(row.source_text)
            end_col = column + WidthOracle.display_width(oracle, row.source_text)
            segment = {row.source_text, visual_index, utf16, end_utf16, column, end_col}
            {segment, {end_utf16, end_col}}
          end)

        boundaries =
          Enum.flat_map(segments, fn {_text, _index, start, stop, _col, _end_col} ->
            [{start, :start}, {stop, :end}]
          end)

        source_bytes =
          offset_map
          |> SourceOffsetMap.composed_utf16_to_source_bytes(boundaries)
          |> Enum.chunk_every(2)

        Enum.zip_with(segments, source_bytes, fn {row_text, visual_index, start, stop, column,
                                                  end_col},
                                                 [source_start, source_end] ->
          %{
            text: row_text,
            logical_line: line,
            visual_index: visual_index,
            offset_map: SourceOffsetMap.slice(offset_map, source_start, source_end, start, stop),
            start_col: column,
            end_col: end_col,
            pill?: pill?
          }
        end)
      end)

    visible = max(1, min(length(rows), min(capacity, 8)))

    projection = %__MODULE__{
      buffer: panel.prompt_buffer,
      version: snapshot.version,
      lines: snapshot.lines,
      cursor: snapshot.cursor,
      columns: columns,
      visible_rows: visible,
      rows: rows,
      scroll: 0,
      oracle: oracle
    }

    {cursor_row, _column} = position(projection, snapshot.cursor)
    marker = {snapshot.version, snapshot.cursor}

    scroll =
      scroll_top(
        projection,
        PromptViewport.reading_anchor(panel.prompt_viewport, marker),
        cursor_row
      )

    %{projection | scroll: scroll}
  end

  @spec visible(t()) :: [visual_row()]
  def visible(%__MODULE__{} = projection),
    do: Enum.slice(projection.rows, projection.scroll, projection.visible_rows)

  @spec anchor(t(), non_neg_integer()) :: PromptViewport.anchor()
  def anchor(%__MODULE__{} = projection, index) do
    row = Enum.at(projection.rows, index)
    {row.logical_line, row.visual_index}
  end

  @spec position(t(), position()) :: {non_neg_integer(), non_neg_integer()}
  def position(%__MODULE__{} = projection, {line, byte}) do
    candidates =
      projection.rows
      |> Enum.with_index()
      |> Enum.filter(fn {row, _index} -> row.logical_line == line end)

    {first, _index} = hd(candidates)
    composed = SourceOffsetMap.source_to_composed_utf16(first.offset_map, byte, :start)

    {row, index} =
      candidates
      |> Enum.filter(fn {row, _index} -> row.offset_map.composed_start_utf16 <= composed end)
      |> List.last()
      |> position_candidate(candidates)

    local = max(composed - row.offset_map.composed_start_utf16, 0)
    prefix = utf16_prefix(row.text, local)
    {index, WidthOracle.display_width(projection.oracle, prefix)}
  end

  @spec position_candidate({visual_row(), non_neg_integer()} | nil, [
          {visual_row(), non_neg_integer()}
        ]) ::
          {visual_row(), non_neg_integer()}
  defp position_candidate(nil, [first | _]), do: first
  defp position_candidate(candidate, _candidates), do: candidate

  @spec scroll_top(t(), PromptViewport.anchor() | nil, non_neg_integer()) :: non_neg_integer()
  defp scroll_top(projection, nil, cursor_row),
    do:
      min(
        max(cursor_row - projection.visible_rows + 1, 0),
        max(length(projection.rows) - projection.visible_rows, 0)
      )

  defp scroll_top(projection, {line, continuation}, _cursor_row) do
    {_row, index} =
      projection.rows
      |> Enum.with_index()
      |> Enum.filter(fn {row, _index} ->
        row.logical_line < line or (row.logical_line == line and row.visual_index <= continuation)
      end)
      |> List.last()

    min(index, max(length(projection.rows) - projection.visible_rows, 0))
  end

  @spec compose_line(String.t(), non_neg_integer(), Panel.t()) ::
          {String.t(), SourceOffsetMap.t(), boolean()}
  defp compose_line(source, line, panel) do
    case UIState.paste_block_index(source) do
      nil ->
        text = expand_tabs(source)
        {text, SourceOffsetMap.new(source, text, Decorations.new(), line, tab_width: 2), false}

      index ->
        count = UIState.paste_block_line_count(panel.pasted_blocks, index)
        text = "󰆏 [pasted #{count} lines]"

        {_id, decorations} =
          Decorations.add_conceal(
            Decorations.new(),
            {line, 0},
            {line, Unicode.display_width(source)},
            replacement: text
          )

        {text, SourceOffsetMap.new(source, text, decorations, line), true}
    end
  end

  @spec insertion_row(
          WrapMap.wrap_entry(),
          String.t(),
          pos_integer(),
          WidthOracle.t()
        ) :: WrapMap.wrap_entry()
  defp insertion_row(rows, text, columns, oracle) do
    last = List.last(rows)

    if byte_size(text) > 0 and WidthOracle.display_width(oracle, last.text) >= columns do
      rows ++ [%{text: "", source_text: "", byte_offset: byte_size(text), indent_width: 0}]
    else
      rows
    end
  end

  @spec expand_tabs(String.t()) :: String.t()
  defp expand_tabs(text) do
    {pieces, _col} =
      Enum.map_reduce(String.graphemes(text), 0, fn
        "\t", col ->
          width = 2 - rem(col, 2)
          {String.duplicate(" ", width), col + width}

        grapheme, col ->
          {grapheme, col + Unicode.grapheme_width(grapheme)}
      end)

    Enum.join(pieces)
  end

  @spec utf16_length(String.t()) :: non_neg_integer()
  defp utf16_length(text),
    do: div(byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :little})), 2)

  @spec utf16_prefix(String.t(), non_neg_integer()) :: String.t()
  defp utf16_prefix(text, offset) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, length} ->
      next = length + utf16_length(grapheme)
      if next <= offset, do: {:cont, {[grapheme | acc], next}}, else: {:halt, {acc, length}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end
end
