defmodule Minga.Editor.Viewport do
  @moduledoc """
  Viewport logic for scrolling the visible region of a buffer.

  The viewport defines which lines and columns are currently visible
  in the terminal. When the cursor moves outside the viewport, it
  scrolls to keep the cursor visible.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Options

  @enforce_keys [:top, :left, :rows, :cols]
  defstruct [:top, :left, :rows, :cols, reserved: 2]

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
  """
  @type t :: %__MODULE__{
          top: non_neg_integer(),
          left: non_neg_integer(),
          rows: pos_integer(),
          cols: pos_integer(),
          reserved: non_neg_integer()
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

  @doc """
  Number of rows reserved for the footer (modeline + minibuffer).
  """
  @spec footer_rows() :: pos_integer()
  def footer_rows, do: 2

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
        Options.get(:scroll_margin)
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
        BufferServer.get_option(buf, :scroll_margin)
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

    top =
      cond do
        cursor_line < vp.top + effective_margin ->
          max(cursor_line - effective_margin, 0)

        cursor_line >= vp.top + visible_rows - effective_margin ->
          cursor_line - visible_rows + 1 + effective_margin

        true ->
          vp.top
      end

    left =
      cond do
        cursor_col < vp.left -> cursor_col
        cursor_col >= vp.left + vp.cols -> cursor_col - vp.cols + 1
        true -> vp.left
      end

    %__MODULE__{vp | top: top, left: left}
  end

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

  The cursor line is clamped to remain visible. Returns
  `{updated_viewport, clamped_cursor_line}`.
  """
  @spec scroll_line_down(t(), non_neg_integer(), non_neg_integer()) ::
          {t(), non_neg_integer()}
  def scroll_line_down(%__MODULE__{} = vp, cursor_line, total_lines) do
    visible = content_rows(vp)
    max_top = max(total_lines - visible, 0)
    new_top = min(vp.top + 1, max_top)
    clamped_cursor = max(cursor_line, new_top)
    {%__MODULE__{vp | top: new_top}, clamped_cursor}
  end

  @doc """
  Scrolls the viewport up by one line without moving the cursor.

  The cursor line is clamped to remain visible. Returns
  `{updated_viewport, clamped_cursor_line}`.
  """
  @spec scroll_line_up(t(), non_neg_integer(), non_neg_integer()) ::
          {t(), non_neg_integer()}
  def scroll_line_up(%__MODULE__{} = vp, cursor_line, _total_lines) do
    new_top = max(vp.top - 1, 0)
    visible = content_rows(vp)
    max_cursor = new_top + visible - 1
    clamped_cursor = min(cursor_line, max_cursor)
    {%__MODULE__{vp | top: new_top}, clamped_cursor}
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
    %__MODULE__{vp | top: new_top}
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
    %__MODULE__{vp | top: new_top}
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
    %__MODULE__{vp | top: new_top}
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
          Minga.Buffer.Decorations.t(),
          non_neg_integer()
        ) :: pos_integer()
  def effective_page_lines(cursor_line, display_rows, decorations, total_lines) do
    alias Minga.Buffer.Decorations

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
    alias Minga.Buffer.Decorations
    alias Minga.Buffer.Decorations.BlockDecoration

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
