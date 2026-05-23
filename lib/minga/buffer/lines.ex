defmodule Minga.Buffer.Lines do
  @moduledoc """
  Presents document content as editor lines.

  This module owns line-oriented questions: fetching visible line text,
  taking line ranges, maintaining the cached line index, and measuring
  how inserted text changes the current line.

  ## Line index representation

  The line index (`line_offsets` on `Document`) has three states:

  - **Clean tuple** `{0, 6, 12, ...}`: accurate line-start byte offsets.
  - **Pending delta** `{:pending, starts, adjust_after, delta}`: the tuple
    `starts` is stale; lines after `adjust_after` are shifted by `delta`.
    Queries apply the delta on the fly in O(1).
  - **`nil`**: needs a full rebuild from content.

  Single-character inserts and deletes (the hot path) produce pending
  deltas in O(1). Newline insertion/deletion flushes the delta and
  splices entries, which is O(line_count) but rare relative to
  non-newline edits.
  """

  alias Minga.Buffer.Document

  @type line_index :: non_neg_integer()
  @type line_count :: pos_integer()
  @type line_starts :: tuple()
  @type line_span :: {start :: non_neg_integer(), length :: non_neg_integer()}
  @type snapshot :: {line_starts(), String.t()}

  # ── Line extraction (zero-copy from gap buffer halves) ──

  @doc "Returns the content of one editor line without its trailing newline."
  @spec fetch(Document.t(), line_index()) :: String.t() | nil

  def fetch(%Document{before: before, after: after_, line_offsets: ls}, line)
      when is_tuple(ls) and is_integer(elem(ls, 0)) and line >= 0 do
    text_size = byte_size(before) + byte_size(after_)

    case span(ls, line, text_size) do
      nil -> nil
      {start, length} -> extract_from_gap(before, after_, start, length)
    end
  end

  def fetch(
        %Document{
          before: before,
          after: after_,
          line_offsets: {:pending, starts, adjust_after, delta}
        },
        line
      )
      when line >= 0 do
    text_size = byte_size(before) + byte_size(after_)

    case adjusted_span(starts, line, text_size, adjust_after, delta) do
      nil -> nil
      {start, length} -> extract_from_gap(before, after_, start, length)
    end
  end

  def fetch(%Document{} = doc, line) when line >= 0 do
    {line_starts, text} = snapshot(doc)

    case span(line_starts, line, byte_size(text)) do
      nil -> nil
      {start, length} -> binary_part(text, start, length)
    end
  end

  @doc "Returns up to `count` editor lines starting at `first_line`."
  @spec slice(Document.t(), line_index(), non_neg_integer()) :: [String.t()]

  def slice(
        %Document{before: before, after: after_, line_offsets: ls},
        first_line,
        count
      )
      when is_tuple(ls) and is_integer(elem(ls, 0)) and first_line >= 0 and count >= 0 do
    text_size = byte_size(before) + byte_size(after_)
    last_line = tuple_size(ls) - 1
    final_line = min(first_line + count - 1, last_line)

    if first_line > last_line do
      []
    else
      for line <- first_line..final_line do
        {start, length} = span(ls, line, text_size)
        extract_from_gap(before, after_, start, length)
      end
    end
  end

  def slice(
        %Document{
          before: before,
          after: after_,
          line_offsets: {:pending, starts, adjust_after, delta}
        },
        first_line,
        count
      )
      when first_line >= 0 and count >= 0 do
    text_size = byte_size(before) + byte_size(after_)
    last_line = tuple_size(starts) - 1
    final_line = min(first_line + count - 1, last_line)

    if first_line > last_line do
      []
    else
      for line <- first_line..final_line do
        {start, length} = adjusted_span(starts, line, text_size, adjust_after, delta)
        extract_from_gap(before, after_, start, length)
      end
    end
  end

  def slice(%Document{} = doc, first_line, count)
      when first_line >= 0 and count >= 0 do
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

  def snapshot(%Document{line_offsets: ls} = doc) when is_tuple(ls) and is_integer(elem(ls, 0)) do
    {ls, Document.content(doc)}
  end

  def snapshot(%Document{line_offsets: {:pending, starts, adjust_after, delta}} = doc) do
    {flush_to_tuple(starts, adjust_after, delta), Document.content(doc)}
  end

  def snapshot(%Document{} = doc) do
    text = Document.content(doc)
    {build_index(text), text}
  end

  # ── Line metrics ──

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

  # ── Index queries ──

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

  # ── Index construction and incremental update ──

  @doc "Builds a line-start index from a complete text."
  @spec build_index(String.t()) :: line_starts()
  def build_index(text) do
    newline_positions = :binary.matches(text, "\n")

    [0 | Enum.map(newline_positions, fn {pos, _len} -> pos + 1 end)]
    |> List.to_tuple()
  end

  @doc "Applies the pending delta to produce a clean tuple."
  @spec flush_to_tuple(line_starts(), non_neg_integer(), integer()) :: line_starts()
  def flush_to_tuple(starts, adjust_after, delta) do
    total = tuple_size(starts)

    for i <- 0..(total - 1) do
      raw = elem(starts, i)
      if i > adjust_after, do: raw + delta, else: raw
    end
    |> List.to_tuple()
  end

  @doc "Updates line_offsets after inserting `text` at the cursor. O(1) when text has no newlines."
  @spec update_after_insert(Document.line_offsets(), non_neg_integer(), non_neg_integer(), String.t()) ::
          Document.line_offsets()
  def update_after_insert(nil, _cursor_line, _gap, _text), do: nil

  def update_after_insert(ls, cursor_line, gap, text) do
    case :binary.match(text, "\n") do
      :nomatch ->
        accumulate_delta(ls, cursor_line, byte_size(text))

      _ ->
        clean = ensure_clean(ls)
        splice_newline_insert(clean, cursor_line, gap, text)
    end
  end

  @doc "Updates line_offsets after deleting one character before the cursor."
  @spec update_after_delete_before(Document.line_offsets(), non_neg_integer(), non_neg_integer(), boolean()) ::
          Document.line_offsets()
  def update_after_delete_before(nil, _cursor_line, _char_size, _newline?), do: nil

  def update_after_delete_before(ls, cursor_line, char_size, newline?) do
    case newline? do
      false ->
        accumulate_delta(ls, cursor_line, -char_size)

      true ->
        clean = ensure_clean(ls)
        remove_and_shift(clean, cursor_line, char_size)
    end
  end

  @doc "Updates line_offsets after deleting one character at the cursor (forward delete)."
  @spec update_after_delete_at(Document.line_offsets(), non_neg_integer(), non_neg_integer(), boolean()) ::
          Document.line_offsets()
  def update_after_delete_at(nil, _cursor_line, _char_size, _newline?), do: nil

  def update_after_delete_at(ls, cursor_line, char_size, newline?) do
    case newline? do
      false ->
        accumulate_delta(ls, cursor_line, -char_size)

      true ->
        clean = ensure_clean(ls)
        remove_and_shift(clean, cursor_line + 1, char_size)
    end
  end

  # ── Private helpers ──

  @spec extract_from_gap(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          String.t()
  defp extract_from_gap(before, after_, start, length) do
    gap = byte_size(before)
    line_end = start + length

    case {start >= gap, line_end <= gap} do
      {_, true} ->
        binary_part(before, start, length)

      {true, _} ->
        binary_part(after_, start - gap, length)

      _ ->
        before_len = gap - start
        binary_part(before, start, before_len) <> binary_part(after_, 0, length - before_len)
    end
  end

  @spec adjusted_span(line_starts(), line_index(), non_neg_integer(), non_neg_integer(), integer()) ::
          line_span() | nil
  defp adjusted_span(starts, line, _text_size, _adjust_after, _delta)
       when line > tuple_size(starts) - 1,
       do: nil

  defp adjusted_span(starts, line, text_size, adjust_after, delta)
       when line == tuple_size(starts) - 1 do
    start = adjusted_offset(starts, line, adjust_after, delta)
    {start, text_size - start}
  end

  defp adjusted_span(starts, line, _text_size, adjust_after, delta) do
    start = adjusted_offset(starts, line, adjust_after, delta)
    next = adjusted_offset(starts, line + 1, adjust_after, delta)
    {start, next - start - 1}
  end

  @spec adjusted_offset(line_starts(), line_index(), non_neg_integer(), integer()) ::
          non_neg_integer()
  defp adjusted_offset(starts, line, adjust_after, delta) do
    raw = elem(starts, line)
    if line > adjust_after, do: raw + delta, else: raw
  end

  @spec accumulate_delta(Document.line_offsets(), non_neg_integer(), integer()) ::
          Document.line_offsets()
  defp accumulate_delta({:pending, starts, adjust_after, delta}, line, new_delta)
       when adjust_after == line do
    {:pending, starts, adjust_after, delta + new_delta}
  end

  defp accumulate_delta({:pending, starts, adjust_after, delta}, line, new_delta) do
    clean = flush_to_tuple(starts, adjust_after, delta)
    {:pending, clean, line, new_delta}
  end

  defp accumulate_delta(starts, line, new_delta)
       when is_tuple(starts) and is_integer(elem(starts, 0)) do
    {:pending, starts, line, new_delta}
  end

  @spec ensure_clean(Document.line_offsets()) :: line_starts()
  defp ensure_clean({:pending, starts, adjust_after, delta}) do
    flush_to_tuple(starts, adjust_after, delta)
  end

  defp ensure_clean(starts) when is_tuple(starts) and is_integer(elem(starts, 0)), do: starts

  @spec splice_newline_insert(line_starts(), non_neg_integer(), non_neg_integer(), String.t()) ::
          line_starts()
  defp splice_newline_insert(starts, cursor_line, gap, text) do
    text_size = byte_size(text)
    newline_positions = :binary.matches(text, "\n")
    total = tuple_size(starts)
    new_entries = Enum.map(newline_positions, fn {pos, _len} -> gap + pos + 1 end)

    kept = for i <- 0..cursor_line, do: elem(starts, i)

    shifted =
      if cursor_line + 1 < total do
        for i <- (cursor_line + 1)..(total - 1), do: elem(starts, i) + text_size
      else
        []
      end

    (kept ++ new_entries ++ shifted) |> List.to_tuple()
  end

  @spec remove_and_shift(line_starts(), non_neg_integer(), non_neg_integer()) :: line_starts()
  defp remove_and_shift(starts, remove_line, char_size) when remove_line > 0 do
    total = tuple_size(starts)
    kept = for i <- 0..(remove_line - 1)//1, do: elem(starts, i)

    shifted =
      if remove_line + 1 < total do
        for i <- (remove_line + 1)..(total - 1), do: elem(starts, i) - char_size
      else
        []
      end

    (kept ++ shifted) |> List.to_tuple()
  end

  @spec last_line_start(String.t()) :: non_neg_integer()
  defp last_line_start(text) do
    case :binary.matches(text, "\n") do
      [] -> 0
      matches -> elem(List.last(matches), 0) + 1
    end
  end
end
