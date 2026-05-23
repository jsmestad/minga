defmodule Minga.Buffer.Lines do
  @moduledoc """
  Presents document content as editor lines.

  This module owns line-oriented questions: fetching visible line text, taking line ranges, and measuring how inserted text changes the current line.
  """

  alias Minga.Buffer.{Document, LineIndex}

  @type line_index :: non_neg_integer()
  @type line_count :: pos_integer()
  @type line_starts :: LineIndex.t()
  @type line_span :: LineIndex.span()
  @type snapshot :: {line_starts(), String.t()}

  @doc "Returns the content of one editor line without its trailing newline."
  @spec fetch(Document.t(), line_index()) :: String.t() | nil
  def fetch(%Document{} = doc, line) when line >= 0 do
    case span(doc.line_index, line, LineIndex.byte_size(doc.line_index)) do
      nil -> nil
      {start, length} -> extract(doc, start, length)
    end
  end

  @doc "Returns up to `count` editor lines starting at `first_line`."
  @spec slice(Document.t(), line_index(), non_neg_integer()) :: [String.t()]
  def slice(%Document{} = _doc, _first_line, 0), do: []

  def slice(%Document{} = doc, first_line, count) when first_line >= 0 and count >= 0 do
    last_line = LineIndex.count(doc.line_index) - 1
    final_line = min(first_line + count - 1, last_line)

    if first_line > last_line do
      []
    else
      for line <- first_line..final_line do
        {start, length} = span(doc.line_index, line, LineIndex.byte_size(doc.line_index))
        extract(doc, start, length)
      end
    end
  end

  @doc "Returns indexed document text so callers can answer multiple line questions without rebuilding the line index."
  @spec snapshot(Document.t()) :: snapshot()
  def snapshot(%Document{line_index: line_index} = doc) do
    {line_index, Document.content(doc)}
  end

  @doc "Returns how many editor lines `text` occupies."
  @spec count(String.t()) :: line_count()
  def count(""), do: 1
  def count(text) when is_binary(text), do: break_count(text) + 1

  @doc "Returns how many line breaks appear in `text`."
  @spec break_count(String.t()) :: non_neg_integer()
  def break_count(text) when is_binary(text), do: length(:binary.matches(text, "\n"))

  @doc "Returns the cursor column at the end of the final line in `text`."
  @spec last_line_width(String.t()) :: non_neg_integer()
  def last_line_width(""), do: 0

  def last_line_width(text) do
    byte_size(text) - last_line_start(text)
  end

  @doc "Returns the content span for one editor line."
  @spec span(line_starts(), line_index(), non_neg_integer()) :: line_span() | nil
  def span(%LineIndex{} = line_starts, line, _text_size) do
    LineIndex.span(line_starts, line)
  end

  @doc "Returns where one editor line starts in the document text."
  @spec start(line_starts(), line_index()) :: non_neg_integer()
  def start(%LineIndex{} = line_starts, line) when line >= 0 do
    LineIndex.start(line_starts, line)
  end

  @doc "Extracts a document byte span without joining both sides of the gap."
  @spec extract(Document.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def extract(%Document{} = doc, start, length) when start >= 0 and length >= 0 do
    do_extract(doc, start, length, byte_size(doc.before))
  end

  @spec do_extract(Document.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          String.t()
  defp do_extract(%Document{before: before}, start, length, gap_start)
       when start + length <= gap_start do
    binary_part(before, start, length)
  end

  defp do_extract(%Document{after: after_}, start, length, gap_start) when start >= gap_start do
    binary_part(after_, start - gap_start, length)
  end

  defp do_extract(%Document{before: before, after: after_}, start, length, gap_start) do
    before_length = gap_start - start
    after_length = length - before_length
    binary_part(before, start, before_length) <> binary_part(after_, 0, after_length)
  end

  @spec last_line_start(String.t()) :: non_neg_integer()
  defp last_line_start(text) do
    case :binary.matches(text, "\n") do
      [] -> 0
      matches -> elem(List.last(matches), 0) + 1
    end
  end
end
