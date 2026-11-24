defmodule MingaEditor.Agent.View.PromptProjection do
  @moduledoc """
  One source-backed, byte-correct projection for prompt wrapping, geometry and input.

  Row topology depends on source content and physical capacity, never the cursor.
  A full final row reserves an EOF insertion continuation even away from EOF.
  Explicit newlines already provide subsequent source rows; interior line ends retain the ordinary wrapped-editor right-edge position without extra blank rows.
  """

  alias Minga.Buffer
  alias Minga.Core.Decorations
  alias Minga.Core.Plural
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
          Enum.map_reduce(wrapped, {0, 0, 0}, fn row, {visual_index, utf16, column} ->
            end_utf16 = utf16 + utf16_length(row.source_text)
            end_col = column + WidthOracle.display_width(oracle, row.source_text)
            segment = {row.source_text, visual_index, utf16, end_utf16, column, end_col}
            {segment, {visual_index + 1, end_utf16, end_col}}
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

    row_count = length(rows)
    visible = max(1, min(row_count, min(capacity, 8)))

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

    marker = {snapshot.version, snapshot.cursor}
    reading_anchor = PromptViewport.reading_anchor(panel.prompt_viewport, marker)
    scroll = min(scroll_top(projection, reading_anchor), max(row_count - visible, 0))

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
    {[%{offset_map: offset_map} | _] = line_rows, index} =
      rows_from_line(projection.rows, line, 0)

    composed = SourceOffsetMap.source_to_composed_utf16(offset_map, byte, :start)
    {row, index} = row_at_composed_utf16(line_rows, line, composed, index)

    local = max(composed - row.offset_map.composed_start_utf16, 0)
    prefix = utf16_prefix(row.text, local)
    {index, WidthOracle.display_width(projection.oracle, prefix)}
  end

  @spec rows_from_line([visual_row()], non_neg_integer(), non_neg_integer()) ::
          {nonempty_list(visual_row()), non_neg_integer()}
  defp rows_from_line([%{logical_line: line} | _] = rows, line, index), do: {rows, index}

  defp rows_from_line([%{logical_line: current} | rest], line, index) when current < line,
    do: rows_from_line(rest, line, index + 1)

  defp rows_from_line(_rows, line, _index),
    do: raise(ArgumentError, "prompt projection has no logical line #{line}")

  @spec row_at_composed_utf16(
          nonempty_list(visual_row()),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {visual_row(), non_neg_integer()}
  defp row_at_composed_utf16(
         [_ | [%{logical_line: line, offset_map: %{composed_start_utf16: start}} | _] = rest],
         line,
         composed,
         index
       )
       when start <= composed,
       do: row_at_composed_utf16(rest, line, composed, index + 1)

  defp row_at_composed_utf16([row | _], _line, _composed, index), do: {row, index}

  @spec scroll_top(t(), PromptViewport.anchor() | nil) :: non_neg_integer()
  defp scroll_top(projection, nil) do
    {cursor_row, _column} = position(projection, projection.cursor)
    max(cursor_row - projection.visible_rows + 1, 0)
  end

  defp scroll_top(projection, anchor) do
    # The anchored continuation may no longer exist after rewrapping.
    anchor_predecessor(projection.rows, anchor, 0)
  end

  @spec anchor_predecessor([visual_row()], PromptViewport.anchor(), non_neg_integer()) ::
          non_neg_integer()
  defp anchor_predecessor(
         [_ | [%{logical_line: line, visual_index: visual_index} | _] = rest],
         {anchor_line, anchor_continuation} = anchor,
         row_index
       )
       when line < anchor_line or (line == anchor_line and visual_index <= anchor_continuation),
       do: anchor_predecessor(rest, anchor, row_index + 1)

  defp anchor_predecessor(_rows, _anchor, row_index), do: row_index

  @spec compose_line(String.t(), non_neg_integer(), Panel.t()) ::
          {String.t(), SourceOffsetMap.t(), boolean()}
  defp compose_line(source, line, panel) do
    case UIState.paste_block_index(source) do
      nil ->
        text = expand_tabs(source)
        {text, SourceOffsetMap.new(source, text, Decorations.new(), line, tab_width: 2), false}

      index ->
        count = UIState.paste_block_line_count(panel.pasted_blocks, index)
        text = "󰆏 [pasted #{Plural.count(count, "line", "lines")}]"

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
