defmodule MingaEditor.Viewport do
  @moduledoc """
  Viewport logic for scrolling the visible region of a buffer.

  The viewport defines which lines and columns are currently visible
  in the terminal. When the cursor moves outside the viewport, it
  scrolls to keep the cursor visible.
  """

  alias Minga.Buffer
  alias Minga.Config

  @enforce_keys [:top, :left, :rows, :cols]
  defstruct [:top, :left, :rows, :cols, reserved: 2, visual_row_offset: 0]

  @typedoc """
  A viewport representing the visible terminal region.

  * `top`      — first visible buffer line (0-indexed)
  * `left`     — first visible **display column** (0-indexed, in terminal columns).
                 Wide characters (CJK, emoji) occupy 2 display columns, so
                 horizontal scroll advances by display columns, not grapheme counts.
  * `rows`     — total rows in this viewport (including reserved rows)
  * `cols`     — total columns in this viewport
  * `reserved` — rows reserved for non-content elements (modeline, minibuffer).
                 Defaults to `footer_rows()` (2) for the terminal-level viewport.
                 Set to 0 for per-window viewports where Layout already excluded
                 the modeline from the content rect.
  * `visual_row_offset` — first visual row shown within `top` when wrapping is active.
                          `{top: 5, visual_row_offset: 2}` starts on the third visual row of logical line 5.
  """
  @type t :: %__MODULE__{
          top: non_neg_integer(),
          left: non_neg_integer(),
          rows: pos_integer(),
          cols: pos_integer(),
          reserved: non_neg_integer(),
          visual_row_offset: non_neg_integer()
        }

  @doc "Creates a new viewport with the given dimensions and default reserved rows (2)."
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(rows, cols) when is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 do
    %__MODULE__{top: 0, left: 0, rows: rows, cols: cols, reserved: footer_rows()}
  end

  @doc "Creates a new viewport with the given dimensions and explicit reserved rows."
  @spec new(pos_integer(), pos_integer(), non_neg_integer()) :: t()
  def new(rows, cols, reserved)
      when is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 and
             is_integer(reserved) and reserved >= 0 do
    %__MODULE__{top: 0, left: 0, rows: rows, cols: cols, reserved: reserved}
  end

  @doc "Stores a logical top line and resets wrapped row offset."
  @spec put_top(t(), non_neg_integer()) :: t()
  def put_top(%__MODULE__{} = vp, top) when is_integer(top) and top >= 0 do
    %{vp | top: top, visual_row_offset: 0}
  end

  @doc """
  Number of rows reserved for the footer (modeline + minibuffer).
  """
  @spec footer_rows() :: pos_integer()
  def footer_rows, do: 2

  @doc """
  Adjusts the raw row count for a line spacing multiplier.

  When `line_spacing > 1.0`, each line takes more vertical space, so fewer
  lines fit on screen. Returns `floor(rows / line_spacing)`, clamped to at
  least 1. Returns the input unchanged when spacing is 1.0 (the TUI default).

  The caller reads `Config.get(:line_spacing)` and passes it here. This keeps
  Viewport a pure module with no config dependency.
  """
  @spec effective_rows(pos_integer(), number()) :: pos_integer()
  def effective_rows(raw_rows, line_spacing \\ 1.0)

  def effective_rows(raw_rows, line_spacing)
      when is_integer(raw_rows) and raw_rows > 0 and is_number(line_spacing) and
             line_spacing > 1.0 do
    max(floor(raw_rows / line_spacing), 1)
  end

  def effective_rows(raw_rows, _line_spacing) when is_integer(raw_rows) and raw_rows > 0 do
    raw_rows
  end

  @doc """
  Scrolls the viewport to keep the cursor visible.

  Returns a new viewport adjusted so that the cursor position `{line, col}`
  is within the visible area. `col` must be a **display column** (terminal
  columns, not grapheme count) — wide characters count as 2. Reserves footer
  rows for the modeline and minibuffer.
  """
  @spec scroll_to_cursor(t(), {non_neg_integer(), non_neg_integer()}) :: t()
  def scroll_to_cursor(%__MODULE__{} = vp, {cursor_line, cursor_col}) do
    margin =
      try do
        Config.get(:scroll_margin)
      catch
        :exit, _ -> 5
      end

    scroll_to_cursor(vp, {cursor_line, cursor_col}, margin)
  end

  @doc """
  Scrolls the viewport with a scroll margin.

  Accepts either a buffer pid (reads `scroll_margin` from the buffer's
  local options) or an explicit integer margin. The margin keeps `n`
  lines visible above and below the cursor when possible. When the file
  is shorter than `2 * margin + 1`, the margin shrinks to fit.
  """
  @spec scroll_to_cursor(t(), {non_neg_integer(), non_neg_integer()}, pid() | non_neg_integer()) ::
          t()
  def scroll_to_cursor(%__MODULE__{} = vp, {cursor_line, cursor_col}, buf) when is_pid(buf) do
    margin =
      try do
        Buffer.get_option(buf, :scroll_margin)
      catch
        :exit, _ -> 5
      end

    scroll_to_cursor(vp, {cursor_line, cursor_col}, margin)
  end

  def scroll_to_cursor(%__MODULE__{} = vp, {cursor_line, cursor_col}, margin) do
    # Reserve rows for non-content elements (modeline, minibuffer, etc.)
    visible_rows = max(vp.rows - vp.reserved, 1)
    # Clamp margin so it can't exceed half the visible area
    effective_margin = min(margin, div(visible_rows - 1, 2))

    top = adjust_top(vp.top, cursor_line, visible_rows, effective_margin)
    left = adjust_left(vp.left, cursor_col, vp.cols)

    %{put_top(vp, top) | left: left}
  end

  @doc "Stores a top logical line and clamps the visual row offset for that line."
  @spec put_top_visual(t(), non_neg_integer(), non_neg_integer(), pos_integer()) :: t()
  def put_top_visual(%__MODULE__{} = vp, top, offset, visual_row_count)
      when is_integer(top) and top >= 0 and is_integer(offset) and offset >= 0 and
             is_integer(visual_row_count) and visual_row_count > 0 do
    %{vp | top: top, visual_row_offset: min(offset, visual_row_count - 1)}
  end

  @doc "Returns the maximum visual row offset allowed for the rows remaining to EOF."
  @spec max_visual_row_offset(pos_integer(), pos_integer()) :: non_neg_integer()
  def max_visual_row_offset(total_visual_rows_to_eof, visible_rows)
      when is_integer(total_visual_rows_to_eof) and total_visual_rows_to_eof > 0 and
             is_integer(visible_rows) and visible_rows > 0 do
    max(total_visual_rows_to_eof - visible_rows, 0)
  end

  @doc "Clamps the current visual row offset against the rows remaining to EOF."
  @spec clamp_visual_row_offset(t(), pos_integer(), pos_integer()) :: t()
  def clamp_visual_row_offset(%__MODULE__{} = vp, total_visual_rows_to_eof, visible_rows)
      when is_integer(total_visual_rows_to_eof) and total_visual_rows_to_eof > 0 and
             is_integer(visible_rows) and visible_rows > 0 do
    %{
      vp
      | visual_row_offset:
          min(vp.visual_row_offset, max_visual_row_offset(total_visual_rows_to_eof, visible_rows))
    }
  end

  @doc "Clamps the current visual row offset against the visual row count of `top`."
  @spec clamp_visual_row_offset(t(), pos_integer()) :: t()
  def clamp_visual_row_offset(%__MODULE__{} = vp, visual_row_count)
      when is_integer(visual_row_count) and visual_row_count > 0 do
    %{vp | visual_row_offset: min(vp.visual_row_offset, visual_row_count - 1)}
  end

  @doc "Scrolls down by one visual row when wrapping is active."
  @spec scroll_visual_row_down(t(), pos_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def scroll_visual_row_down(%__MODULE__{} = vp, top_line_visual_rows, total_lines, _margin)
      when is_integer(top_line_visual_rows) and top_line_visual_rows > 0 and
             is_integer(total_lines) and total_lines >= 0 do
    max_top = max(total_lines - 1, 0)
    visible_rows = content_rows(vp)
    max_offset = max(top_line_visual_rows - visible_rows, 0)

    advance_visual_row_down(vp, top_line_visual_rows, max_top, max_offset)
  end

  @spec advance_visual_row_down(t(), pos_integer(), non_neg_integer(), non_neg_integer()) :: t()
  defp advance_visual_row_down(vp, _top_line_visual_rows, max_top, max_offset)
       when vp.top >= max_top and vp.visual_row_offset >= max_offset do
    %{vp | visual_row_offset: min(vp.visual_row_offset, max_offset)}
  end

  defp advance_visual_row_down(vp, top_line_visual_rows, _max_top, _max_offset)
       when vp.visual_row_offset + 1 < top_line_visual_rows do
    %{vp | visual_row_offset: vp.visual_row_offset + 1}
  end

  defp advance_visual_row_down(vp, _top_line_visual_rows, max_top, _max_offset) do
    put_top(vp, min(vp.top + 1, max_top))
  end

  @doc "Scrolls up by one visual row when wrapping is active."
  @spec scroll_visual_row_up(t(), pos_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def scroll_visual_row_up(%__MODULE__{} = vp, previous_line_visual_rows, _total_lines, _margin)
      when is_integer(previous_line_visual_rows) and previous_line_visual_rows > 0 do
    if vp.visual_row_offset > 0 do
      %{vp | visual_row_offset: vp.visual_row_offset - 1}
    else
      new_top = max(vp.top - 1, 0)
      offset = if new_top == vp.top, do: 0, else: previous_line_visual_rows - 1
      %{put_top(vp, new_top) | visual_row_offset: offset}
    end
  end

  @doc "Scrolls to a cursor visual row within its logical line when wrapping is active."
  @spec scroll_to_cursor_visual(
          t(),
          {non_neg_integer(), non_neg_integer()},
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: t()
  def scroll_to_cursor_visual(
        %__MODULE__{} = vp,
        {cursor_line, cursor_col},
        cursor_visual_row,
        cursor_line_visual_rows,
        margin
      )
      when is_integer(cursor_visual_row) and cursor_visual_row >= 0 and
             is_integer(cursor_line_visual_rows) and cursor_line_visual_rows > 0 do
    visible_rows = content_rows(vp)
    effective_margin = min(margin, div(visible_rows - 1, 2))

    vp
    |> adjust_top_visual(
      cursor_line,
      cursor_visual_row,
      cursor_line_visual_rows,
      visible_rows,
      effective_margin
    )
    |> Map.put(:left, adjust_left(vp.left, cursor_col, vp.cols))
  end

  @spec adjust_top_visual(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: t()
  defp adjust_top_visual(
         vp,
         cursor_line,
         cursor_visual_row,
         cursor_line_visual_rows,
         _visible,
         margin
       )
       when cursor_line == vp.top and cursor_visual_row < vp.visual_row_offset + margin do
    offset = max(cursor_visual_row - margin, 0)
    put_top_visual(vp, cursor_line, offset, cursor_line_visual_rows)
  end

  defp adjust_top_visual(
         vp,
         cursor_line,
         cursor_visual_row,
         cursor_line_visual_rows,
         visible,
         margin
       )
       when cursor_line == vp.top and cursor_visual_row >= vp.visual_row_offset + visible - margin do
    offset = max(cursor_visual_row - visible + 1 + margin, 0)
    put_top_visual(vp, cursor_line, offset, cursor_line_visual_rows)
  end

  defp adjust_top_visual(
         vp,
         cursor_line,
         cursor_visual_row,
         cursor_line_visual_rows,
         _visible,
         _margin
       )
       when cursor_line < vp.top do
    put_top_visual(vp, cursor_line, cursor_visual_row, cursor_line_visual_rows)
  end

  defp adjust_top_visual(
         vp,
         cursor_line,
         _cursor_visual_row,
         _cursor_line_visual_rows,
         _visible,
         _margin
       )
       when cursor_line > vp.top do
    put_top(vp, cursor_line)
  end

  defp adjust_top_visual(
         vp,
         _cursor_line,
         _cursor_visual_row,
         cursor_line_visual_rows,
         _visible,
         _margin
       ) do
    clamp_visual_row_offset(vp, cursor_line_visual_rows)
  end

  # Cursor is above the top margin: scroll up to give margin space.
  @spec adjust_top(non_neg_integer(), non_neg_integer(), pos_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp adjust_top(top, cursor_line, _visible, margin)
       when cursor_line < top + margin do
    max(cursor_line - margin, 0)
  end

  # Cursor is below the bottom margin: scroll down to give margin space.
  defp adjust_top(top, cursor_line, visible, margin)
       when cursor_line >= top + visible - margin do
    cursor_line - visible + 1 + margin
  end

  # Cursor is in the margin-safe zone: no scroll needed.
  defp adjust_top(top, _cursor_line, _visible, _margin), do: top

  # Guard against negative cursor_col (can happen with stale coordinates).
  @spec adjust_left(non_neg_integer(), integer(), pos_integer()) :: non_neg_integer()
  defp adjust_left(_left, cursor_col, _cols) when cursor_col < 0, do: 0

  # Cursor is left of the viewport: scroll left to show it.
  defp adjust_left(left, cursor_col, _cols) when cursor_col < left, do: cursor_col

  # Cursor is right of the viewport: scroll right to show it.
  defp adjust_left(left, cursor_col, cols) when cursor_col >= left + cols do
    cursor_col - cols + 1
  end

  # Cursor is visible horizontally: no scroll needed.
  defp adjust_left(left, _cursor_col, _cols), do: left

  @doc "Returns the range of visible lines as `{first_line, last_line}` (inclusive)."
  @spec visible_range(t()) :: {non_neg_integer(), non_neg_integer()}
  def visible_range(%__MODULE__{top: top, rows: rows, reserved: reserved}) do
    visible_rows = max(rows - reserved, 1)
    {top, top + visible_rows - 1}
  end

  @doc "Returns the number of content rows (total rows minus reserved)."
  @spec content_rows(t()) :: pos_integer()
  def content_rows(%__MODULE__{rows: rows, reserved: reserved}) do
    max(rows - reserved, 1)
  end

  @doc "Returns a cache key that changes for logical and visual scrolling."
  @spec cache_key(t()) :: non_neg_integer()
  def cache_key(%__MODULE__{top: top, visual_row_offset: offset}) do
    top * 1_000_000 + offset
  end

  @doc """
  Computes the gutter width for line numbers based on total line count.

  Returns `max(digits(line_count), 2) + 1` — at least 2 digits plus a
  trailing space separator. For example: 1–99 lines → 3, 100–999 → 4.
  """
  @spec gutter_width(non_neg_integer()) :: pos_integer()
  def gutter_width(line_count) when is_integer(line_count) and line_count >= 0 do
    digits = line_count |> max(1) |> Integer.digits() |> length()
    max(digits, 2) + 1
  end

  @doc """
  Returns the number of columns available for buffer content after the gutter.

  Subtracts `gutter_width(line_count)` from the viewport's total columns,
  clamped to at least 1.
  """
  @spec content_cols(t(), non_neg_integer()) :: pos_integer()
  def content_cols(%__MODULE__{cols: cols}, line_count)
      when is_integer(line_count) and line_count >= 0 do
    max(cols - gutter_width(line_count), 1)
  end

  # ── Scroll-without-cursor commands ───────────────────────────────────────

  @doc """
  Scrolls the viewport down by one line without moving the cursor.

  The cursor line is clamped to remain visible and respect scroll_margin.
  When scrolling down, the cursor is pushed away from the top edge to
  maintain the margin, matching vim's scrolloff behavior for Ctrl-E.
  Returns `{updated_viewport, clamped_cursor_line}`.
  """
  @spec scroll_line_down(t(), non_neg_integer(), non_neg_integer()) ::
          {t(), non_neg_integer()}
  def scroll_line_down(%__MODULE__{} = vp, cursor_line, total_lines) do
    scroll_line_down(vp, cursor_line, total_lines, default_scroll_margin())
  end

  @doc """
  Scrolls the viewport down by one line with an explicit scroll margin.
  """
  @spec scroll_line_down(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {t(), non_neg_integer()}
  def scroll_line_down(%__MODULE__{} = vp, cursor_line, total_lines, margin) do
    visible = content_rows(vp)
    max_top = max(total_lines - visible, 0)
    new_top = min(vp.top + 1, max_top)
    effective_margin = min(margin, div(visible - 1, 2))

    # Scrolling down: enforce top margin (push cursor away from top edge)
    min_cursor = new_top + effective_margin
    clamped_cursor = cursor_line |> max(new_top) |> max(min(min_cursor, new_top + visible - 1))
    {put_top(vp, new_top), clamped_cursor}
  end

  @doc """
  Scrolls the viewport up by one line without moving the cursor.

  The cursor line is clamped to remain visible and respect scroll_margin.
  When scrolling up, the cursor is pushed away from the bottom edge to
  maintain the margin, matching vim's scrolloff behavior for Ctrl-Y.
  Returns `{updated_viewport, clamped_cursor_line}`.
  """
  @spec scroll_line_up(t(), non_neg_integer(), non_neg_integer()) ::
          {t(), non_neg_integer()}
  def scroll_line_up(%__MODULE__{} = vp, cursor_line, _total_lines) do
    scroll_line_up(vp, cursor_line, 0, default_scroll_margin())
  end

  @doc """
  Scrolls the viewport up by one line with an explicit scroll margin.
  """
  @spec scroll_line_up(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {t(), non_neg_integer()}
  def scroll_line_up(%__MODULE__{} = vp, cursor_line, _total_lines, margin) do
    new_top = max(vp.top - 1, 0)
    visible = content_rows(vp)
    effective_margin = min(margin, div(visible - 1, 2))

    # Scrolling up: enforce bottom margin (push cursor away from bottom edge)
    max_cursor = new_top + visible - 1 - effective_margin
    clamped_cursor = cursor_line |> min(new_top + visible - 1) |> min(max(max_cursor, new_top))
    {put_top(vp, new_top), clamped_cursor}
  end

  # Default scroll margin. Reads from config, falls back to 5.
  @spec default_scroll_margin() :: non_neg_integer()
  defp default_scroll_margin do
    Config.get(:scroll_margin)
  catch
    :exit, _ -> 5
  end

  @doc """
  Centers the viewport on the given cursor line (`zz` in vim).

  Returns the updated viewport.
  """
  @spec center_on(t(), non_neg_integer(), non_neg_integer()) :: t()
  def center_on(%__MODULE__{} = vp, cursor_line, total_lines) do
    visible = content_rows(vp)
    target_top = cursor_line - div(visible, 2)
    max_top = max(total_lines - visible, 0)
    new_top = min(max(target_top, 0), max_top)
    put_top(vp, new_top)
  end

  @doc """
  Scrolls so the cursor line is at the top of the viewport (`zt` in vim).

  Respects scroll_margin by placing the cursor `margin` lines from the top.
  """
  @spec top_on(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def top_on(%__MODULE__{} = vp, cursor_line, total_lines, margin \\ 0) do
    visible = content_rows(vp)
    effective_margin = min(margin, div(visible - 1, 2))
    target_top = max(cursor_line - effective_margin, 0)
    max_top = max(total_lines - visible, 0)
    new_top = min(target_top, max_top)
    put_top(vp, new_top)
  end

  @doc """
  Scrolls so the cursor line is at the bottom of the viewport (`zb` in vim).

  Respects scroll_margin by placing the cursor `margin` lines from the bottom.
  """
  @spec bottom_on(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def bottom_on(%__MODULE__{} = vp, cursor_line, total_lines, margin \\ 0) do
    visible = content_rows(vp)
    effective_margin = min(margin, div(visible - 1, 2))
    target_top = cursor_line - visible + 1 + effective_margin
    max_top = max(total_lines - visible, 0)
    new_top = min(max(target_top, 0), max_top)
    put_top(vp, new_top)
  end

  # ── Decoration-aware helpers ─────────────────────────────────────────────

  @doc """
  Computes how many buffer lines fit in `display_rows` screen rows,
  accounting for decorations that consume extra display rows.

  Walks forward from `cursor_line`, counting each buffer line as 1 display
  row plus any virtual lines and block decorations attached to it. Stops
  when the display row budget is exhausted. Returns the number of buffer
  lines traversed.

  When there are no decorations, this returns `display_rows` (the fast path).
  """
  @spec effective_page_lines(
          non_neg_integer(),
          pos_integer(),
          Minga.Core.Decorations.t(),
          non_neg_integer()
        ) :: pos_integer()
  def effective_page_lines(cursor_line, display_rows, decorations, total_lines) do
    alias Minga.Core.Decorations

    if not Decorations.has_block_decorations?(decorations) and
         Decorations.virtual_line_count(decorations, cursor_line, cursor_line + display_rows) == 0 do
      # Fast path: no decorations in this range, but clamp to remaining lines
      min(display_rows, max(total_lines - cursor_line, 1))
    else
      do_effective_page_lines(cursor_line, display_rows, decorations, total_lines, 0, 0)
    end
  end

  defp do_effective_page_lines(_line, display_budget, _decs, _total, buf_count, _display_used)
       when display_budget <= 0 do
    max(buf_count, 1)
  end

  defp do_effective_page_lines(line, _display_budget, _decs, total, buf_count, _display_used)
       when line >= total do
    max(buf_count, 1)
  end

  defp do_effective_page_lines(line, display_budget, decorations, total, buf_count, display_used) do
    alias Minga.Core.Decorations
    alias Minga.Core.Decorations.BlockDecoration

    # Count display rows consumed by this buffer line:
    # 1 for the line itself + virtual lines + block decorations
    virt = Decorations.virtual_line_count(decorations, line, line + 1)

    block_rows =
      decorations.block_decorations
      |> Enum.filter(fn b -> b.anchor_line == line end)
      |> Enum.reduce(0, fn b, acc -> acc + BlockDecoration.resolve_height(b, 80) end)

    rows_for_line = 1 + virt + block_rows
    new_used = display_used + rows_for_line

    if new_used > display_budget and buf_count > 0 do
      # This line would exceed the budget and we already have some lines
      max(buf_count, 1)
    else
      do_effective_page_lines(
        line + 1,
        display_budget,
        decorations,
        total,
        buf_count + 1,
        new_used
      )
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────────
end
