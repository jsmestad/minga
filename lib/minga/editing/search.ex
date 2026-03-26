defmodule Minga.Editing.Search do
  @moduledoc """
  Pure search functions for the Minga editor.

  Provides substring search over buffer content. All functions are pure —
  they take content strings or line lists and return positions. No buffer
  or process state is mutated.

  All positions use byte-indexed columns.

  ## Match representation

  A match is a `{line, byte_col, byte_length}` tuple where `line` and
  `byte_col` are zero-indexed.
  """

  alias Minga.Buffer.Document
  alias Minga.Editing.Search.Match

  @typedoc "A search match with line, byte column, and byte length."
  @type match :: Match.t()

  @typedoc "Search direction."
  @type direction :: :forward | :backward

  @typedoc "A zero-indexed cursor position."
  @type position :: {non_neg_integer(), non_neg_integer()}

  # ── Find next match ──────────────────────────────────────────────────────

  @doc """
  Finds the next match for `pattern` starting from `cursor` in the given
  `direction`. Wraps around the buffer if no match is found between cursor
  and the end (or start for backward).

  Returns `{line, byte_col}` of the match start, or `nil` if no match exists.

  ## Examples

      iex> Minga.Editing.Search.find_next("hello world\\nhello again", "hello", {0, 1}, :forward)
      {1, 0}

      iex> Minga.Editing.Search.find_next("hello world\\nhello again", "hello", {1, 0}, :backward)
      {0, 0}

      iex> Minga.Editing.Search.find_next("no match here", "xyz", {0, 0}, :forward)
      nil
  """
  @spec find_next(String.t(), String.t(), position(), direction()) :: position() | nil
  def find_next(_content, "", _cursor, _direction), do: nil

  def find_next(content, pattern, cursor, :forward) do
    lines = :binary.split(content, "\n", [:global])
    find_forward(lines, pattern, cursor, length(lines))
  end

  def find_next(content, pattern, cursor, :backward) do
    lines = :binary.split(content, "\n", [:global])
    find_backward(lines, pattern, cursor, length(lines))
  end

  # ── Find all matches in visible range ────────────────────────────────────

  @doc """
  Finds all occurrences of `pattern` in `lines` (a list of line strings).

  `first_line` is the buffer line number of the first element in `lines`,
  used to compute absolute line numbers in the returned matches.

  Returns a list of `Search.Match` structs.

  ## Examples

      iex> Minga.Editing.Search.find_all_in_range(["foo bar foo", "baz foo"], "foo", 0)
      [%Minga.Editing.Search.Match{line: 0, col: 0, length: 3}, %Minga.Editing.Search.Match{line: 0, col: 8, length: 3}, %Minga.Editing.Search.Match{line: 1, col: 4, length: 3}]
  """
  @spec find_all_in_range([String.t()], String.t(), non_neg_integer()) :: [match()]
  def find_all_in_range(_lines, "", _first_line), do: []

  def find_all_in_range(lines, pattern, first_line) do
    pattern_byte_len = byte_size(pattern)

    lines
    |> Enum.with_index(first_line)
    |> Enum.flat_map(fn {line_text, line_num} ->
      find_all_overlapping(line_text, pattern, pattern_byte_len, line_num, 0, [])
    end)
  end

  @spec find_all_overlapping(
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [match()]
        ) :: [match()]
  defp find_all_overlapping(line, pattern, pat_len, line_num, start, acc) do
    if start + pat_len > byte_size(line) do
      Enum.reverse(acc)
    else
      searchable = binary_part(line, start, byte_size(line) - start)

      case :binary.match(searchable, pattern) do
        :nomatch ->
          Enum.reverse(acc)

        {pos, _len} ->
          abs_pos = start + pos

          find_all_overlapping(line, pattern, pat_len, line_num, abs_pos + 1, [
            Match.new(line_num, abs_pos, pat_len) | acc
          ])
      end
    end
  end

  # ── Word at cursor ──────────────────────────────────────────────────────

  @doc """
  Returns the word under the cursor in the gap buffer, or `nil` if the
  cursor is not on a word character.

  A word character is alphanumeric or underscore (matching Vim's `\\<word\\>`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Editing.Search.word_at_cursor(buf, {0, 0})
      "hello"

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Editing.Search.word_at_cursor(buf, {0, 5})
      nil
  """
  @spec word_at_cursor(Document.t(), position()) :: String.t() | nil
  def word_at_cursor(%Document{} = buf, {line, col}) do
    lines = :binary.split(Document.content(buf), "\n", [:global])

    case Enum.at(lines, line) do
      nil ->
        nil

      text ->
        if col < byte_size(text) and word_char_at?(text, col) do
          start_byte = find_word_start_byte(text, col)
          end_byte = find_word_end_byte(text, col)
          binary_part(text, start_byte, end_byte - start_byte + 1)
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

      iex> Minga.Editing.Search.substitute("foo bar foo", "foo", "baz", true)
      {"baz bar baz", 2}

      iex> Minga.Editing.Search.substitute("foo bar foo", "foo", "baz", false)
      {"baz bar foo", 1}

      iex> Minga.Editing.Search.substitute("hello world", "xyz", "abc", true)
      {"hello world", 0}
  """
  @spec substitute(String.t(), String.t(), String.t(), boolean()) :: substitute_result()
  def substitute(content, pattern, replacement, global?) do
    lines = :binary.split(content, "\n", [:global])

    {new_lines, total_count} =
      Enum.map_reduce(lines, 0, fn line, count ->
        {new_line, line_count} = substitute_line(line, pattern, replacement, global?)
        {new_line, count + line_count}
      end)

    {Enum.join(new_lines, "\n"), total_count}
  end

  @doc """
  Substitutes occurrences of `pattern` with `replacement` in a single line.

  When `global?` is `true`, replaces all occurrences. When `false`, replaces
  only the first occurrence.

  Returns `{new_line, replacement_count}`.
  """
  @spec substitute_line(String.t(), String.t(), String.t(), boolean()) ::
          {String.t(), non_neg_integer()}
  def substitute_line(line, pattern, replacement, global?) do
    case global? do
      true ->
        matches = :binary.matches(line, pattern)
        do_substitute_all(line, matches, byte_size(pattern), replacement, 0, 0, [])

      false ->
        case :binary.match(line, pattern) do
          :nomatch ->
            {line, 0}

          {pos, len} ->
            before = binary_part(line, 0, pos)
            after_match = binary_part(line, pos + len, byte_size(line) - pos - len)
            {before <> replacement <> after_match, 1}
        end
    end
  end

  @spec do_substitute_all(
          String.t(),
          [{non_neg_integer(), non_neg_integer()}],
          non_neg_integer(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          iolist()
        ) :: {String.t(), non_neg_integer()}
  defp do_substitute_all(line, [], _pat_len, _rep, prev_end, count, acc) do
    final = [binary_part(line, prev_end, byte_size(line) - prev_end) | acc]
    {final |> Enum.reverse() |> IO.iodata_to_binary(), count}
  end

  defp do_substitute_all(line, [{pos, len} | rest], pat_len, rep, prev_end, count, acc) do
    before = binary_part(line, prev_end, pos - prev_end)
    do_substitute_all(line, rest, pat_len, rep, pos + len, count + 1, [rep, before | acc])
  end

  @typedoc "A replacement span: `{byte_col, byte_length}` in the substituted line."
  @type replacement_span :: {non_neg_integer(), non_neg_integer()}

  @doc """
  Like `substitute_line/4` but also returns the column spans of the
  replacement text in the resulting line, for highlighting.

  Returns `{new_line, replacement_count, spans}`.

  ## Examples

      iex> Minga.Editing.Search.substitute_line_with_spans("foo bar foo", "foo", "hello", true)
      {"hello bar hello", 2, [{0, 5}, {10, 5}]}
  """
  @spec substitute_line_with_spans(String.t(), String.t(), String.t(), boolean()) ::
          {String.t(), non_neg_integer(), [replacement_span()]}
  def substitute_line_with_spans(line, pattern, replacement, global?) do
    rep_len = byte_size(replacement)

    case global? do
      true ->
        matches = :binary.matches(line, pattern)

        sub_acc = %{
          rep: replacement,
          rep_len: rep_len,
          prev_end: 0,
          count: 0,
          output: [],
          spans: []
        }

        do_sub_spans_all(line, matches, sub_acc)

      false ->
        case :binary.match(line, pattern) do
          :nomatch ->
            {line, 0, []}

          {pos, len} ->
            before = binary_part(line, 0, pos)
            after_match = binary_part(line, pos + len, byte_size(line) - pos - len)
            {before <> replacement <> after_match, 1, [{pos, rep_len}]}
        end
    end
  end

  @typep sub_acc :: %{
           rep: String.t(),
           rep_len: non_neg_integer(),
           prev_end: non_neg_integer(),
           count: non_neg_integer(),
           output: iolist(),
           spans: [replacement_span()]
         }

  @spec do_sub_spans_all(String.t(), [{non_neg_integer(), non_neg_integer()}], sub_acc()) ::
          {String.t(), non_neg_integer(), [replacement_span()]}
  defp do_sub_spans_all(line, [], acc) do
    final = [binary_part(line, acc.prev_end, byte_size(line) - acc.prev_end) | acc.output]
    {final |> Enum.reverse() |> IO.iodata_to_binary(), acc.count, Enum.reverse(acc.spans)}
  end

  defp do_sub_spans_all(line, [{pos, len} | rest], acc) do
    before = binary_part(line, acc.prev_end, pos - acc.prev_end)
    new_output_pos = output_byte_size(acc.output) + byte_size(before)
    new_span = {new_output_pos, acc.rep_len}

    new_acc = %{
      acc
      | prev_end: pos + len,
        count: acc.count + 1,
        output: [acc.rep, before | acc.output],
        spans: [new_span | acc.spans]
    }

    do_sub_spans_all(line, rest, new_acc)
  end

  @spec output_byte_size(iolist()) :: non_neg_integer()
  defp output_byte_size(acc), do: IO.iodata_length(Enum.reverse(acc))

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
        ) :: position() | nil
  defp search_from(_lines, _pattern, line, _col, total) when line >= total, do: nil

  defp search_from(lines, pattern, line, col, total) do
    line_text = Enum.at(lines, line)
    start_byte = max(col, 0)

    if start_byte >= byte_size(line_text) do
      search_from(lines, pattern, line + 1, 0, total)
    else
      searchable = binary_part(line_text, start_byte, byte_size(line_text) - start_byte)

      case :binary.match(searchable, pattern) do
        {pos, _len} -> {line, start_byte + pos}
        :nomatch -> search_from(lines, pattern, line + 1, 0, total)
      end
    end
  end

  @spec search_backward_from(
          [String.t()],
          String.t(),
          non_neg_integer(),
          non_neg_integer() | :end
        ) :: position() | nil
  defp search_backward_from(_lines, _pattern, line, _col) when line < 0, do: nil

  defp search_backward_from(lines, pattern, line, max_col) do
    line_text = Enum.at(lines, line)

    upper =
      case max_col do
        :end -> byte_size(line_text)
        n -> min(n + byte_size(pattern), byte_size(line_text))
      end

    if upper <= 0 do
      search_backward_from(lines, pattern, line - 1, :end)
    else
      searchable = binary_part(line_text, 0, upper)

      case :binary.matches(searchable, pattern) do
        [] ->
          search_backward_from(lines, pattern, line - 1, :end)

        matches ->
          {last_pos, _len} = List.last(matches)
          {line, last_pos}
      end
    end
  end

  # ── Private — word helpers ────────────────────────────────────────────────

  @spec word_char_at?(String.t(), non_neg_integer()) :: boolean()
  defp word_char_at?(text, byte_col) do
    <<c>> = binary_part(text, byte_col, 1)
    (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) or c == ?_
  end

  @spec find_word_start_byte(String.t(), non_neg_integer()) :: non_neg_integer()
  defp find_word_start_byte(_text, 0), do: 0

  defp find_word_start_byte(text, col) do
    if col > 0 and word_char_at?(text, col - 1) do
      find_word_start_byte(text, col - 1)
    else
      col
    end
  end

  @spec find_word_end_byte(String.t(), non_neg_integer()) :: non_neg_integer()
  defp find_word_end_byte(text, col) do
    if col + 1 < byte_size(text) and word_char_at?(text, col + 1) do
      find_word_end_byte(text, col + 1)
    else
      col
    end
  end
end
