defmodule Minga.Motion.VisualLine do
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
  alias Minga.Buffer.Unicode
  alias Minga.Editor.WrapMap

  @type position :: Document.position()

  @doc """
  Move down by one visual row within a wrapped buffer.

  If the cursor is on a visual row that has more rows below it (within
  the same logical line), moves to the next visual row. Otherwise moves
  to the first visual row of the next logical line.
  """
  @spec visual_down(Document.t(), position(), pos_integer()) :: position()
  def visual_down(doc, {line, col}, content_width) do
    line_text = Document.line_at(doc, line)
    wrap_entry = WrapMap.compute([line_text], content_width) |> hd()
    display_col = Unicode.display_col(line_text, col)
    {vrow_idx, vrow_col} = display_col_to_visual(wrap_entry, display_col)

    if vrow_idx < length(wrap_entry) - 1 do
      # Move to the next visual row within the same logical line
      next_vrow = Enum.at(wrap_entry, vrow_idx + 1)
      target_col = min(vrow_col, max(String.length(next_vrow.text) - 1, 0))
      byte_col = byte_col_in_vrow(next_vrow, target_col)
      {line, next_vrow.byte_offset + byte_col}
    else
      # Move to the first visual row of the next logical line
      next_line = line + 1
      max_line = Document.line_count(doc) - 1

      if next_line > max_line do
        {line, col}
      else
        next_text = Document.line_at(doc, next_line)
        next_entry = WrapMap.compute([next_text], content_width) |> hd()
        first_vrow = hd(next_entry)
        target_col = min(vrow_col, max(String.length(first_vrow.text) - 1, 0))
        byte_col = byte_col_in_vrow(first_vrow, target_col)
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
  def visual_up(doc, {line, col}, content_width) do
    line_text = Document.line_at(doc, line)
    wrap_entry = WrapMap.compute([line_text], content_width) |> hd()
    display_col = Unicode.display_col(line_text, col)
    {vrow_idx, vrow_col} = display_col_to_visual(wrap_entry, display_col)

    if vrow_idx > 0 do
      # Move to the previous visual row within the same logical line
      prev_vrow = Enum.at(wrap_entry, vrow_idx - 1)
      target_col = min(vrow_col, max(String.length(prev_vrow.text) - 1, 0))
      byte_col = byte_col_in_vrow(prev_vrow, target_col)
      {line, prev_vrow.byte_offset + byte_col}
    else
      # Move to the last visual row of the previous logical line
      if line == 0 do
        {0, col}
      else
        prev_line = line - 1
        prev_text = Document.line_at(doc, prev_line)
        prev_entry = WrapMap.compute([prev_text], content_width) |> hd()
        last_vrow = List.last(prev_entry)
        target_col = min(vrow_col, max(String.length(last_vrow.text) - 1, 0))
        byte_col = byte_col_in_vrow(last_vrow, target_col)
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
  def visual_line_start(doc, {line, col}, content_width) do
    line_text = Document.line_at(doc, line)
    wrap_entry = WrapMap.compute([line_text], content_width) |> hd()
    display_col = Unicode.display_col(line_text, col)
    {_vrow_idx, _vrow_col, vrow} = find_visual_row(wrap_entry, display_col)
    {line, vrow.byte_offset}
  end

  @doc """
  Move to the end of the current visual row.

  When the cursor is on a visual row within a wrapped line, moves to
  the last column of that visual row.
  """
  @spec visual_line_end(Document.t(), position(), pos_integer()) :: position()
  def visual_line_end(doc, {line, col}, content_width) do
    line_text = Document.line_at(doc, line)
    wrap_entry = WrapMap.compute([line_text], content_width) |> hd()
    display_col = Unicode.display_col(line_text, col)
    {_vrow_idx, _vrow_col, vrow} = find_visual_row(wrap_entry, display_col)
    trimmed = String.trim_trailing(vrow.text)
    end_byte = max(byte_size(trimmed) - 1, 0)
    {line, vrow.byte_offset + end_byte}
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  # Returns {visual_row_index, col_within_row, visual_row_map} for a display column.
  @spec find_visual_row(WrapMap.wrap_entry(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer(), WrapMap.visual_row()}
  defp find_visual_row(wrap_entry, display_col) do
    {idx, remaining} = display_col_to_visual(wrap_entry, display_col)
    {idx, remaining, Enum.at(wrap_entry, idx)}
  end

  # Given a display column within the full logical line, returns
  # {visual_row_index, column_within_that_visual_row}.
  @spec display_col_to_visual(WrapMap.wrap_entry(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp display_col_to_visual(wrap_entry, display_col) do
    wrap_entry
    |> Enum.with_index()
    |> Enum.reduce_while({0, display_col}, fn {vrow, idx}, {_found_idx, remaining_col} ->
      vrow_width = Unicode.display_width(vrow.text)

      if remaining_col < vrow_width or idx == length(wrap_entry) - 1 do
        {:halt, {idx, remaining_col}}
      else
        {:cont, {idx + 1, remaining_col - vrow_width}}
      end
    end)
  end

  # Converts a display column within a visual row to a byte offset
  # within that visual row's text.
  @spec byte_col_in_vrow(WrapMap.visual_row(), non_neg_integer()) :: non_neg_integer()
  defp byte_col_in_vrow(vrow, target_display_col) do
    Unicode.display_col_to_byte(vrow.text, target_display_col)
  end
end
