defmodule Minga.Editing.Motion.VisualLine do
  @moduledoc """
  Visual-line motions for soft word-wrapping.

  When word-wrap is enabled, a single logical line may span multiple
  screen rows. These functions move the cursor by visual rows rather
  than logical lines, keeping the cursor at the same visual column
  (or as close as possible) across wrapped rows.

  These replace `j`/`k` when wrap is on. The original `j`/`k` behavior
  (logical line movement) is available via `gj`/`gk`.
  """

  alias Minga.Buffer.Document
  alias Minga.Core.Unicode
  alias Minga.Core.WidthOracle
  alias Minga.Core.WidthOracle.Monospace
  alias Minga.Core.WrapMap

  @type position :: Document.position()
  @type wrap_opts :: keyword()

  @doc """
  Move down by one visual row within a wrapped buffer.

  If the cursor is on a visual row that has more rows below it (within
  the same logical line), moves to the next visual row. Otherwise moves
  to the first visual row of the next logical line.
  """
  @spec visual_down(Document.t(), position(), pos_integer()) :: position()
  def visual_down(doc, pos, content_width), do: visual_down(doc, pos, content_width, [])

  @spec visual_down(Document.t(), position(), pos_integer(), wrap_opts()) :: position()
  def visual_down(doc, {line, col}, content_width, opts) do
    line_text = Document.line_at(doc, line)
    wrap_entry = wrap_entry(line_text, content_width, opts)
    {vrow_idx, computed_vrow_col} = source_byte_to_visual(wrap_entry, col, opts)
    vrow_col = Keyword.get(opts, :desired_col, computed_vrow_col)

    if vrow_idx < Enum.count(wrap_entry) - 1 do
      next_vrow = Enum.at(wrap_entry, vrow_idx + 1)
      target_col = min(vrow_col, max(visual_display_width(next_vrow, opts) - 1, 0))
      byte_col = byte_col_in_vrow(next_vrow, target_col, opts)
      {line, next_vrow.byte_offset + byte_col}
    else
      next_line = line + 1
      max_line = Document.line_count(doc) - 1

      if next_line > max_line do
        {line, col}
      else
        next_text = Document.line_at(doc, next_line)
        next_entry = wrap_entry(next_text, content_width, opts)
        first_vrow = hd(next_entry)
        target_col = min(vrow_col, max(visual_display_width(first_vrow, opts) - 1, 0))
        byte_col = byte_col_in_vrow(first_vrow, target_col, opts)
        {next_line, byte_col}
      end
    end
  end

  @doc """
  Move up by one visual row within a wrapped buffer.

  If the cursor is on a visual row that has rows above it (within the
  same logical line), moves to the previous visual row. Otherwise moves
  to the last visual row of the previous logical line.
  """
  @spec visual_up(Document.t(), position(), pos_integer()) :: position()
  def visual_up(doc, pos, content_width), do: visual_up(doc, pos, content_width, [])

  @spec visual_up(Document.t(), position(), pos_integer(), wrap_opts()) :: position()
  def visual_up(doc, {line, col}, content_width, opts) do
    line_text = Document.line_at(doc, line)
    wrap_entry = wrap_entry(line_text, content_width, opts)
    {vrow_idx, computed_vrow_col} = source_byte_to_visual(wrap_entry, col, opts)
    vrow_col = Keyword.get(opts, :desired_col, computed_vrow_col)

    if vrow_idx > 0 do
      prev_vrow = Enum.at(wrap_entry, vrow_idx - 1)
      target_col = min(vrow_col, max(visual_display_width(prev_vrow, opts) - 1, 0))
      byte_col = byte_col_in_vrow(prev_vrow, target_col, opts)
      {line, prev_vrow.byte_offset + byte_col}
    else
      if line == 0 do
        {0, col}
      else
        prev_line = line - 1
        prev_text = Document.line_at(doc, prev_line)
        prev_entry = wrap_entry(prev_text, content_width, opts)
        last_vrow = Enum.at(prev_entry, -1)
        target_col = min(vrow_col, max(visual_display_width(last_vrow, opts) - 1, 0))
        byte_col = byte_col_in_vrow(last_vrow, target_col, opts)
        {prev_line, last_vrow.byte_offset + byte_col}
      end
    end
  end

  @doc """
  Move to the start of the current visual row.

  When the cursor is on a continuation row of a wrapped line, moves to
  the first column of that visual row (not the logical line start).
  """
  @spec visual_line_start(Document.t(), position(), pos_integer()) :: position()
  def visual_line_start(doc, pos, content_width),
    do: visual_line_start(doc, pos, content_width, [])

  @spec visual_line_start(Document.t(), position(), pos_integer(), wrap_opts()) :: position()
  def visual_line_start(doc, {line, col}, content_width, opts) do
    line_text = Document.line_at(doc, line)
    wrap_entry = wrap_entry(line_text, content_width, opts)
    {vrow_idx, _vrow_col} = source_byte_to_visual(wrap_entry, col, opts)
    vrow = Enum.at(wrap_entry, vrow_idx)
    {line, vrow.byte_offset}
  end

  @doc """
  Move to the end of the current visual row.

  When the cursor is on a visual row within a wrapped line, moves to
  the last column of that visual row.
  """
  @spec visual_line_end(Document.t(), position(), pos_integer()) :: position()
  def visual_line_end(doc, pos, content_width), do: visual_line_end(doc, pos, content_width, [])

  @spec visual_line_end(Document.t(), position(), pos_integer(), wrap_opts()) :: position()
  def visual_line_end(doc, {line, col}, content_width, opts) do
    line_text = Document.line_at(doc, line)
    wrap_entry = wrap_entry(line_text, content_width, opts)
    {vrow_idx, _vrow_col} = source_byte_to_visual(wrap_entry, col, opts)
    vrow = Enum.at(wrap_entry, vrow_idx)
    trimmed = vrow |> source_text() |> String.trim_trailing()
    end_byte = max(byte_size(trimmed) - 1, 0)
    {line, vrow.byte_offset + end_byte}
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec wrap_entry(String.t(), pos_integer(), wrap_opts()) :: WrapMap.wrap_entry()
  defp wrap_entry(text, content_width, opts) do
    WrapMap.compute([text], content_width, opts) |> hd()
  end

  @doc "Maps a full-line display column to `{visual_row_index, column_within_that_visual_row}`."
  @spec display_col_to_visual(WrapMap.wrap_entry(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def display_col_to_visual(wrap_entry, display_col) do
    wrap_entry
    |> Enum.with_index()
    |> Enum.reduce_while({0, display_col}, fn {vrow, idx}, {_found_idx, remaining_col} ->
      vrow_width = source_display_width(vrow)

      if remaining_col < vrow_width or idx == Enum.count(wrap_entry) - 1 do
        {:halt, {idx, remaining_col + indent_width(vrow)}}
      else
        {:cont, {idx + 1, remaining_col - vrow_width}}
      end
    end)
  end

  @doc "Maps a source byte boundary to its visual row and display column."
  @spec source_byte_to_visual(WrapMap.wrap_entry(), non_neg_integer(), wrap_opts()) ::
          {non_neg_integer(), non_neg_integer()}
  def source_byte_to_visual(wrap_entry, source_byte, opts \\ []) do
    {vrow, idx} =
      wrap_entry
      |> Enum.with_index()
      |> Enum.filter(fn {row, _idx} -> row.byte_offset <= source_byte end)
      |> Enum.at(-1, {hd(wrap_entry), 0})

    source_byte_in_row = max(source_byte - vrow.byte_offset, 0)
    row_start_col = indent_width(vrow)
    visual_col = display_col_at_byte(source_text(vrow), source_byte_in_row, row_start_col, opts)
    {idx, visual_col}
  end

  # Converts a display column within a visual row to a byte offset
  # within that visual row's text.
  @spec byte_col_in_vrow(WrapMap.visual_row(), non_neg_integer(), wrap_opts()) ::
          non_neg_integer()
  defp byte_col_in_vrow(vrow, target_display_col, opts) do
    do_display_col_to_byte(
      source_text(vrow),
      target_display_col,
      indent_width(vrow),
      0,
      opts
    )
  end

  @spec visual_display_width(WrapMap.visual_row(), wrap_opts()) :: non_neg_integer()
  defp visual_display_width(vrow, opts) do
    display_col_at_byte(
      source_text(vrow),
      byte_size(source_text(vrow)),
      indent_width(vrow),
      opts
    )
  end

  @spec display_col_at_byte(String.t(), non_neg_integer(), non_neg_integer(), wrap_opts()) ::
          non_neg_integer()
  defp display_col_at_byte(text, source_byte, start_col, opts) do
    do_display_col_at_byte(text, source_byte, 0, start_col, opts)
  end

  @spec do_display_col_at_byte(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          wrap_opts()
        ) :: non_neg_integer()
  defp do_display_col_at_byte(_text, target_byte, current_byte, col, _opts)
       when current_byte >= target_byte,
       do: col

  defp do_display_col_at_byte(text, target_byte, current_byte, col, opts) do
    case String.next_grapheme(text) do
      {grapheme, rest} ->
        do_display_col_at_byte(
          rest,
          target_byte,
          current_byte + byte_size(grapheme),
          col + grapheme_advance(grapheme, col, opts),
          opts
        )

      nil ->
        col
    end
  end

  @spec do_display_col_to_byte(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          wrap_opts()
        ) :: non_neg_integer()
  defp do_display_col_to_byte("", _target_col, _col, bytes, _opts), do: bytes

  defp do_display_col_to_byte(text, target_col, col, bytes, opts) do
    case String.next_grapheme(text) do
      {grapheme, rest} ->
        next_col = col + grapheme_advance(grapheme, col, opts)

        if next_col > target_col do
          bytes
        else
          do_display_col_to_byte(rest, target_col, next_col, bytes + byte_size(grapheme), opts)
        end

      nil ->
        bytes
    end
  end

  @spec grapheme_advance(String.t(), non_neg_integer(), wrap_opts()) :: non_neg_integer()
  defp grapheme_advance("\t", col, opts) do
    tab_width = Keyword.get(opts, :tab_width, 2)
    tab_width - rem(col, tab_width)
  end

  defp grapheme_advance(grapheme, _col, opts) do
    oracle = Keyword.get(opts, :oracle, %Monospace{})
    WidthOracle.grapheme_width(oracle, grapheme)
  end

  @spec source_display_width(WrapMap.visual_row()) :: non_neg_integer()
  defp source_display_width(vrow) do
    vrow |> source_text() |> Unicode.display_width()
  end

  @spec source_text(WrapMap.visual_row()) :: String.t()
  defp source_text(vrow), do: Map.get(vrow, :source_text, vrow.text)

  @spec indent_width(WrapMap.visual_row()) :: non_neg_integer()
  defp indent_width(vrow), do: Map.get(vrow, :indent_width, 0)
end
