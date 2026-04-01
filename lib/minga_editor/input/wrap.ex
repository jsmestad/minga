defmodule MingaEditor.Input.Wrap do
  @moduledoc """
  Soft-wraps text lines to fit within a column width.

  Any text input widget that needs to display long lines across multiple
  visual rows can use this module. It handles:

  - **Wrapping:** splits a logical line into visual line segments that
    fit within a given width, breaking at word boundaries when possible
    and hard-breaking for long unbroken tokens (URLs, file paths).
  - **Height:** counts total visual lines so the widget can size itself.
  - **Cursor mapping:** translates a logical `{line, col}` cursor to
    a visual `{row, col}` within the wrapped output.
  - **Scroll offset:** keeps the cursor visible when the visual line
    count exceeds a maximum visible window.

  All functions are pure; there is no state. Call them at render time
  with the current text and width.

  ## Comparison with `Minga.Core.WrapMap`

  `WrapMap` serves the main editor buffer and tracks byte offsets for
  syntax highlighting alignment. It also supports breakindent (preserving
  leading whitespace on continuation rows). This module is simpler: it
  tracks grapheme-level column offsets for cursor positioning and skips
  breakindent, which doesn't apply to small input fields.
  """

  alias MingaEditor.Input.VisualLine

  @typedoc "A single visual row within a wrapped logical line."
  @type visual_line :: VisualLine.t()

  @typedoc "Wrap result for one logical line: list of visual rows it expands to."
  @type wrap_entry :: [visual_line()]

  # Below this width, wrapping degenerates. Truncate instead.
  @min_wrap_width 4

  # ── Wrapping ──────────────────────────────────────────────────────────────

  @doc """
  Wraps a single logical line to fit within `width` columns.

  Returns a list of `%{text: ..., col_offset: ...}` maps, one per visual
  row the line occupies. `col_offset` is the grapheme offset into the
  logical line where each visual row starts.

  An empty string returns a single entry with empty text.
  A width below #{@min_wrap_width} truncates rather than wrapping.
  """
  @spec wrap_line(String.t(), pos_integer()) :: wrap_entry()
  def wrap_line("", _width), do: [%VisualLine{text: "", col_offset: 0}]

  def wrap_line(text, width) when width < @min_wrap_width do
    [%VisualLine{text: String.slice(text, 0, width), col_offset: 0}]
  end

  def wrap_line(text, width) do
    graphemes = String.graphemes(text)

    if length(graphemes) <= width do
      [%VisualLine{text: text, col_offset: 0}]
    else
      do_wrap(graphemes, width, 0, [])
    end
  end

  @doc """
  Wraps a list of logical lines and returns a flat list of visual rows,
  each tagged with its logical line index.

  Useful when you need to render a scrollable window over the wrapped output.
  """
  @spec wrap_lines([String.t()], pos_integer()) :: [{non_neg_integer(), visual_line()}]
  def wrap_lines(lines, width) do
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, idx} ->
      line
      |> wrap_line(width)
      |> Enum.map(fn vl -> {idx, vl} end)
    end)
  end

  # ── Height ────────────────────────────────────────────────────────────────

  @doc """
  Counts total visual rows across all logical lines when wrapped to `width`.
  """
  @spec visual_line_count([String.t()], pos_integer()) :: pos_integer()
  def visual_line_count(lines, width) do
    Enum.reduce(lines, 0, fn line, acc ->
      acc + length(wrap_line(line, width))
    end)
  end

  @doc """
  Computes the visible height for a text input widget.

  Takes the logical lines, the available inner width, and a maximum
  number of visible rows. Returns the number of visual rows to display
  (clamped to `[1, max_visible]`).

  This does NOT include any chrome (borders, padding). The caller adds
  those. For example, a bordered input box would add 2 to this value.
  """
  @spec visible_height([String.t()], pos_integer(), pos_integer()) :: pos_integer()
  def visible_height(lines, width, max_visible) do
    visual = visual_line_count(lines, width)
    max(min(visual, max_visible), 1)
  end

  # ── Cursor mapping ────────────────────────────────────────────────────────

  @doc """
  Maps a logical cursor `{line, col}` to a visual `{row, col}`.

  `row` is the 0-based index into the flat list of visual rows across
  all wrapped lines. `col` is the column within that visual row.
  """
  @spec logical_to_visual([String.t()], pos_integer(), {non_neg_integer(), non_neg_integer()}) ::
          {non_neg_integer(), non_neg_integer()}
  def logical_to_visual(lines, width, {cursor_line, cursor_col}) do
    # Sum visual rows from all logical lines before the cursor's line
    visual_offset =
      lines
      |> Enum.take(cursor_line)
      |> Enum.reduce(0, fn line, acc -> acc + length(wrap_line(line, width)) end)

    # Find which visual row within the cursor's logical line contains the cursor
    current_line = Enum.at(lines, cursor_line) || ""
    wrapped = wrap_line(current_line, width)

    {vl_idx, visual_col} = find_cursor_in_wrapped(wrapped, cursor_col)

    {visual_offset + vl_idx, visual_col}
  end

  # ── Scroll ────────────────────────────────────────────────────────────────

  @doc """
  Computes scroll offset to keep `cursor_visual_row` visible within a
  window of `visible_rows` out of `total_visual_rows`.

  Returns the first visual row to display (0-based).
  """
  @spec scroll_offset(non_neg_integer(), pos_integer(), pos_integer()) :: non_neg_integer()
  def scroll_offset(cursor_visual_row, visible_rows, total_visual_rows) do
    max_scroll = max(total_visual_rows - visible_rows, 0)
    min(max(cursor_visual_row - visible_rows + 1, 0), max_scroll)
  end

  # ── Private ───────────────────────────────────────────────────────────────

  @spec do_wrap([String.t()], pos_integer(), non_neg_integer(), wrap_entry()) :: wrap_entry()
  defp do_wrap([], _width, _offset, acc), do: Enum.reverse(acc)

  defp do_wrap(graphemes, width, offset, acc) do
    {taken, rest} = Enum.split(graphemes, width)

    case rest do
      [] ->
        entry = %VisualLine{text: Enum.join(taken), col_offset: offset}
        Enum.reverse([entry | acc])

      _ ->
        {row_graphemes, overflow} = break_at_word_boundary(taken, rest)
        row_len = length(row_graphemes)
        entry = %VisualLine{text: Enum.join(row_graphemes), col_offset: offset}
        do_wrap(overflow, width, offset + row_len, [entry | acc])
    end
  end

  # Finds the last space in `taken` and breaks there, pushing the
  # remainder back onto `rest`. Falls back to a hard break when no
  # space is found.
  @spec break_at_word_boundary([String.t()], [String.t()]) :: {[String.t()], [String.t()]}
  defp break_at_word_boundary(taken, rest) do
    last_space =
      taken
      |> Enum.with_index()
      |> Enum.filter(fn {g, _} -> g == " " end)
      |> List.last()

    case last_space do
      {_, idx} when idx > 0 ->
        # Break after the space (include it in the current row)
        {row, overflow} = Enum.split(taken, idx + 1)
        {row, overflow ++ rest}

      _ ->
        {taken, rest}
    end
  end

  # Finds which visual row the cursor column falls on within a wrapped
  # entry. Returns `{visual_row_index, visual_col}`.
  @spec find_cursor_in_wrapped(wrap_entry(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp find_cursor_in_wrapped([%VisualLine{col_offset: offset, text: text}], cursor_col) do
    visual_col = min(cursor_col - offset, String.length(text))
    {0, max(visual_col, 0)}
  end

  defp find_cursor_in_wrapped([%VisualLine{col_offset: offset, text: text} | rest], cursor_col) do
    next_offset = offset + String.length(text)

    if cursor_col < next_offset do
      {0, max(cursor_col - offset, 0)}
    else
      {idx, col} = find_cursor_in_wrapped(rest, cursor_col)
      {idx + 1, col}
    end
  end
end
