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

  @typedoc "Search options. Defaults: `case_sensitive: true`, `whole_word: false`, `regex: false`."
  @type search_opts :: [
          case_sensitive: boolean(),
          whole_word: boolean(),
          regex: boolean()
        ]

  @typedoc "A compiled matcher: either a binary for `:binary.match` or a `Regex` for `Regex.run`."
  @type matcher :: binary() | Regex.t()

  # ── Matcher compilation ──────────────────────────────────────────────────

  @spec compile_matcher(String.t(), search_opts()) :: matcher()
  defp compile_matcher(pattern, []), do: pattern

  defp compile_matcher(pattern, opts) do
    use_regex = Keyword.get(opts, :regex, false)
    case_sensitive = Keyword.get(opts, :case_sensitive, true)
    whole_word = Keyword.get(opts, :whole_word, false)

    if case_sensitive and not whole_word and (not use_regex or literal_regex?(pattern)) do
      pattern
    else
      compile_regex(pattern, use_regex, case_sensitive, whole_word)
    end
  end

  @spec compile_regex(String.t(), boolean(), boolean(), boolean()) :: Regex.t()
  defp compile_regex(pattern, use_regex, case_sensitive, whole_word) do
    regex_source = if use_regex, do: pattern, else: Regex.escape(pattern)
    regex_source = if whole_word, do: "\\b#{regex_source}\\b", else: regex_source
    regex_opts = if case_sensitive, do: "", else: "i"

    case Regex.compile(regex_source, regex_opts) do
      {:ok, regex} -> regex
      {:error, _} -> Regex.compile!(Regex.escape(pattern), regex_opts)
    end
  end

  # Nonempty regexes without metacharacters match their own bytes; neither `x` nor `u` is enabled.
  # The binary matcher avoids regex compilation. Empty sources stay regexes for zero-width matches.
  @spec literal_regex?(String.t()) :: boolean()
  defp literal_regex?(""), do: false
  defp literal_regex?(pattern), do: free_of_regex_metacharacters?(pattern)

  @spec free_of_regex_metacharacters?(binary()) :: boolean()
  defp free_of_regex_metacharacters?(<<>>), do: true

  defp free_of_regex_metacharacters?(<<byte, _rest::binary>>) when byte in ~c".^$*+?()[]{}\\|",
    do: false

  defp free_of_regex_metacharacters?(<<_byte, rest::binary>>),
    do: free_of_regex_metacharacters?(rest)

  @spec match_in(String.t(), matcher()) :: {non_neg_integer(), non_neg_integer()} | nil
  defp match_in(haystack, matcher) when is_binary(matcher) do
    case :binary.match(haystack, matcher) do
      {pos, len} -> {pos, len}
      :nomatch -> nil
    end
  end

  defp match_in(haystack, %Regex{} = matcher) do
    case Regex.run(matcher, haystack, return: :index, capture: :first) do
      [{pos, len}] -> {pos, len}
      nil -> nil
    end
  end

  @spec matches_in(String.t(), matcher()) :: [{non_neg_integer(), non_neg_integer()}]
  defp matches_in(haystack, matcher) when is_binary(matcher) do
    :binary.matches(haystack, matcher)
  end

  defp matches_in(haystack, %Regex{} = matcher) do
    Regex.scan(matcher, haystack, return: :index, capture: :first)
    |> Enum.map(fn [{pos, len}] -> {pos, len} end)
  end

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
  @spec find_next(String.t(), String.t(), position(), direction(), search_opts()) ::
          position() | nil
  def find_next(content, pattern, cursor, direction, opts \\ [])
  def find_next(_content, "", _cursor, _direction, _opts), do: nil

  def find_next(content, pattern, cursor, :forward, opts) do
    lines = :binary.split(content, "\n", [:global])
    find_forward(lines, compile_matcher(pattern, opts), cursor)
  end

  def find_next(content, pattern, cursor, :backward, opts) do
    lines = :binary.split(content, "\n", [:global])
    find_backward(lines, compile_matcher(pattern, opts), cursor)
  end

  @spec find_on_lines([String.t()], matcher(), position(), direction()) :: position() | nil
  defp find_on_lines(lines, matcher, cursor, :forward), do: find_forward(lines, matcher, cursor)
  defp find_on_lines(lines, matcher, cursor, :backward), do: find_backward(lines, matcher, cursor)

  @doc "Returns the exact match at `position`, including its byte length, or nil."
  @spec match_at(String.t(), String.t(), position(), search_opts()) :: match() | nil
  def match_at(content, pattern, position, opts \\ [])
  def match_at(_content, "", _position, _opts), do: nil

  def match_at(content, pattern, {line, col}, opts) do
    content
    |> :binary.split("\n", [:global])
    |> Enum.at(line)
    |> match_at_column(pattern, line, col, opts)
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
  @spec find_all_in_range([String.t()], String.t(), non_neg_integer(), search_opts()) :: [match()]
  def find_all_in_range(lines, pattern, first_line, opts \\ [])
  def find_all_in_range(_lines, "", _first_line, _opts), do: []

  def find_all_in_range(lines, pattern, first_line, opts) do
    matcher = compile_matcher(pattern, opts)

    lines
    |> Enum.with_index(first_line)
    |> Enum.flat_map(fn {line_text, line_num} ->
      find_all_overlapping(line_text, matcher, line_num, 0, [])
    end)
  end

  @spec find_all_overlapping(String.t(), matcher(), non_neg_integer(), non_neg_integer(), [
          match()
        ]) :: [match()]
  defp find_all_overlapping(line, matcher, line_num, start, acc) do
    if start >= byte_size(line) do
      Enum.reverse(acc)
    else
      searchable = binary_part(line, start, byte_size(line) - start)

      case match_in(searchable, matcher) do
        nil ->
          Enum.reverse(acc)

        {pos, match_len} ->
          abs_pos = start + pos

          find_all_overlapping(line, matcher, line_num, abs_pos + 1, [
            Match.new(line_num, abs_pos, match_len) | acc
          ])
      end
    end
  end

  @spec match_at_column(
          String.t() | nil,
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          search_opts()
        ) ::
          match() | nil
  defp match_at_column(nil, _pattern, _line, _col, _opts), do: nil

  defp match_at_column(line_text, pattern, line, col, opts) do
    matcher = compile_matcher(pattern, opts)

    case match_at_position(line_text, matcher, col) do
      {^col, length} -> Match.new(line, col, length)
      nil -> nil
    end
  end

  @spec match_at_position(String.t(), matcher(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp match_at_position(line_text, matcher, col) when is_binary(matcher) do
    matcher_size = byte_size(matcher)

    if col + matcher_size <= byte_size(line_text) and
         binary_part(line_text, col, matcher_size) == matcher do
      {col, matcher_size}
    else
      nil
    end
  end

  defp match_at_position(line_text, %Regex{} = matcher, col) do
    case Regex.run(matcher, line_text, return: :index, capture: :first, offset: col) do
      [{^col, length}] -> {col, length}
      _other -> nil
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
  def word_at_cursor(%Document{} = buf, {line, col}),
    do: word_at_byte(Document.line_at(buf, line), col)

  @doc "Finds the cursor word and its next position using one split of the buffer text."
  @spec find_word_next(String.t(), position(), direction()) ::
          {String.t(), position() | nil} | nil
  def find_word_next(content, {line, col} = cursor, direction) do
    lines = :binary.split(content, "\n", [:global])

    case word_at_byte(Enum.at(lines, line), col) do
      nil -> nil
      word -> {word, find_on_lines(lines, word, cursor, direction)}
    end
  end

  @spec word_at_byte(String.t() | nil, non_neg_integer()) :: String.t() | nil
  defp word_at_byte(text, col) when col < byte_size(text) do
    if word_char_at?(text, col) do
      start_byte = find_word_start_byte(text, col)
      end_byte = find_word_end_byte(text, col)
      binary_part(text, start_byte, end_byte - start_byte + 1)
    end
  end

  defp word_at_byte(_text, _col), do: nil

  # ── Substitution ──────────────────────────────────────────────────────────

  @typep line_focus :: {non_neg_integer(), [String.t()], [String.t()]}

  @doc "Applies accepted matches in the supplied order, using the text left by each previous edit."
  @spec apply_substitutions(String.t(), [match()], String.t()) :: String.t()
  def apply_substitutions(content, [], _replacement), do: content

  def apply_substitutions(content, matches, replacement) do
    lines = :binary.split(content, "\n", [:global])
    multiline? = :binary.match(replacement, "\n") != :nomatch

    {_line, before, remaining} =
      Enum.reduce(matches, {0, [], lines}, fn %Match{line: line} = match, focus ->
        focus
        |> seek_line(line)
        |> apply_focused_match(match, replacement, multiline?)
      end)

    before |> Enum.reverse(remaining) |> Enum.join("\n")
  end

  # The prefix is reversed so both neighboring lines are available without starting over.
  @spec seek_line(line_focus(), non_neg_integer()) :: line_focus()
  defp seek_line({line, before, [text | rest]}, target) when line < target,
    do: seek_line({line + 1, [text | before], rest}, target)

  defp seek_line({line, [text | before], rest}, target) when line > target,
    do: seek_line({line - 1, before, [text | rest]}, target)

  defp seek_line(focus, _target), do: focus

  @spec apply_focused_match(line_focus(), match(), String.t(), boolean()) :: line_focus()
  defp apply_focused_match({_, _, []} = focus, _match, _replacement, _multiline?), do: focus

  defp apply_focused_match({line, before, [text | rest]}, match, replacement, multiline?) do
    edited = splice_match(text, {match.col, match.length}, replacement)

    rest =
      if multiline?, do: :binary.split(edited, "\n", [:global]) ++ rest, else: [edited | rest]

    {line, before, rest}
  end

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
  @spec substitute(String.t(), String.t(), String.t(), boolean(), search_opts()) ::
          substitute_result()
  def substitute(content, pattern, replacement, global?, opts \\ []) do
    matcher = compile_matcher(pattern, opts)
    lines = :binary.split(content, "\n", [:global])

    {new_lines, total_count} =
      Enum.map_reduce(lines, 0, fn line, count ->
        {new_line, line_count} = substitute_line(line, matcher, replacement, global?)
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
  @spec substitute_line(String.t(), matcher(), String.t(), boolean()) ::
          {String.t(), non_neg_integer()}
  def substitute_line(line, matcher, replacement, global?) do
    if global? do
      matches = matches_in(line, matcher)
      do_substitute_all(line, matches, replacement, 0, 0, [])
    else
      case match_in(line, matcher) do
        nil ->
          {line, 0}

        match ->
          {splice_match(line, match, replacement), 1}
      end
    end
  end

  @spec do_substitute_all(
          String.t(),
          [{non_neg_integer(), non_neg_integer()}],
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          [binary()]
        ) :: {String.t(), non_neg_integer()}
  defp do_substitute_all(line, [], _rep, prev_end, count, acc) do
    {finish_substitution(line, prev_end, acc), count}
  end

  defp do_substitute_all(line, [{pos, len} | rest], rep, prev_end, count, acc) do
    before = binary_part(line, prev_end, pos - prev_end)
    do_substitute_all(line, rest, rep, pos + len, count + 1, [rep, before | acc])
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
  @spec substitute_line_with_spans(String.t(), String.t(), String.t(), boolean(), search_opts()) ::
          {String.t(), non_neg_integer(), [replacement_span()]}
  def substitute_line_with_spans(line, pattern, replacement, global?, opts \\ []) do
    matcher = compile_matcher(pattern, opts)
    rep_len = byte_size(replacement)

    if global? do
      matches = matches_in(line, matcher)

      sub_acc = %{
        rep: replacement,
        rep_len: rep_len,
        prev_end: 0,
        count: 0,
        output: [],
        output_size: 0,
        spans: []
      }

      do_sub_spans_all(line, matches, sub_acc)
    else
      case match_in(line, matcher) do
        nil ->
          {line, 0, []}

        {pos, _len} = match ->
          {splice_match(line, match, replacement), 1, [{pos, rep_len}]}
      end
    end
  end

  @typep sub_acc :: %{
           rep: String.t(),
           rep_len: non_neg_integer(),
           prev_end: non_neg_integer(),
           count: non_neg_integer(),
           output: [binary()],
           output_size: non_neg_integer(),
           spans: [replacement_span()]
         }

  @spec do_sub_spans_all(String.t(), [{non_neg_integer(), non_neg_integer()}], sub_acc()) ::
          {String.t(), non_neg_integer(), [replacement_span()]}
  defp do_sub_spans_all(line, [], acc) do
    {finish_substitution(line, acc.prev_end, acc.output), acc.count, Enum.reverse(acc.spans)}
  end

  defp do_sub_spans_all(line, [{pos, len} | rest], acc) do
    prefix_size = pos - acc.prev_end
    before = binary_part(line, acc.prev_end, prefix_size)
    new_output_pos = acc.output_size + prefix_size
    new_span = {new_output_pos, acc.rep_len}

    new_acc = %{
      acc
      | prev_end: pos + len,
        count: acc.count + 1,
        output: [acc.rep, before | acc.output],
        output_size: new_output_pos + acc.rep_len,
        spans: [new_span | acc.spans]
    }

    do_sub_spans_all(line, rest, new_acc)
  end

  @spec splice_match(binary(), {non_neg_integer(), non_neg_integer()}, binary()) :: binary()
  defp splice_match(line, {pos, len}, replacement) do
    before = binary_part(line, 0, pos)
    after_match = binary_part(line, pos + len, byte_size(line) - pos - len)
    before <> replacement <> after_match
  end

  @spec finish_substitution(binary(), non_neg_integer(), [binary()]) :: binary()
  defp finish_substitution(line, 0, []), do: line

  defp finish_substitution(line, prev_end, reversed_parts) do
    [binary_part(line, prev_end, byte_size(line) - prev_end) | reversed_parts]
    |> Enum.reverse()
    |> :binary.list_to_bin()
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec find_forward([String.t()], matcher(), position()) :: position() | nil
  defp find_forward(lines, matcher, {cur_line, cur_col}) do
    case search_forward(Enum.drop(lines, cur_line), matcher, cur_line, max(cur_col + 1, 0), :end) do
      nil -> search_forward(lines, matcher, 0, 0, cur_line + 1)
      pos -> pos
    end
  end

  @spec search_forward(
          [String.t()],
          matcher(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer() | :end
        ) :: position() | nil
  defp search_forward([], _matcher, _line, _col, _stop_line), do: nil
  defp search_forward(_lines, _matcher, line, _col, line), do: nil

  defp search_forward([line_text | rest], matcher, line, col, stop_line)
       when col >= byte_size(line_text) do
    search_forward(rest, matcher, line + 1, 0, stop_line)
  end

  defp search_forward([line_text | rest], matcher, line, col, stop_line) do
    searchable = binary_part(line_text, col, byte_size(line_text) - col)

    case match_in(searchable, matcher) do
      {pos, _len} -> {line, col + pos}
      nil -> search_forward(rest, matcher, line + 1, 0, stop_line)
    end
  end

  @spec find_backward([String.t()], matcher(), position()) :: position() | nil
  defp find_backward(lines, matcher, {cur_line, cur_col}) do
    # A match on the cursor line needs no reversed lines.
    line_text = Enum.at(lines, cur_line)

    case last_match_before(matches_in(line_text, matcher), cur_col - 1, nil) do
      nil ->
        search_backward(reverse_prefix(lines, cur_line, []), matcher, cur_line - 1) ||
          search_backward(Enum.reverse(lines), matcher, length(lines) - 1)

      col ->
        {cur_line, col}
    end
  end

  @spec reverse_prefix([String.t()], non_neg_integer(), [String.t()]) :: [String.t()]
  defp reverse_prefix(_lines, 0, acc), do: acc

  defp reverse_prefix([line | rest], count, acc) do
    reverse_prefix(rest, count - 1, [line | acc])
  end

  @spec search_backward([String.t()], matcher(), integer()) :: position() | nil
  defp search_backward([], _matcher, _line), do: nil

  defp search_backward([line_text | rest], matcher, line) do
    case last_match_before(matches_in(line_text, matcher), byte_size(line_text), nil) do
      nil -> search_backward(rest, matcher, line - 1)
      col -> {line, col}
    end
  end

  @spec last_match_before(
          [{non_neg_integer(), non_neg_integer()}],
          integer(),
          non_neg_integer() | nil
        ) :: non_neg_integer() | nil
  defp last_match_before([], _upper, last), do: last

  defp last_match_before([{pos, _len} | rest], upper, _last) when pos < upper do
    last_match_before(rest, upper, pos)
  end

  defp last_match_before([_match | rest], upper, last) do
    last_match_before(rest, upper, last)
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
