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

  # ── Private helpers ────────────────────────────────────────────────────────
end
