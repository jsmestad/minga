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

  @doc "Creates a new gap buffer from a string. Cursor starts at {0, 0}."
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

  @doc "Returns true if the buffer contains no text."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{before: "", after: ""}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc "Returns the total number of lines in the buffer."
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

  # ── Mutations ──

  @doc "Inserts a character (or string) at the cursor position."
  @spec insert_char(t(), String.t()) :: t()
  def insert_char(%__MODULE__{before: before, after: after_}, char) when is_binary(char) do
    %__MODULE__{before: before <> char, after: after_}
  end

  @doc """
  Deletes the character before the cursor (backspace).
  Returns the buffer unchanged if the cursor is at the beginning.
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

  @doc "Moves the cursor to an exact `{line, col}` position."
  @spec move_to(t(), position()) :: t()
  def move_to(%__MODULE__{} = buf, {target_line, target_col})
      when is_integer(target_line) and target_line >= 0 and
             is_integer(target_col) and target_col >= 0 do
    text = content(buf)
    all_lines = String.split(text, "\n")

    # Clamp line to valid range
    max_line = length(all_lines) - 1
    line = min(target_line, max_line)

    # Clamp col to valid range for that line
    line_text = Enum.at(all_lines, line)
    max_col = String.length(line_text)
    col = min(target_col, max_col)

    # Calculate byte offset
    offset = byte_offset_for(all_lines, line, col)
    {before, after_} = String.split_at(text, offset)

    %__MODULE__{before: before, after: after_}
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

  @spec pop_last_grapheme(String.t()) :: {String.t(), String.t()}
  defp pop_last_grapheme(str) do
    graphemes = String.graphemes(str)
    last = List.last(graphemes)
    rest = graphemes |> Enum.drop(-1) |> Enum.join()
    {rest, last}
  end

  @spec count_newlines(String.t()) :: non_neg_integer()
  defp count_newlines(str) do
    str
    |> String.graphemes()
    |> Enum.count(&(&1 == "\n"))
  end

  @spec byte_offset_for([String.t()], non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp byte_offset_for(all_lines, target_line, target_col) do
    # Sum bytes of all complete lines before target_line (including \n)
    lines_before =
      all_lines
      |> Enum.take(target_line)
      |> Enum.reduce(0, fn line, acc -> acc + byte_size(line) + 1 end)

    # Add bytes for the partial column in the target line
    target_line_text = Enum.at(all_lines, target_line)

    col_bytes =
      target_line_text
      |> String.graphemes()
      |> Enum.take(target_col)
      |> Enum.join()
      |> byte_size()

    lines_before + col_bytes
  end
end
