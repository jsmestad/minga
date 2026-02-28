defmodule Minga.Buffer.GapBuffer do
  @moduledoc """
  A gap buffer implementation for text editing.

  The gap buffer stores text as two binaries: `before` contains all text
  before the cursor (in natural order), and `after_` contains all text
  after the cursor (in natural order). The "gap" is the conceptual space
  between them where insertions happen in O(1).

  Moving the cursor shifts characters between the two binaries. This gives
  O(1) insertions and deletions at the cursor, and O(n) cursor movement
  (where n is the distance moved). For an interactive editor where the
  cursor moves incrementally, this is ideal.

  All positions are zero-indexed `{line, col}` tuples.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello\\nworld")
      iex> Minga.Buffer.GapBuffer.cursor(buf)
      {0, 0}
      iex> buf = Minga.Buffer.GapBuffer.insert_char(buf, "H")
      iex> Minga.Buffer.GapBuffer.content(buf)
      "Hhello\\nworld"
  """

  @enforce_keys [:before, :after]
  defstruct [:before, :after]

  @typedoc "A gap buffer instance."
  @type t :: %__MODULE__{
          before: String.t(),
          after: String.t()
        }

  @typedoc "A zero-indexed {line, col} position in the buffer."
  @type position :: {line :: non_neg_integer(), col :: non_neg_integer()}

  @typedoc "A direction for cursor movement."
  @type direction :: :left | :right | :up | :down

  # ── Construction ──

  @doc """
  Creates a new gap buffer from a string. Cursor starts at `{0, 0}`.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello")
      iex> Minga.Buffer.GapBuffer.content(buf)
      "hello"
      iex> Minga.Buffer.GapBuffer.cursor(buf)
      {0, 0}
  """
  @spec new(String.t()) :: t()
  def new(text \\ "") when is_binary(text) do
    %__MODULE__{before: "", after: text}
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

      iex> Minga.Buffer.GapBuffer.empty?(Minga.Buffer.GapBuffer.new(""))
      true
      iex> Minga.Buffer.GapBuffer.empty?(Minga.Buffer.GapBuffer.new("hi"))
      false
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{before: "", after: ""}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Returns the total number of lines in the buffer.

  An empty buffer counts as one line.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("one\\ntwo\\nthree")
      iex> Minga.Buffer.GapBuffer.line_count(buf)
      3
      iex> Minga.Buffer.GapBuffer.line_count(Minga.Buffer.GapBuffer.new(""))
      1
  """
  @spec line_count(t()) :: pos_integer()
  def line_count(%__MODULE__{} = buf) do
    text = content(buf)

    case text do
      "" -> 1
      _ -> count_newlines(text) + 1
    end
  end

  @doc """
  Returns the text of a specific line (zero-indexed), without the trailing newline.
  Returns `nil` if the line number is out of range.
  """
  @spec line_at(t(), non_neg_integer()) :: String.t() | nil
  def line_at(%__MODULE__{} = buf, line_num) when is_integer(line_num) and line_num >= 0 do
    buf
    |> content()
    |> String.split("\n")
    |> Enum.at(line_num)
  end

  @doc """
  Returns a range of lines (zero-indexed, inclusive start, exclusive end).
  """
  @spec lines(t(), non_neg_integer(), non_neg_integer()) :: [String.t()]
  def lines(%__MODULE__{} = buf, start, count)
      when is_integer(start) and start >= 0 and is_integer(count) and count >= 0 do
    buf
    |> content()
    |> String.split("\n")
    |> Enum.slice(start, count)
  end

  @doc "Returns the current cursor position as a `{line, col}` tuple."
  @spec cursor(t()) :: position()
  def cursor(%__MODULE__{before: before}) do
    lines_before = String.split(before, "\n")
    line = length(lines_before) - 1
    col = lines_before |> List.last() |> String.length()
    {line, col}
  end

  @doc "Returns the byte offset of the cursor in the full text."
  @spec cursor_offset(t()) :: non_neg_integer()
  def cursor_offset(%__MODULE__{before: before}) do
    byte_size(before)
  end

  @doc """
  Returns the grapheme offset of a `{line, col}` position in the buffer content.
  """
  @spec position_to_offset(t(), position()) :: non_neg_integer()
  def position_to_offset(%__MODULE__{} = buf, {line, col})
      when is_integer(line) and line >= 0 and is_integer(col) and col >= 0 do
    text = content(buf)
    all_lines = String.split(text, "\n")
    grapheme_offset_for(all_lines, line, col)
  end

  @doc """
  Converts a grapheme offset in the buffer content to a `{line, col}` position.
  Clamps to valid bounds.
  """
  @spec offset_to_position(t(), non_neg_integer()) :: position()
  def offset_to_position(%__MODULE__{} = buf, offset) when is_integer(offset) and offset >= 0 do
    text = content(buf)
    do_offset_to_position(text, offset, 0, 0)
  end

  # ── Mutations ──

  @doc """
  Inserts a character (or string) at the cursor position.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("world")
      iex> buf = Minga.Buffer.GapBuffer.insert_char(buf, "hello ")
      iex> Minga.Buffer.GapBuffer.content(buf)
      "hello world"
  """
  @spec insert_char(t(), String.t()) :: t()
  def insert_char(%__MODULE__{before: before, after: after_}, char) when is_binary(char) do
    %__MODULE__{before: before <> char, after: after_}
  end

  @doc """
  Deletes the character before the cursor (backspace).
  Returns the buffer unchanged if the cursor is at the beginning.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello")
      iex> buf = Minga.Buffer.GapBuffer.move_to(buf, {0, 5})
      iex> buf = Minga.Buffer.GapBuffer.delete_before(buf)
      iex> Minga.Buffer.GapBuffer.content(buf)
      "hell"
  """
  @spec delete_before(t()) :: t()
  def delete_before(%__MODULE__{before: "", after: after_}) do
    %__MODULE__{before: "", after: after_}
  end

  def delete_before(%__MODULE__{before: before, after: after_}) do
    # Remove the last grapheme from `before`
    {new_before, _removed} = pop_last_grapheme(before)
    %__MODULE__{before: new_before, after: after_}
  end

  @doc """
  Deletes the character at the cursor (delete forward).
  Returns the buffer unchanged if the cursor is at the end.
  """
  @spec delete_at(t()) :: t()
  def delete_at(%__MODULE__{before: before, after: ""}) do
    %__MODULE__{before: before, after: ""}
  end

  def delete_at(%__MODULE__{before: before, after: after_}) do
    # Remove the first grapheme from `after_`
    case String.next_grapheme(after_) do
      {_grapheme, rest} -> %__MODULE__{before: before, after: rest}
      nil -> %__MODULE__{before: before, after: after_}
    end
  end

  # ── Movement ──

  @doc "Moves the cursor one step in the given direction."
  @spec move(t(), direction()) :: t()
  def move(%__MODULE__{} = buf, direction) when direction in [:left, :right, :up, :down] do
    case direction do
      :left -> move_left(buf)
      :right -> move_right(buf)
      :up -> move_up(buf)
      :down -> move_down(buf)
    end
  end

  @doc """
  Moves the cursor to an exact `{line, col}` position.

  Line and column are clamped to valid buffer bounds.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello\\nworld")
      iex> buf = Minga.Buffer.GapBuffer.move_to(buf, {1, 3})
      iex> Minga.Buffer.GapBuffer.cursor(buf)
      {1, 3}
  """
  @spec move_to(t(), position()) :: t()
  def move_to(%__MODULE__{} = buf, {target_line, target_col})
      when is_integer(target_line) and target_line >= 0 and
             is_integer(target_col) and target_col >= 0 do
    text = content(buf)
    all_lines = String.split(text, "\n")

    # Clamp line to valid range
    max_line = length(all_lines) - 1
    line = min(target_line, max_line)

    # Clamp col to valid range for that line (grapheme count)
    line_text = Enum.at(all_lines, line)
    max_col = String.length(line_text)
    col = min(target_col, max_col)

    # Calculate grapheme offset from start of text
    grapheme_offset = grapheme_offset_for(all_lines, line, col)

    # Split at grapheme position (not byte position)
    {before, after_} = split_at_grapheme(text, grapheme_offset)

    %__MODULE__{before: before, after: after_}
  end

  # ── Range operations ──

  @doc """
  Returns the text between two positions **inclusive** on both ends.
  If the positions are reversed, they are normalised automatically.
  """
  @spec content_range(t(), position(), position()) :: String.t()
  def content_range(%__MODULE__{} = buf, from_pos, to_pos) do
    text = content(buf)
    all_lines = String.split(text, "\n")
    total_graphemes = String.length(text)
    from_off = grapheme_offset_for(all_lines, elem(from_pos, 0), elem(from_pos, 1))
    to_off = grapheme_offset_for(all_lines, elem(to_pos, 0), elem(to_pos, 1))
    {start_off, end_off} = if from_off <= to_off, do: {from_off, to_off}, else: {to_off, from_off}
    extract_count = min(end_off - start_off + 1, total_graphemes - start_off)
    {_, rest} = split_at_grapheme(text, start_off)
    {extracted, _} = split_at_grapheme(rest, extract_count)
    extracted
  end

  @doc """
  Deletes the text between two positions **inclusive** on both ends.
  If the positions are reversed, they are normalised automatically.
  The cursor is placed at the earlier position.
  """
  @spec delete_range(t(), position(), position()) :: t()
  def delete_range(%__MODULE__{} = buf, from_pos, to_pos) do
    text = content(buf)
    all_lines = String.split(text, "\n")
    total_graphemes = String.length(text)
    from_off = grapheme_offset_for(all_lines, elem(from_pos, 0), elem(from_pos, 1))
    to_off = grapheme_offset_for(all_lines, elem(to_pos, 0), elem(to_pos, 1))

    {start_off, end_off, cursor_pos} =
      if from_off <= to_off,
        do: {from_off, to_off, from_pos},
        else: {to_off, from_off, to_pos}

    # Inclusive: delete end_off - start_off + 1 graphemes, clamped to buffer length.
    delete_count = min(end_off - start_off + 1, total_graphemes - start_off)
    {before_text, rest} = split_at_grapheme(text, start_off)
    {_, after_text} = split_at_grapheme(rest, delete_count)
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
    text = content(buf)
    graphemes = String.graphemes(text)
    all_lines = String.split(text, "\n")

    {s, e} = sort_positions(start_pos, end_pos)
    s_off = grapheme_offset_for(all_lines, elem(s, 0), elem(s, 1))
    e_off = grapheme_offset_for(all_lines, elem(e, 0), elem(e, 1))

    graphemes |> Enum.slice(s_off..e_off) |> Enum.join()
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

    buf
    |> content()
    |> String.split("\n")
    |> Enum.slice(s..e)
    |> Enum.join("\n")
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
    text = content(buf)
    all_lines = String.split(text, "\n")
    total_lines = length(all_lines)

    {s, e} = if start_line <= end_line, do: {start_line, end_line}, else: {end_line, start_line}
    s = min(s, total_lines - 1)
    e = min(e, total_lines - 1)

    before_lines = Enum.take(all_lines, s)
    after_lines = Enum.drop(all_lines, e + 1)
    remaining = before_lines ++ after_lines

    new_text =
      case remaining do
        [] -> ""
        lines -> Enum.join(lines, "\n")
      end

    target_line = min(s, max(0, length(remaining) - 1))
    new_text |> new() |> move_to({target_line, 0})
  end

  # ── Private helpers ──

  @spec move_left(t()) :: t()
  defp move_left(%__MODULE__{before: "", after: after_}) do
    %__MODULE__{before: "", after: after_}
  end

  defp move_left(%__MODULE__{before: before, after: after_}) do
    {new_before, char} = pop_last_grapheme(before)
    %__MODULE__{before: new_before, after: char <> after_}
  end

  @spec move_right(t()) :: t()
  defp move_right(%__MODULE__{before: before, after: ""}) do
    %__MODULE__{before: before, after: ""}
  end

  defp move_right(%__MODULE__{before: before, after: after_}) do
    case String.next_grapheme(after_) do
      {grapheme, rest} -> %__MODULE__{before: before <> grapheme, after: rest}
      nil -> %__MODULE__{before: before, after: ""}
    end
  end

  @spec move_up(t()) :: t()
  defp move_up(%__MODULE__{} = buf) do
    {line, col} = cursor(buf)

    if line == 0 do
      buf
    else
      move_to(buf, {line - 1, col})
    end
  end

  @spec move_down(t()) :: t()
  defp move_down(%__MODULE__{} = buf) do
    {line, col} = cursor(buf)
    max_line = line_count(buf) - 1

    if line >= max_line do
      buf
    else
      move_to(buf, {line + 1, col})
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

  @spec do_offset_to_position(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          position()
  defp do_offset_to_position("", _offset, line, col), do: {line, col}
  defp do_offset_to_position(_text, 0, line, col), do: {line, col}

  defp do_offset_to_position(text, offset, line, col) do
    case String.next_grapheme(text) do
      {"\n", rest} ->
        do_offset_to_position(rest, offset - 1, line + 1, 0)

      {_ch, rest} ->
        do_offset_to_position(rest, offset - 1, line, col + 1)

      nil ->
        {line, col}
    end
  end

  @spec sort_positions(position(), position()) :: {position(), position()}
  defp sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if {l1, c1} <= {l2, c2}, do: {p1, p2}, else: {p2, p1}
  end

  @spec count_newlines(String.t()) :: non_neg_integer()
  defp count_newlines(str) do
    str
    |> String.graphemes()
    |> Enum.count(&(&1 == "\n"))
  end

  @spec grapheme_offset_for([String.t()], non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp grapheme_offset_for(all_lines, target_line, target_col) do
    # Count graphemes in all complete lines before target_line (including \n)
    graphemes_before =
      all_lines
      |> Enum.take(target_line)
      |> Enum.reduce(0, fn line, acc -> acc + String.length(line) + 1 end)

    # Add graphemes for the partial column in the target line
    graphemes_before + target_col
  end

  # Split a string at a grapheme position, preserving exact binary representation
  @spec split_at_grapheme(String.t(), non_neg_integer()) :: {String.t(), String.t()}
  defp split_at_grapheme(str, 0), do: {"", str}

  defp split_at_grapheme(str, count) do
    do_split_at_grapheme(str, count, "")
  end

  @spec do_split_at_grapheme(String.t(), non_neg_integer(), String.t()) ::
          {String.t(), String.t()}
  defp do_split_at_grapheme(str, 0, acc), do: {acc, str}

  defp do_split_at_grapheme(str, remaining, acc) do
    case String.next_grapheme(str) do
      {grapheme, rest} -> do_split_at_grapheme(rest, remaining - 1, acc <> grapheme)
      nil -> {acc, ""}
    end
  end
end
