defmodule Minga.Buffer.Lines do
  @moduledoc """
  Presents document content as editor lines.

  This module owns line-oriented questions: fetching visible line text, taking line ranges, and measuring how inserted text changes the current line.
  """

  alias Minga.Buffer.Document

  @type line_index :: non_neg_integer()
  @type line_count :: pos_integer()
  @type line_starts :: tuple()
  @type line_span :: {start :: non_neg_integer(), length :: non_neg_integer()}
  @type snapshot :: {line_starts(), String.t()}

  @doc "Returns the content of one editor line without its trailing newline."
  @spec fetch(Document.t(), line_index()) :: String.t() | nil
  def fetch(%Document{} = doc, line) when line >= 0 do
    {line_starts, text} = snapshot(doc)

    case span(line_starts, line, byte_size(text)) do
      nil -> nil
      {start, length} -> binary_part(text, start, length)
    end
  end

  @doc "Returns up to `count` editor lines starting at `first_line`."
  @spec slice(Document.t(), line_index(), non_neg_integer()) :: [String.t()]
  def slice(%Document{} = doc, first_line, count) when first_line >= 0 and count >= 0 do
    {line_starts, text} = snapshot(doc)
    text_size = byte_size(text)
    last_line = tuple_size(line_starts) - 1
    final_line = min(first_line + count - 1, last_line)

    if first_line > last_line do
      []
    else
      for line <- first_line..final_line do
        {start, length} = span(line_starts, line, text_size)
        binary_part(text, start, length)
      end
    end
  end

  @doc "Returns indexed document text so callers can answer multiple line questions without rebuilding the line index."
  @spec snapshot(Document.t()) :: snapshot()
  def snapshot(%Document{line_offsets: line_starts} = doc) when is_tuple(line_starts) do
    {line_starts, Document.content(doc)}
  end

  def snapshot(%Document{} = doc) do
    text = Document.content(doc)
    {build_index(text), text}
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
  def span(line_starts, line, _text_size) when line > tuple_size(line_starts) - 1, do: nil

  def span(line_starts, line, text_size) when line == tuple_size(line_starts) - 1 do
    start = elem(line_starts, line)
    {start, text_size - start}
  end

  def span(line_starts, line, _text_size) do
    start = elem(line_starts, line)
    next_start = elem(line_starts, line + 1)
    {start, next_start - start - 1}
  end

  @doc "Returns where one editor line starts in the document text."
  @spec start(line_starts(), line_index()) :: non_neg_integer()
  def start(line_starts, line) when is_tuple(line_starts) and line >= 0 do
    elem(line_starts, line)
  end

  @spec build_index(String.t()) :: line_starts()
  defp build_index(text) do
    newline_positions = :binary.matches(text, "\n")

    [0 | Enum.map(newline_positions, fn {pos, _len} -> pos + 1 end)]
    |> List.to_tuple()
  end

  @spec last_line_start(String.t()) :: non_neg_integer()
  defp last_line_start(text) do
    case :binary.matches(text, "\n") do
      [] -> 0
      matches -> elem(List.last(matches), 0) + 1
    end
  end
end
