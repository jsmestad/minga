defmodule Minga.Buffer.Document do
  @moduledoc """
  A gap buffer implementation for text editing.

  The gap buffer stores text as two binaries: `before` contains all text
  before the cursor (in natural order), and `after` contains all text
  after the cursor (in natural order). The "gap" is the conceptual space
  between them where insertions happen in O(1).

  Moving the cursor shifts characters between the two binaries. This gives
  O(1) insertions and deletions at the cursor, and O(n) cursor movement
  (where n is the distance moved). For an interactive editor where the
  cursor moves incrementally, this is ideal.

  ## Byte-indexed positions

  All positions are zero-indexed `{line, byte_col}` tuples, where `byte_col`
  is the byte offset within the line. For ASCII content (the common case),
  byte offset equals grapheme index. For multi-byte UTF-8 characters,
  byte offset is larger (e.g., `é` = 2 bytes, emoji = 4+ bytes).

  This representation enables O(1) `binary_part` slicing throughout the
  editor and aligns with tree-sitter's byte-offset model.

  Use `grapheme_col/2` to convert a byte-indexed position to a display
  column for rendering.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello\\nworld")
      iex> Minga.Buffer.Document.cursor(buf)
      {0, 0}
      iex> buf = Minga.Buffer.Document.insert_text(buf, "H")
      iex> Minga.Buffer.Document.content(buf)
      "Hhello\\nworld"
  """

  alias Minga.Buffer.{Cursor, Lines, Position}

  @enforce_keys [:before, :after, :cursor_line, :cursor_col, :line_count]
  defstruct [:before, :after, :cursor_line, :cursor_col, :line_count, :line_offsets]

  @typedoc "Cached line offset tuple, or `nil` when stale."
  @type line_offsets :: tuple() | nil

  @typedoc "A gap buffer instance."
  @type t :: %__MODULE__{
          before: String.t(),
          after: String.t(),
          cursor_line: non_neg_integer(),
          cursor_col: non_neg_integer(),
          line_count: pos_integer(),
          line_offsets: line_offsets()
        }

  @type position :: Position.t()

  @typedoc "A direction for cursor movement."
  @type direction :: :left | :right | :up | :down

  # ── Construction ──

  @doc """
  Creates a new gap buffer from a string. Cursor starts at `{0, 0}`.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello")
      iex> Minga.Buffer.Document.content(buf)
      "hello"
      iex> Minga.Buffer.Document.cursor(buf)
      {0, 0}
  """
  @spec new(String.t()) :: t()
  def new(text \\ "") do
    lc =
      case text do
        "" -> 1
        _ -> Lines.count(text)
      end

    %__MODULE__{before: "", after: text, cursor_line: 0, cursor_col: 0, line_count: lc}
  end

  # ── Queries ──

  @doc "Returns the full text content of the buffer."
  @spec content(t()) :: String.t()
  def content(%__MODULE__{before: before, after: after_}), do: before <> after_

  @doc """
  Returns true if the buffer contains no text.

  ## Examples

      iex> Minga.Buffer.Document.empty?(Minga.Buffer.Document.new(""))
      true
      iex> Minga.Buffer.Document.empty?(Minga.Buffer.Document.new("hi"))
      false
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{before: "", after: ""}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Returns the total number of lines in the buffer.

  An empty buffer counts as one line.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("one\\ntwo\\nthree")
      iex> Minga.Buffer.Document.line_count(buf)
      3
      iex> Minga.Buffer.Document.line_count(Minga.Buffer.Document.new(""))
      1
  """
  @spec line_count(t()) :: pos_integer()
  def line_count(%__MODULE__{line_count: lc}), do: lc

  @doc "Returns the current cursor position as a `{line, byte_col}` tuple."
  @spec cursor(t()) :: position()
  def cursor(%__MODULE__{cursor_line: line, cursor_col: col}), do: {line, col}

  @doc "Returns the byte offset of the cursor in the full text."
  @spec cursor_offset(t()) :: non_neg_integer()
  def cursor_offset(%__MODULE__{before: before}), do: byte_size(before)

  # ── Mutations ──

  @doc """
  Inserts a multi-character string at the cursor position in a single
  binary operation. 

  ## Examples

      iex> buf = Minga.Buffer.Document.new("world")
      iex> buf = Minga.Buffer.Document.insert_text(buf, "hello ")
      iex> Minga.Buffer.Document.content(buf)
      "hello world"

      iex> buf = Minga.Buffer.Document.new("end")
      iex> buf = Minga.Buffer.Document.insert_text(buf, "line1\\nline2\\n")
      iex> Minga.Buffer.Document.content(buf)
      "line1\\nline2\\nend"
      iex> Minga.Buffer.Document.cursor(buf)
      {2, 0}
  """
  @spec insert_text(t(), String.t()) :: t()
  def insert_text(%__MODULE__{} = buf, ""), do: buf

  def insert_text(
        %__MODULE__{
          before: before,
          # after: after_,
          cursor_line: line,
          cursor_col: col,
          line_count: lc
        } = mod,
        text
      ) do
    {new_line, new_col, new_lc} = compute_cursor_after_insert(line, col, lc, text)

    %{
      mod
      | before: before <> text,
        cursor_line: new_line,
        cursor_col: new_col,
        line_count: new_lc
    }
  end

  @doc """
  Deletes the character before the cursor (backspace).
  Returns the buffer unchanged if the cursor is at the beginning.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello")
      iex> buf = Minga.Buffer.Document.move_to(buf, {0, 5})
      iex> buf = Minga.Buffer.Document.delete_before(buf)
      iex> Minga.Buffer.Document.content(buf)
      "hell"
  """
  @spec delete_before(t()) :: t()
  def delete_before(%__MODULE__{before: ""} = buf), do: buf

  def delete_before(
        %__MODULE__{before: before, cursor_line: line, cursor_col: _col, line_count: lc} = buf
      ) do
    {new_before, removed} = Cursor.previous_character(before)

    {new_line, new_col, new_lc} =
      case removed do
        "\n" -> {line - 1, Lines.last_line_width(new_before), lc - 1}
        _ -> {line, Lines.last_line_width(new_before), lc}
      end

    %{buf | before: new_before, cursor_line: new_line, cursor_col: new_col, line_count: new_lc}
  end

  @doc """
  Deletes the character at the cursor (delete forward).
  Returns the buffer unchanged if the cursor is at the end.
  """
  @spec delete_at(t()) :: t()
  def delete_at(%__MODULE__{after: ""} = buf), do: buf

  def delete_at(%__MODULE__{after: after_, line_count: lc} = buf) do
    case Cursor.next_character(after_) do
      {"\n", rest} -> %{buf | after: rest, line_count: lc - 1}
      {_grapheme, rest} -> %{buf | after: rest}
      nil -> buf
    end
  end

  # ── Range operations ──

  @doc """
  Returns the text between two positions **inclusive** on both ends.
  If the positions are reversed, they are normalised automatically.
  """
  @spec content_range(t(), position(), position()) :: String.t()
  def content_range(%__MODULE__{} = buf, from_pos, to_pos) do
    {offsets, text} = Lines.snapshot(buf)
    text_size = byte_size(text)

    from_off =
      Position.point_in(offsets, elem(from_pos, 0), elem(from_pos, 1), text_size)

    to_off = Position.point_in(offsets, elem(to_pos, 0), elem(to_pos, 1), text_size)
    {start_off, end_off} = if from_off <= to_off, do: {from_off, to_off}, else: {to_off, from_off}

    range_end = Position.after_character_at(text, end_off)

    binary_part(text, start_off, range_end - start_off)
  end

  @doc """
  Deletes the text between two positions **inclusive** on both ends.
  If the positions are reversed, they are normalised automatically.
  The cursor is placed at the earlier position.
  """
  @spec delete_range(t(), position(), position()) :: t()
  def delete_range(%__MODULE__{} = buf, from_pos, to_pos) do
    {offsets, text} = Lines.snapshot(buf)
    text_size = byte_size(text)

    from_off =
      Position.point_in(offsets, elem(from_pos, 0), elem(from_pos, 1), text_size)

    to_off = Position.point_in(offsets, elem(to_pos, 0), elem(to_pos, 1), text_size)

    {start_off, end_off, cursor_pos} =
      if from_off <= to_off,
        do: {from_off, to_off, from_pos},
        else: {to_off, from_off, to_pos}

    delete_end = Position.after_character_at(text, end_off)

    before_text = binary_part(text, 0, start_off)
    after_text = binary_part(text, delete_end, text_size - delete_end)
    new_text = before_text <> after_text
    move_to(new(new_text), cursor_pos)
  end

  @doc """
  Returns the text in the range [start_pos, end_pos] inclusive (characterwise).

  Positions are clamped to valid buffer bounds. If start_pos is after end_pos,
  the positions are swapped automatically.
  """
  @spec get_range(t(), position(), position()) :: String.t()
  def get_range(%__MODULE__{} = buf, start_pos, end_pos) do
    {offsets, text} = Lines.snapshot(buf)
    text_size = byte_size(text)

    {s, e} = sort_positions(start_pos, end_pos)
    s_off = Position.point_in(offsets, elem(s, 0), elem(s, 1), text_size)
    e_off = Position.point_in(offsets, elem(e, 0), elem(e, 1), text_size)

    range_end = Position.after_character_at(text, e_off)

    binary_part(text, s_off, range_end - s_off)
  end

  @doc """
  Returns the joined text of lines [start_line, end_line] inclusive, with
  newlines between them (no trailing newline).
  """
  @spec get_lines_content(t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def get_lines_content(%__MODULE__{} = buf, start_line, end_line)
      when start_line >= 0 and end_line >= 0 do
    {s, e} = if start_line <= end_line, do: {start_line, end_line}, else: {end_line, start_line}
    count = e - s + 1
    Lines.slice(buf, s, count) |> Enum.join("\n")
  end

  @doc """
  Deletes lines [start_line, end_line] inclusive from the buffer.

  The cursor is placed at the beginning of the line that now occupies
  the start position (or the last remaining line if fewer lines remain).
  """
  @spec delete_lines(t(), non_neg_integer(), non_neg_integer()) :: t()
  def delete_lines(%__MODULE__{} = buf, start_line, end_line)
      when start_line >= 0 and end_line >= 0 do
    {offsets, text} = Lines.snapshot(buf)
    text_size = byte_size(text)
    total_lines = tuple_size(offsets)

    {s, e} = if start_line <= end_line, do: {start_line, end_line}, else: {end_line, start_line}
    s = min(s, total_lines - 1)
    e = min(e, total_lines - 1)

    # Compute byte range to delete: from start of line s to start of line e+1
    # (or end of text if e is the last line)
    delete_start = elem(offsets, s)

    delete_end =
      if e + 1 < total_lines do
        elem(offsets, e + 1)
      else
        text_size
      end

    before_text = binary_part(text, 0, delete_start)
    after_text = binary_part(text, delete_end, text_size - delete_end)

    new_text =
      case {before_text, after_text} do
        {"", ""} -> ""
        # If before_text ends with \n and we're joining with after_text,
        # the newline separates them correctly
        _ -> before_text <> after_text
      end

    # Remove trailing newline if we deleted through the end and before_text has one
    new_text =
      if delete_end == text_size and byte_size(new_text) > 0 and
           :binary.last(new_text) == ?\n do
        binary_part(new_text, 0, byte_size(new_text) - 1)
      else
        new_text
      end

    remaining_lines = total_lines - (e - s + 1)
    target_line = min(s, max(0, remaining_lines - 1))
    new_text |> new() |> move_to({target_line, 0})
  end

  @doc """
  Clears all content on the given line, leaving an empty line.
  Returns `{yanked_text, new_buffer}` where `yanked_text` is the text
  that was on the line. The cursor is placed at column 0 of the line.
  """
  @spec clear_line(t(), non_neg_integer()) :: {String.t(), t()}
  def clear_line(%__MODULE__{} = buf, line_num) when line_num >= 0 do
    case Lines.fetch(buf, line_num) do
      nil ->
        {"", buf}

      "" ->
        {"", move_to(buf, {line_num, 0})}

      text ->
        start_pos = {line_num, 0}
        end_pos = {line_num, Position.last_character_on_line(text)}
        new_buf = delete_range(buf, start_pos, end_pos)
        {text, new_buf}
    end
  end

  @doc """
  Returns the content and cursor position in a single call,
  avoiding separate content/1 + cursor/1 round-trips.
  """
  @spec content_and_cursor(t()) :: {String.t(), position()}
  def content_and_cursor(%__MODULE__{
        before: before,
        after: after_,
        cursor_line: line,
        cursor_col: col
      }) do
    {before <> after_, {line, col}}
  end

  # ── Private helpers ──

  # Computes new cursor position and line_count after inserting `text` at the current cursor.
  # Uses byte_size for column tracking.
  @spec compute_cursor_after_insert(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          String.t()
        ) :: {non_neg_integer(), non_neg_integer(), pos_integer()}
  defp compute_cursor_after_insert(line, col, lc, text) do
    newline_count = Lines.break_count(text)

    case newline_count do
      0 ->
        {line, col + byte_size(text), lc}

      _ ->
        {line + newline_count, Lines.last_line_width(text), lc + newline_count}
    end
  end

  @spec sort_positions(position(), position()) :: {position(), position()}
  defp sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if {l1, c1} <= {l2, c2}, do: {p1, p2}, else: {p2, p1}
  end

  @doc "Returns the position of the last selectable character on a line."
  @spec last_grapheme_byte_offset(String.t()) :: non_neg_integer()
  defdelegate last_grapheme_byte_offset(text), to: Position, as: :last_character_on_line

  defdelegate line_at(buf, line_num), to: Lines, as: :fetch
  defdelegate lines(buf, start, count), to: Lines, as: :slice

  defdelegate move(buf, direction), to: Cursor, as: :step
  defdelegate move_to(buf, target), to: Cursor, as: :place

  defdelegate position_to_offset(buf, target), to: Position, as: :point_for
  defdelegate offset_to_position(doc, offset), to: Position, as: :from_point
  defdelegate grapheme_col(buf, value), to: Position, as: :display_column
end

defimpl Minga.Editing.Text.Readable, for: Minga.Buffer.Document do
  @moduledoc false

  alias Minga.Buffer.Document
  alias Minga.Buffer.Lines

  def content(doc), do: Document.content(doc)
  def line_at(doc, n), do: Lines.fetch(doc, n)
  def line_count(doc), do: Document.line_count(doc)
  def offset_to_position(doc, offset), do: Document.offset_to_position(doc, offset)
end
