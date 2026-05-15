defmodule Minga.Buffer.Cursor do
  alias Minga.Buffer.{Document, Lines}

  @doc "Moves the cursor one step in the given direction."
  @spec move(Document.t(), :left | :right | :up | :down) :: Document.t()
  def move(%Document{before: ""} = buf, :left), do: buf

  def move(%Document{cursor_line: line} = buf, :left) do
    {new_before, char} = Document.pop_last_grapheme(buf.before)

    {new_line, new_col} =
      case char do
        "\n" -> {line - 1, Document.byte_col_in_last_line(new_before)}
        _ -> {line, byte_size(new_before) - Document.byte_offset_of_last_newline(new_before)}
      end

    %{
      buf
      | before: new_before,
        after: char <> buf.after,
        cursor_line: new_line,
        cursor_col: new_col
    }
  end

  def move(%Document{after: ""} = buf, :right), do: buf

  def move(%Document{} = buf, :right) do
    case String.next_grapheme(buf.after) do
      {"\n", rest} ->
        %{
          buf
          | before: buf.before <> "\n",
            after: rest,
            cursor_line: buf.cursor_line + 1,
            cursor_col: 0
        }

      {grapheme, rest} ->
        %{
          buf
          | before: buf.before <> grapheme,
            after: rest,
            cursor_col: buf.cursor_col + byte_size(grapheme)
        }

      nil ->
        buf
    end
  end

  def move(%Document{cursor_line: 0} = buf, :up), do: buf

  def move(%Document{} = buf, :up), do: move_to(buf, {buf.cursor_line - 1, buf.cursor_col})

  def move(%Document{cursor_line: line, line_count: lc} = buf, :down) when line >= lc - 1,
    do: buf

  def move(%Document{} = buf, :down), do: move_to(buf, {buf.cursor_line + 1, buf.cursor_col})

  @doc """
  Moves the cursor to an exact `{line, byte_col}` position.

  Line and column are clamped to valid buffer bounds.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello\\nworld")
      iex> buf = Minga.Buffer.Document.move_to(buf, {1, 3})
      iex> Minga.Buffer.Document.cursor(buf)
      {1, 3}
  """
  @spec move_to(Document.t(), Document.position()) :: Document.t()
  def move_to(%Document{} = buf, {target_line, target_col})
      when target_line >= 0 and target_col >= 0 do
    {offsets, text} = Lines.ensure_line_offsets(buf)
    text_size = byte_size(text)

    # Clamp line to valid range
    max_line = tuple_size(offsets) - 1
    line = min(target_line, max_line)

    # Get line text via index for column clamping
    {line_start, line_len} = Lines.line_byte_range(offsets, line, text_size)
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
end
