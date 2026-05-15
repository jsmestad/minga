defmodule Minga.Buffer.Lines do
  alias Minga.Buffer.Document

  @doc """
  Returns the text of a specific line (zero-indexed), without the trailing newline.
  Returns `nil` if the line number is out of range.
  """
  @spec line_at(Document.t(), non_neg_integer()) :: String.t() | nil
  def line_at(%Document{} = buf, line_num) when line_num >= 0 do
    {offsets, text} = ensure_line_offsets(buf)

    case line_byte_range(offsets, line_num, byte_size(text)) do
      nil -> nil
      {start, len} -> binary_part(text, start, len)
    end
  end

  @doc """
  Returns a range of lines (zero-indexed, inclusive start, exclusive end).
  """
  @spec lines(Document.t(), non_neg_integer(), non_neg_integer()) :: [String.t()]

  def lines(%Document{} = buf, start, count) when start >= 0 and count >= 0 do
    {offsets, _text} = ensure_line_offsets(buf)
    # text_size = byte_size(text)
    max_line = tuple_size(offsets) - 1
    last = min(start + count - 1, max_line)

    if start > max_line do
      []
    else
      for line_num <- start..last do
        line_at(buf, line_num)
        # {s, len} = line_byte_range(offsets, line_num, text_size)
        # binary_part(text, s, len)
      end
    end
  end

  @doc """
  Lazily computes line offsets if the cache is stale. Returns the offset
  tuple and the materialized content binary so callers avoid a second
  `content()` call. Uses `:binary.matches/2` (Boyer-Moore in C) for a
  single-pass newline scan.
  """
  @spec ensure_line_offsets(Document.t()) :: {tuple(), String.t()}
  def ensure_line_offsets(%Document{line_offsets: offsets} = buf) when is_tuple(offsets) do
    {offsets, Document.content(buf)}
  end

  def ensure_line_offsets(%Document{} = buf) do
    text = Document.content(buf)
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

  @doc """
  Returns the byte range {start_offset, byte_length} for a given line
  number, using the line offset tuple and the total content size.
  Returns `nil` if the line is out of range.
  """
  @spec line_byte_range(tuple(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def line_byte_range(offsets, line_num, _text_size) when line_num > tuple_size(offsets) - 1,
    do: nil

  def line_byte_range(offsets, line_num, text_size) when line_num == tuple_size(offsets) - 1 do
    start = elem(offsets, line_num)
    {start, text_size - start}
  end

  def line_byte_range(offsets, line_num, _text_size) do
    start = elem(offsets, line_num)
    # Next line starts at elem(offsets, line_num + 1); subtract 1 for the newline
    next_start = elem(offsets, line_num + 1)
    {start, next_start - start - 1}
  end
end
