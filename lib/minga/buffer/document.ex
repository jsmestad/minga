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
      iex> buf = Minga.Buffer.Document.insert_char(buf, "H")
      iex> Minga.Buffer.Document.content(buf)
      "Hhello\\nworld"
  """

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

  @typedoc """
  A zero-indexed `{line, byte_col}` position in the buffer.

  `byte_col` is the byte offset within the line's UTF-8 binary.
  For ASCII text, this equals the character/grapheme index.
  """
  @type position :: {line :: non_neg_integer(), byte_col :: non_neg_integer()}

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
  def new(text \\ "") when is_binary(text) do
    lc =
      case text do
        "" -> 1
        _ -> count_newlines(text) + 1
      end

    %__MODULE__{before: "", after: text, cursor_line: 0, cursor_col: 0, line_count: lc}
  end

  # ── Queries ──

  @doc "Returns the full text content of the buffer."
  @spec content(t()) :: String.t()
  def content(%__MODULE__{before: before, after: after_}) do
    before <> after_
  end

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

  @doc """
  Returns the text of a specific line (zero-indexed), without the trailing newline.
  Returns `nil` if the line number is out of range.
  """
  @spec line_at(t(), non_neg_integer()) :: String.t() | nil
  def line_at(%__MODULE__{} = buf, line_num) when is_integer(line_num) and line_num >= 0 do
    {offsets, text} = ensure_line_offsets(buf)

    case line_byte_range(offsets, line_num, byte_size(text)) do
      nil -> nil
      {start, len} -> binary_part(text, start, len)
    end
  end

  @doc """
  Returns a range of lines (zero-indexed, inclusive start, exclusive end).
  """
  @spec lines(t(), non_neg_integer(), non_neg_integer()) :: [String.t()]
  def lines(%__MODULE__{} = buf, start, count)
      when is_integer(start) and start >= 0 and is_integer(count) and count >= 0 do
    {offsets, text} = ensure_line_offsets(buf)
    text_size = byte_size(text)
    max_line = tuple_size(offsets) - 1
    last = min(start + count - 1, max_line)

    if start > max_line do
      []
    else
      for line_num <- start..last do
        {s, len} = line_byte_range(offsets, line_num, text_size)
        binary_part(text, s, len)
      end
    end
  end

  @doc "Returns the current cursor position as a `{line, byte_col}` tuple."
  @spec cursor(t()) :: position()
  def cursor(%__MODULE__{cursor_line: line, cursor_col: col}), do: {line, col}

  @doc "Returns the byte offset of the cursor in the full text."
  @spec cursor_offset(t()) :: non_neg_integer()
  def cursor_offset(%__MODULE__{before: before}) do
    byte_size(before)
  end

  @doc """
  Returns the byte offset of a `{line, byte_col}` position in the buffer content.
  """
  @spec position_to_offset(t(), position()) :: non_neg_integer()
  def position_to_offset(%__MODULE__{} = buf, {line, col})
      when is_integer(line) and line >= 0 and is_integer(col) and col >= 0 do
    {offsets, text} = ensure_line_offsets(buf)
    offset_for_position(offsets, line, col, byte_size(text))
  end

  @doc """
  Converts a byte offset in the buffer content to a `{line, byte_col}` position.
  Clamps to valid bounds.
  """
  @spec offset_to_position(t(), non_neg_integer()) :: position()
  def offset_to_position(%__MODULE__{} = buf, offset) when is_integer(offset) and offset >= 0 do
    text = content(buf)
    do_offset_to_position(text, offset, 0, 0)
  end

  @doc """
  Converts a `{line, byte_col}` position to a grapheme (display) column.

  Counts graphemes in the line text from byte 0 to `byte_col`.
  Used by the renderer to convert byte positions to screen columns.
  """
  @spec grapheme_col(t(), position()) :: non_neg_integer()
  def grapheme_col(%__MODULE__{} = buf, {line, byte_col}) do
    case line_at(buf, line) do
      nil -> 0
      text -> grapheme_count_in_bytes(text, byte_col)
    end
  end

  @doc """
  Converts a grapheme column to a byte column for the given line.

  Walks graphemes until `grapheme_index` graphemes have been counted,
  returning the byte offset at that point. Used by motions that need
  to reason about character positions.
  """
  @spec byte_col_for_grapheme(String.t(), non_neg_integer()) :: non_neg_integer()
  def byte_col_for_grapheme(line_text, grapheme_index)
      when is_binary(line_text) and is_integer(grapheme_index) and grapheme_index >= 0 do
    do_byte_col_for_grapheme(line_text, grapheme_index, 0)
  end

  # ── Mutations ──

  @doc """
  Inserts a character (or string) at the cursor position.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("world")
      iex> buf = Minga.Buffer.Document.insert_char(buf, "hello ")
      iex> Minga.Buffer.Document.content(buf)
      "hello world"
  """
  @spec insert_char(t(), String.t()) :: t()
  def insert_char(
        %__MODULE__{
          before: before,
          after: after_,
          cursor_line: line,
          cursor_col: col,
          line_count: lc
        } = _buf,
        char
      )
      when is_binary(char) do
    {new_line, new_col, new_lc} = compute_cursor_after_insert(line, col, lc, char)

    %__MODULE__{
      before: before <> char,
      after: after_,
      cursor_line: new_line,
      cursor_col: new_col,
      line_count: new_lc
    }
  end

  @doc """
  Inserts a multi-character string at the cursor position in a single
  binary operation. Use this instead of decomposing into graphemes and
  calling `insert_char/2` in a loop; that pattern is O(n²) on the gap
  buffer's binary.

  Functionally equivalent to `insert_char/2` (which already accepts
  arbitrary strings), but exists as a separate entry point so the intent
  is clear and `Buffer.Server` can route bulk inserts here directly.

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
  def insert_text(%__MODULE__{} = buf, text) when is_binary(text), do: insert_char(buf, text)

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
    {new_before, removed} = pop_last_grapheme(before)

    {new_line, new_col, new_lc} =
      case removed do
        "\n" -> {line - 1, byte_col_in_last_line(new_before), lc - 1}
        _ -> {line, byte_size(new_before) - byte_offset_of_last_newline(new_before), lc}
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
    case String.next_grapheme(after_) do
      {"\n", rest} -> %{buf | after: rest, line_count: lc - 1}
      {_grapheme, rest} -> %{buf | after: rest}
      nil -> buf
    end
  end

  # ── Movement ──

  @doc "Moves the cursor one step in the given direction."
  @spec move(t(), direction()) :: t()
  def move(%__MODULE__{} = buf, :left), do: move_left(buf)
  def move(%__MODULE__{} = buf, :right), do: move_right(buf)
  def move(%__MODULE__{} = buf, :up), do: move_up(buf)
  def move(%__MODULE__{} = buf, :down), do: move_down(buf)

  @doc """
  Moves the cursor to an exact `{line, byte_col}` position.

  Line and column are clamped to valid buffer bounds.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello\\nworld")
      iex> buf = Minga.Buffer.Document.move_to(buf, {1, 3})
      iex> Minga.Buffer.Document.cursor(buf)
      {1, 3}
  """
  @spec move_to(t(), position()) :: t()
  def move_to(%__MODULE__{} = buf, {target_line, target_col})
      when is_integer(target_line) and target_line >= 0 and
             is_integer(target_col) and target_col >= 0 do
    {offsets, text} = ensure_line_offsets(buf)
    text_size = byte_size(text)

    # Clamp line to valid range
    max_line = tuple_size(offsets) - 1
    line = min(target_line, max_line)

    # Get line text via index for column clamping
    {line_start, line_len} = line_byte_range(offsets, line, text_size)
    line_text = binary_part(text, line_start, line_len)
    col = min(target_col, line_len)

    # Clamp to grapheme boundary (don't land in the middle of a multi-byte char)
    col = clamp_to_grapheme_boundary(line_text, col)

    # Calculate byte offset from line start offset + col
    byte_off = line_start + col

    # Split at byte position (O(1) binary_part)
    before = binary_part(text, 0, byte_off)
    after_ = binary_part(text, byte_off, text_size - byte_off)

    %{buf | before: before, after: after_, cursor_line: line, cursor_col: col, line_offsets: nil}
  end

  # ── Range operations ──

  @doc """
  Returns the text between two positions **inclusive** on both ends.
  If the positions are reversed, they are normalised automatically.
  """
  @spec content_range(t(), position(), position()) :: String.t()
  def content_range(%__MODULE__{} = buf, from_pos, to_pos) do
    {offsets, text} = ensure_line_offsets(buf)
    text_size = byte_size(text)
    from_off = offset_for_position(offsets, elem(from_pos, 0), elem(from_pos, 1), text_size)
    to_off = offset_for_position(offsets, elem(to_pos, 0), elem(to_pos, 1), text_size)
    {start_off, end_off} = if from_off <= to_off, do: {from_off, to_off}, else: {to_off, from_off}

    # end_off points to the start of the last character. Find its byte length.
    remaining = binary_part(text, end_off, text_size - end_off)
    char_len = next_grapheme_byte_size(remaining)
    extract_len = min(end_off - start_off + char_len, text_size - start_off)

    binary_part(text, start_off, extract_len)
  end

  @doc """
  Deletes the text between two positions **inclusive** on both ends.
  If the positions are reversed, they are normalised automatically.
  The cursor is placed at the earlier position.
  """
  @spec delete_range(t(), position(), position()) :: t()
  def delete_range(%__MODULE__{} = buf, from_pos, to_pos) do
    {offsets, text} = ensure_line_offsets(buf)
    text_size = byte_size(text)
    from_off = offset_for_position(offsets, elem(from_pos, 0), elem(from_pos, 1), text_size)
    to_off = offset_for_position(offsets, elem(to_pos, 0), elem(to_pos, 1), text_size)

    {start_off, end_off, cursor_pos} =
      if from_off <= to_off,
        do: {from_off, to_off, from_pos},
        else: {to_off, from_off, to_pos}

    # end_off points to the start of the last character. Find its byte length.
    remaining = binary_part(text, end_off, text_size - end_off)
    char_len = next_grapheme_byte_size(remaining)
    delete_end = min(end_off + char_len, text_size)

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
    {offsets, text} = ensure_line_offsets(buf)
    text_size = byte_size(text)

    {s, e} = sort_positions(start_pos, end_pos)
    s_off = offset_for_position(offsets, elem(s, 0), elem(s, 1), text_size)
    e_off = offset_for_position(offsets, elem(e, 0), elem(e, 1), text_size)

    # e_off points to the start of the last character. Find its byte length.
    remaining = binary_part(text, e_off, text_size - e_off)
    char_len = next_grapheme_byte_size(remaining)
    extract_len = min(e_off - s_off + char_len, text_size - s_off)

    binary_part(text, s_off, extract_len)
  end

  @doc """
  Returns the joined text of lines [start_line, end_line] inclusive, with
  newlines between them (no trailing newline).
  """
  @spec get_lines_content(t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def get_lines_content(%__MODULE__{} = buf, start_line, end_line)
      when is_integer(start_line) and start_line >= 0 and
             is_integer(end_line) and end_line >= 0 do
    {s, e} = if start_line <= end_line, do: {start_line, end_line}, else: {end_line, start_line}
    count = e - s + 1
    lines(buf, s, count) |> Enum.join("\n")
  end

  @doc """
  Deletes lines [start_line, end_line] inclusive from the buffer.

  The cursor is placed at the beginning of the line that now occupies
  the start position (or the last remaining line if fewer lines remain).
  """
  @spec delete_lines(t(), non_neg_integer(), non_neg_integer()) :: t()
  def delete_lines(%__MODULE__{} = buf, start_line, end_line)
      when is_integer(start_line) and start_line >= 0 and
             is_integer(end_line) and end_line >= 0 do
    {offsets, text} = ensure_line_offsets(buf)
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
  def clear_line(%__MODULE__{} = buf, line_num) when is_integer(line_num) and line_num >= 0 do
    case line_at(buf, line_num) do
      nil ->
        {"", buf}

      "" ->
        {"", move_to(buf, {line_num, 0})}

      text ->
        start_pos = {line_num, 0}
        end_pos = {line_num, last_grapheme_byte_offset(text)}
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

  # ── Byte/grapheme conversion utilities ──

  @doc """
  Returns the byte offset of the first byte of the last grapheme in `text`.
  Returns 0 for empty strings.
  """
  @spec last_grapheme_byte_offset(String.t()) :: non_neg_integer()
  def last_grapheme_byte_offset(""), do: 0

  def last_grapheme_byte_offset(text) when is_binary(text) do
    {offset, _size} = find_last_grapheme_offset(text, 0)
    offset
  end

  # ── Private helpers ──

  # ── Line index helpers ──

  # Lazily computes line offsets if the cache is stale. Returns the offset
  # tuple and the materialized content binary so callers avoid a second
  # `content()` call. Uses `:binary.matches/2` (Boyer-Moore in C) for a
  # single-pass newline scan.
  @spec ensure_line_offsets(t()) :: {tuple(), String.t()}
  defp ensure_line_offsets(%__MODULE__{line_offsets: offsets} = buf) when is_tuple(offsets) do
    {offsets, content(buf)}
  end

  defp ensure_line_offsets(%__MODULE__{} = buf) do
    text = content(buf)
    offsets = build_line_offsets(text)
    {offsets, text}
  end

  # Builds a tuple of byte offsets marking the start of each line.
  # Line 0 always starts at offset 0. Each subsequent line starts one byte
  # after a newline character.
  @spec build_line_offsets(String.t()) :: tuple()
  defp build_line_offsets(text) do
    newline_positions = :binary.matches(text, "\n")

    [0 | Enum.map(newline_positions, fn {pos, _len} -> pos + 1 end)]
    |> List.to_tuple()
  end

  # Returns the byte range {start_offset, byte_length} for a given line
  # number, using the line offset tuple and the total content size.
  # Returns `nil` if the line is out of range.
  @spec line_byte_range(tuple(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp line_byte_range(offsets, line_num, text_size) do
    max_line = tuple_size(offsets) - 1

    cond do
      line_num > max_line ->
        nil

      line_num == max_line ->
        start = elem(offsets, line_num)
        {start, text_size - start}

      true ->
        start = elem(offsets, line_num)
        # Next line starts at elem(offsets, line_num + 1); subtract 1 for the newline
        next_start = elem(offsets, line_num + 1)
        {start, next_start - start - 1}
    end
  end

  # ── Movement helpers ──

  @spec move_left(t()) :: t()
  defp move_left(%__MODULE__{before: ""} = buf), do: buf

  defp move_left(%__MODULE__{before: before, after: after_, cursor_line: line} = buf) do
    {new_before, char} = pop_last_grapheme(before)

    {new_line, new_col} =
      case char do
        "\n" -> {line - 1, byte_col_in_last_line(new_before)}
        _ -> {line, byte_size(new_before) - byte_offset_of_last_newline(new_before)}
      end

    %{buf | before: new_before, after: char <> after_, cursor_line: new_line, cursor_col: new_col}
  end

  @spec move_right(t()) :: t()
  defp move_right(%__MODULE__{after: ""} = buf), do: buf

  defp move_right(
         %__MODULE__{before: before, after: after_, cursor_line: line, cursor_col: col} = buf
       ) do
    case String.next_grapheme(after_) do
      {"\n", rest} ->
        %{buf | before: before <> "\n", after: rest, cursor_line: line + 1, cursor_col: 0}

      {grapheme, rest} ->
        %{buf | before: before <> grapheme, after: rest, cursor_col: col + byte_size(grapheme)}

      nil ->
        buf
    end
  end

  @spec move_up(t()) :: t()
  defp move_up(%__MODULE__{cursor_line: 0} = buf), do: buf

  defp move_up(%__MODULE__{cursor_line: line, cursor_col: col} = buf) do
    move_to(buf, {line - 1, col})
  end

  @spec move_down(t()) :: t()
  defp move_down(%__MODULE__{cursor_line: line, line_count: lc} = buf) when line >= lc - 1,
    do: buf

  defp move_down(%__MODULE__{cursor_line: line, cursor_col: col} = buf) do
    move_to(buf, {line + 1, col})
  end

  # Computes new cursor position and line_count after inserting `text` at the current cursor.
  # Uses byte_size for column tracking.
  @spec compute_cursor_after_insert(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          String.t()
        ) :: {non_neg_integer(), non_neg_integer(), pos_integer()}
  defp compute_cursor_after_insert(line, col, lc, text) do
    newline_count = count_newlines(text)

    case newline_count do
      0 ->
        {line, col + byte_size(text), lc}

      _ ->
        # Find byte_size of content after the last newline
        matches = :binary.matches(text, "\n")
        {last_newline_pos, _len} = List.last(matches)
        last_line_bytes = byte_size(text) - last_newline_pos - 1
        {line + newline_count, last_line_bytes, lc + newline_count}
    end
  end

  # Returns the byte column of the position after the last `\n` in `str`,
  # i.e. the byte offset within the current line if the cursor were at the end of `str`.
  @spec byte_col_in_last_line(String.t()) :: non_neg_integer()
  defp byte_col_in_last_line(""), do: 0

  defp byte_col_in_last_line(str) do
    byte_size(str) - byte_offset_of_last_newline(str)
  end

  # Returns the byte offset just past the last `\n` in `str`, or 0 if no newline.
  @spec byte_offset_of_last_newline(String.t()) :: non_neg_integer()
  defp byte_offset_of_last_newline(str) do
    case :binary.matches(str, "\n") do
      [] -> 0
      matches -> elem(List.last(matches), 0) + 1
    end
  end

  # Splits off the last grapheme from a string, preserving exact binary representation.
  # Returns {rest, last_grapheme}.
  @spec pop_last_grapheme(String.t()) :: {String.t(), String.t()}
  defp pop_last_grapheme(str) do
    byte_len = byte_size(str)
    # Walk forward with next_grapheme to find where the last grapheme starts
    {last_start, _} = find_last_grapheme_offset(str, 0)
    rest = binary_part(str, 0, last_start)
    last = binary_part(str, last_start, byte_len - last_start)
    {rest, last}
  end

  # Walks the string grapheme by grapheme, tracking the byte offset
  # of the start of the last grapheme.
  @spec find_last_grapheme_offset(String.t(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp find_last_grapheme_offset(str, current_offset) do
    case String.next_grapheme_size(str) do
      {size, ""} ->
        # This is the last grapheme
        {current_offset, size}

      {size, rest} ->
        find_last_grapheme_offset(rest, current_offset + size)

      nil ->
        {current_offset, 0}
    end
  end

  # Converts a byte offset to {line, byte_col} by scanning for newlines.
  @spec do_offset_to_position(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          position()
  defp do_offset_to_position(_text, 0, line, col), do: {line, col}
  defp do_offset_to_position("", _offset, line, col), do: {line, col}

  defp do_offset_to_position(text, offset, line, col) when offset > 0 do
    case text do
      <<"\n", rest::binary>> ->
        do_offset_to_position(rest, offset - 1, line + 1, 0)

      <<_byte, rest::binary>> ->
        do_offset_to_position(rest, offset - 1, line, col + 1)
    end
  end

  @spec sort_positions(position(), position()) :: {position(), position()}
  defp sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if {l1, c1} <= {l2, c2}, do: {p1, p2}, else: {p2, p1}
  end

  @spec count_newlines(String.t()) :: non_neg_integer()
  defp count_newlines(str) do
    length(:binary.matches(str, "\n"))
  end

  # Computes the byte offset from start of text for a {line, byte_col} position
  # using the line offset tuple. O(1) lookup instead of O(lines) iteration.
  @spec offset_for_position(tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp offset_for_position(offsets, line, col, text_size) do
    max_line = tuple_size(offsets) - 1
    clamped_line = min(line, max_line)
    offset = elem(offsets, clamped_line) + col
    min(offset, text_size)
  end

  # Returns the byte size of the next grapheme in `text`, or 0 for empty.
  @spec next_grapheme_byte_size(String.t()) :: non_neg_integer()
  defp next_grapheme_byte_size(""), do: 0

  defp next_grapheme_byte_size(text) do
    case String.next_grapheme_size(text) do
      {size, _rest} -> size
      nil -> 0
    end
  end

  # Clamp a byte offset to the nearest grapheme boundary (don't land mid-character).
  @spec clamp_to_grapheme_boundary(String.t(), non_neg_integer()) :: non_neg_integer()
  defp clamp_to_grapheme_boundary(_text, 0), do: 0

  defp clamp_to_grapheme_boundary(text, target_byte) when target_byte >= byte_size(text) do
    byte_size(text)
  end

  defp clamp_to_grapheme_boundary(text, target_byte) do
    do_clamp_to_grapheme_boundary(text, target_byte, 0)
  end

  @spec do_clamp_to_grapheme_boundary(String.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_clamp_to_grapheme_boundary(text, target_byte, current_byte) do
    case String.next_grapheme_size(text) do
      {size, _rest} when current_byte + size > target_byte ->
        # The next grapheme would overshoot — stay at current_byte
        current_byte

      {size, rest} ->
        do_clamp_to_grapheme_boundary(rest, target_byte, current_byte + size)

      nil ->
        current_byte
    end
  end

  # Count graphemes in the first `byte_count` bytes of `text`.
  @spec grapheme_count_in_bytes(String.t(), non_neg_integer()) :: non_neg_integer()
  defp grapheme_count_in_bytes(_text, 0), do: 0

  defp grapheme_count_in_bytes(text, byte_count) do
    do_grapheme_count_in_bytes(text, byte_count, 0, 0)
  end

  @spec do_grapheme_count_in_bytes(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          non_neg_integer()
  defp do_grapheme_count_in_bytes(_text, byte_count, bytes_seen, grapheme_count)
       when bytes_seen >= byte_count do
    grapheme_count
  end

  defp do_grapheme_count_in_bytes(text, byte_count, bytes_seen, grapheme_count) do
    case String.next_grapheme_size(text) do
      {size, rest} ->
        do_grapheme_count_in_bytes(rest, byte_count, bytes_seen + size, grapheme_count + 1)

      nil ->
        grapheme_count
    end
  end

  # Convert grapheme index to byte offset within a line.
  @spec do_byte_col_for_grapheme(String.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_byte_col_for_grapheme(_text, 0, byte_offset), do: byte_offset

  defp do_byte_col_for_grapheme(text, remaining, byte_offset) do
    case String.next_grapheme_size(text) do
      {size, rest} ->
        do_byte_col_for_grapheme(rest, remaining - 1, byte_offset + size)

      nil ->
        byte_offset
    end
  end
end

defimpl Minga.Text.Readable, for: Minga.Buffer.Document do
  @moduledoc false

  alias Minga.Buffer.Document

  def content(doc), do: Document.content(doc)
  def line_at(doc, n), do: Document.line_at(doc, n)
  def line_count(doc), do: Document.line_count(doc)
  def offset_to_position(doc, offset), do: Document.offset_to_position(doc, offset)
end
