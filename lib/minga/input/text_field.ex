defmodule Minga.Input.TextField do
  @moduledoc """
  A reusable multi-line text input with cursor tracking.

  `TextField` is a pure data structure that stores lines of text and a
  2D cursor position. It provides editing operations (insert, delete,
  newline) and cursor movement (left, right, up, down, home, end). All
  functions are pure and return an updated struct.

  Use this as the foundation for any text input widget: chat prompts,
  command lines, search fields, eval inputs. Combine with
  `Minga.Input.Wrap` at render time for soft-wrapping in bounded-width
  containers.

  ## Design decisions

  - **Lines, not a string.** Storing `[String.t()]` makes multi-line
    editing O(1) per line instead of scanning for newlines. Single-line
    inputs simply never call `insert_newline/1`.
  - **Cursor as `{line, col}`.** Both are 0-based grapheme indices.
    Column is clamped to line length on vertical movement, matching vim
    behavior.
  - **Boundary sentinels.** `move_up/1` returns `:at_top` when the
    cursor is already on the first line, and `move_down/1` returns
    `:at_bottom` on the last line. This lets callers decide what to do
    at boundaries (e.g., cycle through prompt history) without encoding
    that policy in the text field itself.
  - **No wrapping awareness.** Wrapping is a rendering concern handled
    by `Minga.Input.Wrap`. When a UI component needs wrap-aware cursor
    movement (up/down by visual line), it queries Wrap to compute
    positions and updates the TextField accordingly.
  """

  @typedoc "Cursor position: `{line_index, column_index}`, both 0-based."
  @type cursor :: {non_neg_integer(), non_neg_integer()}

  @typedoc "A multi-line text field with cursor."
  @type t :: %__MODULE__{
          lines: [String.t()],
          cursor: cursor()
        }

  @enforce_keys []
  defstruct lines: [""],
            cursor: {0, 0}

  # ── Construction ──────────────────────────────────────────────────────────

  @doc "Creates an empty text field."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a text field initialized with `text`.

  The cursor is placed at the end of the text.
  """
  @spec new(String.t()) :: t()
  def new(text) when is_binary(text) do
    lines = String.split(text, "\n")
    last_line = List.last(lines)
    cursor = {length(lines) - 1, String.length(last_line)}
    %__MODULE__{lines: lines, cursor: cursor}
  end

  @doc """
  Creates a text field from explicit lines and cursor.

  The cursor is clamped to valid bounds.
  """
  @spec from_parts([String.t()], cursor()) :: t()
  def from_parts(lines, {line, col}) when is_list(lines) do
    lines = if lines == [], do: [""], else: lines
    line = clamp(line, 0, length(lines) - 1)
    col = clamp(col, 0, String.length(Enum.at(lines, line)))
    %__MODULE__{lines: lines, cursor: {line, col}}
  end

  # ── Access ────────────────────────────────────────────────────────────────

  @doc "Returns the full text by joining lines with newlines."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{} = tf), do: content(tf)

  @doc "Returns the number of logical lines."
  @spec line_count(t()) :: pos_integer()
  def line_count(%__MODULE__{lines: lines}), do: length(lines)

  @doc "Returns true if the field contains only an empty string."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{lines: [""]}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc "Returns the text of the line the cursor is on."
  @spec current_line(t()) :: String.t()
  def current_line(%__MODULE__{lines: lines, cursor: {line, _}}), do: Enum.at(lines, line)

  # ── Editing ───────────────────────────────────────────────────────────────

  @doc "Inserts a character (or short string) at the cursor position."
  @spec insert_char(t(), String.t()) :: t()
  def insert_char(%__MODULE__{cursor: {line, col}, lines: lines} = tf, char) do
    current = Enum.at(lines, line)
    {before, after_cursor} = String.split_at(current, col)
    updated = before <> char <> after_cursor

    %{
      tf
      | lines: List.replace_at(lines, line, updated),
        cursor: {line, col + String.length(char)}
    }
  end

  @doc """
  Inserts a block of text at the cursor, handling multi-line content.

  Single-line text is merged into the current line. Multi-line text
  splits the current line at the cursor: the first inserted line merges
  with the text before the cursor, the last inserted line merges with
  the text after the cursor, and middle lines are inserted between them.
  """
  @spec insert_text(t(), String.t()) :: t()
  def insert_text(%__MODULE__{} = tf, ""), do: tf

  def insert_text(%__MODULE__{cursor: {cur_line, cur_col}, lines: lines} = tf, text) do
    paste_lines = String.split(text, "\n")
    current = Enum.at(lines, cur_line)
    {before, after_cursor} = String.split_at(current, cur_col)

    {new_lines, new_cursor} =
      case paste_lines do
        [single] ->
          merged = before <> single <> after_cursor
          {List.replace_at(lines, cur_line, merged), {cur_line, cur_col + String.length(single)}}

        [first | rest] ->
          {middle, [last]} = Enum.split(rest, -1)
          first_merged = before <> first
          last_merged = last <> after_cursor

          pre = Enum.take(lines, cur_line)
          post = Enum.drop(lines, cur_line + 1)
          assembled = pre ++ [first_merged] ++ middle ++ [last_merged] ++ post

          new_cur_line = cur_line + length(paste_lines) - 1
          new_cur_col = String.length(last)
          {assembled, {new_cur_line, new_cur_col}}
      end

    %{tf | lines: new_lines, cursor: new_cursor}
  end

  @doc "Inserts a newline at the cursor, splitting the current line."
  @spec insert_newline(t()) :: t()
  def insert_newline(%__MODULE__{cursor: {line, col}, lines: lines} = tf) do
    current = Enum.at(lines, line)
    {before, after_cursor} = String.split_at(current, col)

    new_lines =
      lines
      |> List.replace_at(line, before)
      |> List.insert_at(line + 1, after_cursor)

    %{tf | lines: new_lines, cursor: {line + 1, 0}}
  end

  @doc """
  Deletes the character before the cursor (backspace).

  At the start of a line, joins the current line with the previous one.
  At `{0, 0}`, no-op.
  """
  @spec delete_backward(t()) :: t()
  def delete_backward(%__MODULE__{cursor: {0, 0}} = tf), do: tf

  def delete_backward(%__MODULE__{cursor: {line, 0}, lines: lines} = tf) do
    prev = Enum.at(lines, line - 1)
    current = Enum.at(lines, line)
    merged = prev <> current
    new_col = String.length(prev)

    new_lines =
      lines
      |> List.replace_at(line - 1, merged)
      |> List.delete_at(line)

    %{tf | lines: new_lines, cursor: {line - 1, new_col}}
  end

  def delete_backward(%__MODULE__{cursor: {line, col}, lines: lines} = tf) do
    current = Enum.at(lines, line)
    {before, after_cursor} = String.split_at(current, col)
    updated = String.slice(before, 0..-2//1) <> after_cursor

    %{tf | lines: List.replace_at(lines, line, updated), cursor: {line, col - 1}}
  end

  @doc """
  Deletes the character at the cursor (delete key).

  At the end of a line, joins with the next line. At the end of the
  last line, no-op.
  """
  @spec delete_forward(t()) :: t()
  def delete_forward(%__MODULE__{cursor: {line, col}, lines: lines} = tf) do
    current = Enum.at(lines, line)

    cond do
      col < String.length(current) ->
        {before, after_cursor} = String.split_at(current, col)
        rest = String.slice(after_cursor, 1..-1//1)
        %{tf | lines: List.replace_at(lines, line, before <> rest)}

      line < length(lines) - 1 ->
        next = Enum.at(lines, line + 1)
        merged = current <> next

        new_lines =
          lines
          |> List.replace_at(line, merged)
          |> List.delete_at(line + 1)

        %{tf | lines: new_lines}

      true ->
        tf
    end
  end

  @doc "Replaces all content and places the cursor at the end."
  @spec set_text(t(), String.t()) :: t()
  def set_text(%__MODULE__{} = _tf, text), do: new(text)

  @doc "Clears all content."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{}), do: new()

  # ── Cursor movement ──────────────────────────────────────────────────────

  @doc """
  Moves the cursor left by one grapheme.

  At the start of a line, wraps to the end of the previous line.
  At `{0, 0}`, no-op.
  """
  @spec move_left(t()) :: t()
  def move_left(%__MODULE__{cursor: {0, 0}} = tf), do: tf

  def move_left(%__MODULE__{cursor: {line, 0}, lines: lines} = tf) do
    prev = Enum.at(lines, line - 1)
    %{tf | cursor: {line - 1, String.length(prev)}}
  end

  def move_left(%__MODULE__{cursor: {line, col}} = tf) do
    %{tf | cursor: {line, col - 1}}
  end

  @doc """
  Moves the cursor right by one grapheme.

  At the end of a line, wraps to the start of the next line.
  At the end of the last line, no-op.
  """
  @spec move_right(t()) :: t()
  def move_right(%__MODULE__{cursor: {line, col}, lines: lines} = tf) do
    current = Enum.at(lines, line)

    cond do
      col < String.length(current) ->
        %{tf | cursor: {line, col + 1}}

      line < length(lines) - 1 ->
        %{tf | cursor: {line + 1, 0}}

      true ->
        tf
    end
  end

  @doc """
  Moves the cursor up one logical line.

  Returns `:at_top` when already on the first line, letting the caller
  decide what to do at the boundary (e.g., browse history).
  """
  @spec move_up(t()) :: t() | :at_top
  def move_up(%__MODULE__{cursor: {0, _}}), do: :at_top

  def move_up(%__MODULE__{cursor: {line, col}, lines: lines} = tf) do
    prev = Enum.at(lines, line - 1)
    new_col = min(col, String.length(prev))
    %{tf | cursor: {line - 1, new_col}}
  end

  @doc """
  Moves the cursor down one logical line.

  Returns `:at_bottom` when already on the last line, letting the caller
  decide what to do at the boundary (e.g., browse history).
  """
  @spec move_down(t()) :: t() | :at_bottom
  def move_down(%__MODULE__{cursor: {line, _}, lines: lines}) when line >= length(lines) - 1 do
    :at_bottom
  end

  def move_down(%__MODULE__{cursor: {line, col}, lines: lines} = tf) do
    next = Enum.at(lines, line + 1)
    new_col = min(col, String.length(next))
    %{tf | cursor: {line + 1, new_col}}
  end

  @doc "Moves the cursor to the start of the current line."
  @spec move_home(t()) :: t()
  def move_home(%__MODULE__{cursor: {line, _}} = tf) do
    %{tf | cursor: {line, 0}}
  end

  @doc "Moves the cursor to the end of the current line."
  @spec move_end(t()) :: t()
  def move_end(%__MODULE__{cursor: {line, _}, lines: lines} = tf) do
    current = Enum.at(lines, line)
    %{tf | cursor: {line, String.length(current)}}
  end

  @doc """
  Sets the cursor position, clamping to valid bounds.
  """
  @spec set_cursor(t(), cursor()) :: t()
  def set_cursor(%__MODULE__{lines: lines} = tf, {line, col}) do
    line = clamp(line, 0, length(lines) - 1)
    col = clamp(col, 0, String.length(Enum.at(lines, line)))
    %{tf | cursor: {line, col}}
  end

  # ── Range operations (for vim operators) ────────────────────────────────

  @doc """
  Returns the text between two positions (inclusive of `from`, exclusive of `to`).

  Positions are `{line, col}` where col is a byte offset. The range is
  extracted from the full content string. Returns an empty string if the
  range is empty or reversed.
  """
  @spec get_range(t(), cursor(), cursor()) :: String.t()
  def get_range(%__MODULE__{} = tf, from, to) do
    {from, to} = sort_positions(from, to)
    text = content(tf)
    from_byte = position_to_byte_offset(tf, from)
    to_byte = position_to_byte_offset(tf, to)
    binary_part(text, from_byte, max(to_byte - from_byte, 0))
  end

  @doc """
  Deletes text between two positions and returns `{updated_tf, deleted_text}`.

  The cursor is placed at the `from` position (or clamped to the end of
  the resulting text if `from` is past the new content).
  """
  @spec delete_range(t(), cursor(), cursor()) :: {t(), String.t()}
  def delete_range(%__MODULE__{} = tf, from, to) do
    {from, to} = sort_positions(from, to)
    text = content(tf)
    from_byte = position_to_byte_offset(tf, from)
    to_byte = position_to_byte_offset(tf, to)
    deleted = binary_part(text, from_byte, max(to_byte - from_byte, 0))

    new_text =
      binary_part(text, 0, from_byte) <> binary_part(text, to_byte, byte_size(text) - to_byte)

    new_tf = new(new_text) |> set_cursor(from)
    {new_tf, deleted}
  end

  @doc """
  Deletes an entire line by index. Returns `{updated_tf, deleted_line_text}`.

  If the buffer has only one line, it is cleared. The cursor moves to
  the same line index (clamped) at column 0.
  """
  @spec delete_line(t(), non_neg_integer()) :: {t(), String.t()}
  def delete_line(%__MODULE__{lines: [only]} = tf, 0) do
    {%{tf | lines: [""], cursor: {0, 0}}, only}
  end

  def delete_line(%__MODULE__{lines: lines} = tf, line_idx)
      when is_integer(line_idx) and line_idx >= 0 and line_idx < length(lines) do
    deleted = Enum.at(lines, line_idx)
    new_lines = List.delete_at(lines, line_idx)
    new_line = min(line_idx, length(new_lines) - 1)
    {%{tf | lines: new_lines, cursor: {new_line, 0}}, deleted}
  end

  def delete_line(%__MODULE__{} = tf, _line_idx), do: {tf, ""}

  @doc """
  Replaces text between two positions with new text.

  The cursor is placed at the end of the inserted text.
  """
  @spec replace_range(t(), cursor(), cursor(), String.t()) :: t()
  def replace_range(%__MODULE__{} = tf, from, to, replacement) do
    {from, to} = sort_positions(from, to)
    text = content(tf)
    from_byte = position_to_byte_offset(tf, from)
    to_byte = position_to_byte_offset(tf, to)

    new_text =
      binary_part(text, 0, from_byte) <>
        replacement <>
        binary_part(text, to_byte, byte_size(text) - to_byte)

    # Place cursor at end of replacement
    replacement_end_byte = from_byte + byte_size(replacement)
    new_tf = new(new_text)
    end_pos = offset_to_position(new_tf, replacement_end_byte)
    set_cursor(new_tf, end_pos)
  end

  # ── Read access (used by Minga.Text.Readable protocol) ──────────────────

  @doc "Returns the full text content as a single string."
  @spec content(t()) :: String.t()
  def content(%__MODULE__{lines: lines}), do: Enum.join(lines, "\n")

  @doc "Returns the line at the given 0-based index, or nil if out of range."
  @spec line_at(t(), non_neg_integer()) :: String.t() | nil
  def line_at(%__MODULE__{lines: lines}, index) when is_integer(index) and index >= 0 do
    Enum.at(lines, index)
  end

  def line_at(%__MODULE__{}, _index), do: nil

  @doc """
  Converts a byte offset from the start of content to a `{line, col}` position.

  Walks through the text byte by byte, incrementing line on newlines.
  """
  @spec offset_to_position(t(), non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  def offset_to_position(%__MODULE__{} = tf, offset) when is_integer(offset) and offset >= 0 do
    do_offset_to_position(content(tf), offset, 0, 0)
  end

  # ── Private ───────────────────────────────────────────────────────────────

  @spec do_offset_to_position(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp do_offset_to_position(_text, 0, line, col), do: {line, col}
  defp do_offset_to_position("", _offset, line, col), do: {line, col}

  defp do_offset_to_position(<<"\n", rest::binary>>, offset, line, _col) do
    do_offset_to_position(rest, offset - 1, line + 1, 0)
  end

  defp do_offset_to_position(<<_byte, rest::binary>>, offset, line, col) do
    do_offset_to_position(rest, offset - 1, line, col + 1)
  end

  @spec clamp(integer(), integer(), integer()) :: integer()
  defp clamp(value, min_val, max_val), do: max(min_val, min(value, max_val))

  @spec sort_positions(cursor(), cursor()) :: {cursor(), cursor()}
  defp sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if l1 < l2 or (l1 == l2 and c1 <= c2), do: {p1, p2}, else: {p2, p1}
  end

  # Converts a {line, col} position to a byte offset into the content string.
  # col is a byte offset within the line.
  @spec position_to_byte_offset(t(), cursor()) :: non_neg_integer()
  defp position_to_byte_offset(%__MODULE__{lines: lines}, {line, col}) do
    # Sum bytes of all lines before `line`, plus 1 for each newline separator
    line_bytes =
      lines
      |> Enum.take(line)
      |> Enum.reduce(0, fn l, acc -> acc + byte_size(l) + 1 end)

    line_bytes + min(col, byte_size(Enum.at(lines, line) || ""))
  end
end

defimpl Minga.Text.Readable, for: Minga.Input.TextField do
  @moduledoc false

  alias Minga.Input.TextField

  def content(tf), do: TextField.content(tf)
  def line_at(tf, n), do: TextField.line_at(tf, n)
  def line_count(tf), do: TextField.line_count(tf)
  def offset_to_position(tf, offset), do: TextField.offset_to_position(tf, offset)
end
