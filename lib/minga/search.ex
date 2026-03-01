defmodule Minga.Search do
  @moduledoc """
  Pure search functions for the Minga editor.

  Provides substring search over buffer content. All functions are pure —
  they take content strings or line lists and return positions. No buffer
  or process state is mutated.

  ## Match representation

  A match is a `{line, col, length}` tuple where `line` and `col` are
  zero-indexed and `length` is the number of graphemes matched.
  """

  alias Minga.Buffer.GapBuffer

  @typedoc "A match: `{line, col, grapheme_length}`."
  @type match :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @typedoc "Search direction."
  @type direction :: :forward | :backward

  @typedoc "A zero-indexed cursor position."
  @type position :: {non_neg_integer(), non_neg_integer()}

  # ── Find next match ──────────────────────────────────────────────────────

  @doc """
  Finds the next match for `pattern` starting from `cursor` in the given
  `direction`. Wraps around the buffer if no match is found between cursor
  and the end (or start for backward).

  Returns `{line, col}` of the match start, or `nil` if no match exists.

  ## Examples

      iex> Minga.Search.find_next("hello world\\nhello again", "hello", {0, 1}, :forward)
      {1, 0}

      iex> Minga.Search.find_next("hello world\\nhello again", "hello", {1, 0}, :backward)
      {0, 0}

      iex> Minga.Search.find_next("no match here", "xyz", {0, 0}, :forward)
      nil
  """
  @spec find_next(String.t(), String.t(), position(), direction()) :: position() | nil
  def find_next(_content, "", _cursor, _direction), do: nil

  def find_next(content, pattern, cursor, :forward) do
    lines = String.split(content, "\n")
    find_forward(lines, pattern, cursor, length(lines))
  end

  def find_next(content, pattern, cursor, :backward) do
    lines = String.split(content, "\n")
    find_backward(lines, pattern, cursor, length(lines))
  end

  # ── Find all matches in visible range ────────────────────────────────────

  @doc """
  Finds all occurrences of `pattern` in `lines` (a list of line strings).

  `first_line` is the buffer line number of the first element in `lines`,
  used to compute absolute line numbers in the returned matches.

  Returns a list of `{line, col, length}` tuples.

  ## Examples

      iex> Minga.Search.find_all_in_range(["foo bar foo", "baz foo"], "foo", 0)
      [{0, 0, 3}, {0, 8, 3}, {1, 4, 3}]
  """
  @spec find_all_in_range([String.t()], String.t(), non_neg_integer()) :: [match()]
  def find_all_in_range(_lines, "", _first_line), do: []

  def find_all_in_range(lines, pattern, first_line) do
    pattern_len = String.length(pattern)

    lines
    |> Enum.with_index(first_line)
    |> Enum.flat_map(fn {line_text, line_num} ->
      find_all_in_line(line_text, pattern, pattern_len, line_num, 0, [])
    end)
  end

  # ── Word at cursor ──────────────────────────────────────────────────────

  @doc """
  Returns the word under the cursor in the gap buffer, or `nil` if the
  cursor is not on a word character.

  A word character is alphanumeric or underscore (matching Vim's `\\<word\\>`).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello world")
      iex> Minga.Search.word_at_cursor(buf, {0, 0})
      "hello"

      iex> buf = Minga.Buffer.GapBuffer.new("hello world")
      iex> Minga.Search.word_at_cursor(buf, {0, 5})
      nil
  """
  @spec word_at_cursor(GapBuffer.t(), position()) :: String.t() | nil
  def word_at_cursor(%GapBuffer{} = buf, {line, col}) do
    lines = String.split(GapBuffer.content(buf), "\n")

    case Enum.at(lines, line) do
      nil ->
        nil

      text ->
        graphemes = String.graphemes(text)

        if col < length(graphemes) and word_char?(Enum.at(graphemes, col)) do
          start_col = find_word_start(graphemes, col)
          end_col = find_word_end(graphemes, col, length(graphemes))

          graphemes
          |> Enum.slice(start_col..end_col)
          |> Enum.join()
        else
          nil
        end
    end
  end

  # ── Substitution ──────────────────────────────────────────────────────────

  @typedoc "Result of a substitution: new content and count of replacements."
  @type substitute_result :: {String.t(), non_neg_integer()}

  @doc """
  Replaces occurrences of `pattern` with `replacement` in `content`.

  When `global?` is `true`, replaces all occurrences. When `false`, replaces
  only the first occurrence on each line (Vim `:s` default).

  Returns `{new_content, replacement_count}`.

  ## Examples

      iex> Minga.Search.substitute("foo bar foo", "foo", "baz", true)
      {"baz bar baz", 2}

      iex> Minga.Search.substitute("foo bar foo", "foo", "baz", false)
      {"baz bar foo", 1}

      iex> Minga.Search.substitute("hello world", "xyz", "abc", true)
      {"hello world", 0}
  """
  @spec substitute(String.t(), String.t(), String.t(), boolean()) :: substitute_result()
  def substitute(content, pattern, replacement, global?) do
    lines = String.split(content, "\n")

    {new_lines, total_count} =
      Enum.map_reduce(lines, 0, fn line, count ->
        {new_line, line_count} = substitute_line(line, pattern, replacement, global?)
        {new_line, count + line_count}
      end)

    {Enum.join(new_lines, "\n"), total_count}
  end

  @spec substitute_line(String.t(), String.t(), String.t(), boolean()) ::
          {String.t(), non_neg_integer()}
  defp substitute_line(line, pattern, replacement, global?) do
    graphemes = String.graphemes(line)
    pattern_graphemes = String.graphemes(pattern)
    pattern_len = length(pattern_graphemes)

    do_substitute_line(graphemes, pattern_graphemes, pattern_len, replacement, global?, [], 0)
  end

  @spec do_substitute_line(
          [String.t()],
          [String.t()],
          non_neg_integer(),
          String.t(),
          boolean(),
          [String.t()],
          non_neg_integer()
        ) :: {String.t(), non_neg_integer()}
  defp do_substitute_line([], _pat, _pat_len, _rep, _global?, acc, count) do
    {acc |> Enum.reverse() |> Enum.join(), count}
  end

  defp do_substitute_line(graphemes, pat, pat_len, rep, global?, acc, count) do
    candidate = Enum.take(graphemes, pat_len)

    if length(candidate) == pat_len and candidate == pat do
      rest = Enum.drop(graphemes, pat_len)
      new_acc = [rep | acc]

      if global? do
        do_substitute_line(rest, pat, pat_len, rep, true, new_acc, count + 1)
      else
        # Non-global: only replace first match, append remaining unchanged
        remaining = Enum.join(rest)
        result = [remaining | new_acc] |> Enum.reverse() |> Enum.join()
        {result, count + 1}
      end
    else
      [head | tail] = graphemes
      do_substitute_line(tail, pat, pat_len, rep, global?, [head | acc], count)
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec find_forward([String.t()], String.t(), position(), non_neg_integer()) ::
          position() | nil
  defp find_forward(lines, pattern, {cur_line, cur_col}, total) do
    # Search from cursor position to end, then wrap from start to cursor
    case search_from(lines, pattern, cur_line, cur_col + 1, total) do
      nil -> search_from(lines, pattern, 0, 0, min(cur_line + 1, total))
      pos -> pos
    end
  end

  @spec find_backward([String.t()], String.t(), position(), non_neg_integer()) ::
          position() | nil
  defp find_backward(lines, pattern, {cur_line, cur_col}, total) do
    # Search backward from cursor to start, then wrap from end to cursor
    case search_backward_from(lines, pattern, cur_line, cur_col - 1) do
      nil -> search_backward_from(lines, pattern, total - 1, :end)
      pos -> pos
    end
  end

  @spec search_from(
          [String.t()],
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          position() | nil
  defp search_from(_lines, _pattern, line, _col, total) when line >= total, do: nil

  defp search_from(lines, pattern, line, col, total) do
    line_text = Enum.at(lines, line)
    graphemes = String.graphemes(line_text)
    start_col = max(col, 0)

    case find_in_graphemes(graphemes, pattern, start_col) do
      nil -> search_from(lines, pattern, line + 1, 0, total)
      found_col -> {line, found_col}
    end
  end

  @spec search_backward_from(
          [String.t()],
          String.t(),
          non_neg_integer(),
          non_neg_integer() | :end
        ) ::
          position() | nil
  defp search_backward_from(_lines, _pattern, line, _col) when line < 0, do: nil

  defp search_backward_from(lines, pattern, line, max_col) do
    line_text = Enum.at(lines, line)
    graphemes = String.graphemes(line_text)

    actual_max =
      case max_col do
        :end -> length(graphemes) - 1
        n -> n
      end

    case rfind_in_graphemes(graphemes, pattern, actual_max) do
      nil -> search_backward_from(lines, pattern, line - 1, :end)
      found_col -> {line, found_col}
    end
  end

  @spec find_in_graphemes([String.t()], String.t(), non_neg_integer()) ::
          non_neg_integer() | nil
  defp find_in_graphemes(graphemes, pattern, start_col) do
    pattern_graphemes = String.graphemes(pattern)
    pattern_len = length(pattern_graphemes)
    line_len = length(graphemes)

    do_find_in_graphemes(graphemes, pattern_graphemes, pattern_len, start_col, line_len)
  end

  @spec do_find_in_graphemes(
          [String.t()],
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer() | nil
  defp do_find_in_graphemes(_graphemes, _pattern, pattern_len, col, line_len)
       when col + pattern_len > line_len,
       do: nil

  defp do_find_in_graphemes(graphemes, pattern_graphemes, pattern_len, col, line_len) do
    candidate = Enum.slice(graphemes, col, pattern_len)

    if candidate == pattern_graphemes do
      col
    else
      do_find_in_graphemes(graphemes, pattern_graphemes, pattern_len, col + 1, line_len)
    end
  end

  @spec rfind_in_graphemes([String.t()], String.t(), non_neg_integer()) ::
          non_neg_integer() | nil
  defp rfind_in_graphemes(_graphemes, _pattern, max_col) when max_col < 0, do: nil

  defp rfind_in_graphemes(graphemes, pattern, max_col) do
    pattern_graphemes = String.graphemes(pattern)
    pattern_len = length(pattern_graphemes)

    do_rfind_in_graphemes(graphemes, pattern_graphemes, pattern_len, max_col)
  end

  @spec do_rfind_in_graphemes(
          [String.t()],
          [String.t()],
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer() | nil
  defp do_rfind_in_graphemes(_graphemes, _pattern, _pattern_len, col) when col < 0, do: nil

  defp do_rfind_in_graphemes(graphemes, pattern_graphemes, pattern_len, col) do
    candidate = Enum.slice(graphemes, col, pattern_len)

    if candidate == pattern_graphemes do
      col
    else
      do_rfind_in_graphemes(graphemes, pattern_graphemes, pattern_len, col - 1)
    end
  end

  @spec find_all_in_line(
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [match()]
        ) :: [match()]
  defp find_all_in_line(line_text, pattern, pattern_len, line_num, start_col, acc) do
    graphemes = String.graphemes(line_text)

    case find_in_graphemes(graphemes, pattern, start_col) do
      nil ->
        Enum.reverse(acc)

      col ->
        find_all_in_line(
          line_text,
          pattern,
          pattern_len,
          line_num,
          col + 1,
          [{line_num, col, pattern_len} | acc]
        )
    end
  end

  @spec word_char?(String.t() | nil) :: boolean()
  defp word_char?(nil), do: false

  defp word_char?(g) when byte_size(g) > 0 do
    <<c, _::binary>> = g
    (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) or c == ?_
  end

  defp word_char?(_), do: false

  @spec find_word_start([String.t()], non_neg_integer()) :: non_neg_integer()
  defp find_word_start(_graphemes, 0), do: 0

  defp find_word_start(graphemes, col) do
    if word_char?(Enum.at(graphemes, col - 1)) do
      find_word_start(graphemes, col - 1)
    else
      col
    end
  end

  @spec find_word_end([String.t()], non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp find_word_end(_graphemes, col, len) when col + 1 >= len, do: col

  defp find_word_end(graphemes, col, len) do
    if word_char?(Enum.at(graphemes, col + 1)) do
      find_word_end(graphemes, col + 1, len)
    else
      col
    end
  end
end
