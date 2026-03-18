defmodule Minga.Buffer.Decorations.ConcealRange do
  @moduledoc """
  A conceal range decoration: hides buffer characters from the display
  without removing them from the buffer.

  Concealed text occupies zero display columns (or one column if a
  replacement character is specified). The buffer content is never
  modified; `BufferServer.content/1` always returns the raw text
  including concealed characters.

  ## Replacement character

  When `replacement` is nil, the concealed range is invisible. When
  `replacement` is a string (typically a single character like "·"),
  the entire concealed range is replaced by that single character in
  the display. The replacement inherits the style of the first
  concealed character.

  ## Cursor behavior

  In normal mode, the cursor skips over concealed ranges. In insert
  mode, entering a concealed range expands it (reveals the raw
  characters) so the user can edit. For V1, concealment follows
  Neovim's conceallevel=2 equivalent: conceal when the cursor is
  not on the line.

  ## Column mapping

  Concealed ranges affect the mapping between buffer columns and
  display columns. `buf_col_to_display_col` subtracts concealed
  width (and adds replacement width). `display_col_to_buf_col`
  reverses the mapping. These are the central functions that the
  rendering pipeline, mouse handling, and selection logic depend on.
  """

  alias Minga.Buffer.IntervalTree
  alias Minga.Face

  @enforce_keys [:id, :start_pos, :end_pos]
  defstruct [
    :id,
    :start_pos,
    :end_pos,
    :group,
    replacement: nil,
    replacement_style: %Face{name: "_"},
    priority: 0
  ]

  @typedoc """
  A conceal range decoration.

  - `id` - unique reference for removal
  - `start_pos` - inclusive start position `{line, col}` (display columns)
  - `end_pos` - exclusive end position `{line, col}` (display columns)
  - `replacement` - nil for invisible, or a string shown in place of the concealed text
  - `replacement_style` - style keyword list for the replacement character
  - `priority` - higher values take precedence on overlap (default 0)
  - `group` - optional atom for bulk removal (e.g., `:markdown`, `:agent`)
  """
  @type t :: %__MODULE__{
          id: reference(),
          start_pos: IntervalTree.position(),
          end_pos: IntervalTree.position(),
          replacement: String.t() | nil,
          replacement_style: Face.t(),
          priority: integer(),
          group: atom() | nil
        }

  @doc """
  Returns the display width contribution of this conceal range.

  When replacement is nil, the concealed text contributes 0 display columns.
  When replacement is a string, it contributes 1 display column (the
  replacement character).
  """
  @spec display_width(t()) :: non_neg_integer()
  def display_width(%__MODULE__{replacement: nil}), do: 0
  def display_width(%__MODULE__{replacement: _}), do: 1

  @doc """
  Returns the concealed width: the number of buffer columns hidden by this range
  on the given line. For multi-line conceals, returns the portion relevant to
  the specified line.
  """
  @spec concealed_width_on_line(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def concealed_width_on_line(%__MODULE__{start_pos: {sl, sc}, end_pos: {el, ec}}, line, line_len) do
    start_col = if sl < line, do: 0, else: sc
    end_col = if el > line, do: line_len, else: ec
    max(end_col - start_col, 0)
  end

  @doc "Returns true if this conceal range spans the given line."
  @spec spans_line?(t(), non_neg_integer()) :: boolean()
  def spans_line?(%__MODULE__{start_pos: {sl, _}, end_pos: {el, _}}, line) do
    line >= sl and line <= el
  end

  @doc "Returns true if the given position is inside the conceal range."
  @spec contains?(t(), IntervalTree.position()) :: boolean()
  def contains?(%__MODULE__{start_pos: start_pos, end_pos: end_pos}, pos) do
    pos >= start_pos and pos < end_pos
  end
end
