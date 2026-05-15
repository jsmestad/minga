defmodule Minga.Buffer.Position do
  @typedoc """
  A zero-indexed `{line, byte_col}` position in the buffer.

  `byte_col` is the byte offset within the line's UTF-8 binary.
  For ASCII text, this equals the character/grapheme index.
  """
  @type t :: {line :: non_neg_integer(), byte_col :: non_neg_integer()}

  alias Minga.Buffer.{Document, Lines}

  @doc """
  Returns the byte offset of a `{line, byte_col}` position in the buffer content.
  """
  @spec position_to_offset(Document.t(), t()) :: non_neg_integer()
  def position_to_offset(%Document{} = buf, {line, col})
      when line >= 0 and col >= 0 do
    {offsets, text} = Lines.ensure_line_offsets(buf)
    offset_for_position(offsets, line, col, byte_size(text))
  end

  @doc """
  Converts a byte offset in the buffer content to a `{line, byte_col}` position.
  Clamps to valid bounds.
  """
  @spec offset_to_position(Document.t(), non_neg_integer()) :: t()
  def offset_to_position(%Document{} = buf, offset) when offset >= 0 do
    text = Document.content(buf)
    do_offset_to_position(text, offset, 0, 0)
  end

  @doc """
  Computes the byte offset from start of text for a {line, byte_col} position
  using the line offset tuple. O(1) lookup instead of O(lines) iteration.
  """
  @spec offset_for_position(tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def offset_for_position(offsets, line, col, text_size) do
    max_line = tuple_size(offsets) - 1
    clamped_line = min(line, max_line)
    offset = elem(offsets, clamped_line) + col
    min(offset, text_size)
  end

  @doc """
  Converts a `{line, byte_col}` position to a grapheme (display) column.

  Counts graphemes in the line text from byte 0 to `byte_col`.
  Used by the renderer to convert byte positions to screen columns.
  """
  @spec grapheme_col(Document.t(), t()) :: non_neg_integer()
  def grapheme_col(%Document{} = buf, {line, byte_col}) do
    case Lines.line_at(buf, line) do
      nil -> 0
      text -> grapheme_count_in_bytes(text, byte_col)
    end
  end

  # Converts a byte offset to {line, byte_col} by scanning for newlines.
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

  # Count graphemes in the first `byte_count` bytes of `text`.
  @spec grapheme_count_in_bytes(String.t(), non_neg_integer()) :: non_neg_integer()
  defp grapheme_count_in_bytes(_text, 0), do: 0

  defp grapheme_count_in_bytes(text, byte_count),
    do: do_grapheme_count_in_bytes(text, byte_count, 0, 0)

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
end
