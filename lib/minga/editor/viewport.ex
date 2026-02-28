defmodule Minga.Editor.Viewport do
  @moduledoc """
  Viewport logic for scrolling the visible region of a buffer.

  The viewport defines which lines and columns are currently visible
  in the terminal. When the cursor moves outside the viewport, it
  scrolls to keep the cursor visible.
  """

  @enforce_keys [:top, :left, :rows, :cols]
  defstruct [:top, :left, :rows, :cols]

  @typedoc "A viewport representing the visible terminal region."
  @type t :: %__MODULE__{
          top: non_neg_integer(),
          left: non_neg_integer(),
          rows: pos_integer(),
          cols: pos_integer()
        }

  @doc "Creates a new viewport with the given dimensions."
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(rows, cols) when is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 do
    %__MODULE__{top: 0, left: 0, rows: rows, cols: cols}
  end

  @doc """
  Scrolls the viewport to keep the cursor visible.

  Returns a new viewport adjusted so that the cursor position
  `{line, col}` is within the visible area. Reserves the last
  row for the status line.
  """
  @spec scroll_to_cursor(t(), {non_neg_integer(), non_neg_integer()}) :: t()
  def scroll_to_cursor(%__MODULE__{} = vp, {cursor_line, cursor_col}) do
    # Reserve 1 row for status line
    visible_rows = max(vp.rows - 1, 1)

    top =
      cond do
        cursor_line < vp.top -> cursor_line
        cursor_line >= vp.top + visible_rows -> cursor_line - visible_rows + 1
        true -> vp.top
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
  def visible_range(%__MODULE__{top: top, rows: rows}) do
    # Reserve 1 row for status line
    visible_rows = max(rows - 1, 1)
    {top, top + visible_rows - 1}
  end

  @doc "Returns the number of content rows (total rows minus status line)."
  @spec content_rows(t()) :: pos_integer()
  def content_rows(%__MODULE__{rows: rows}) do
    max(rows - 1, 1)
  end
end
