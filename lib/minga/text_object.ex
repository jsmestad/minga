defmodule Minga.TextObject do
  @moduledoc """
  Text object selection for Vim operator-pending mode.

  Each function takes a `GapBuffer.t()` and a cursor `position()` and returns
  a `{start_pos, end_pos}` range (both positions inclusive), or `nil` when no
  matching text object exists around the cursor.

  ## Word text objects

  * `inner_word/2` (`iw`) — the word (or whitespace run) under the cursor,
    without surrounding whitespace.
  * `a_word/2` (`aw`) — the word plus one surrounding whitespace run
    (trailing preferred; leading used when at end of line).

  ## Quote text objects

  * `inner_quotes/3` (`i"`, `i'`) — the content between the nearest enclosing
    quote pair on the current line, excluding the quote characters themselves.
  * `a_quotes/3` (`a"`, `a'`) — same range including the quote characters.

  ## Parenthesis / bracket text objects

  * `inner_parens/4` (`i(`, `i{`, `i[`) — content between the nearest
    enclosing open/close delimiter pair, excluding the delimiters. Handles
    nesting: e.g. `i(` inside `(a (b) c)` with cursor on `b` selects `a (b) c`.
  * `a_parens/4` (`a(`, `a{`, `a[`) — same range including the delimiters.

  Delimiter search spans multiple lines.
  """

  alias Minga.Buffer.GapBuffer

  @typedoc "A zero-indexed `{line, col}` position."
  @type position :: GapBuffer.position()

  @typedoc "An inclusive `{start_pos, end_pos}` range, or `nil` when not found."
  @type range :: {position(), position()} | nil

  # ── Word text objects ────────────────────────────────────────────────────────

  @doc """
  Returns the range of the word (or whitespace / symbol run) under the cursor,
  excluding any surrounding whitespace.

  Corresponds to Vim's `iw` motion in operator-pending mode.
  """
  @spec inner_word(GapBuffer.t(), position()) :: {position(), position()}
  def inner_word(buffer, {line, col}) do
    text = GapBuffer.line_at(buffer, line) || ""
    graphemes = String.graphemes(text)
    len = length(graphemes)
    clamped = min(col, max(0, len - 1))

    if len == 0 do
      {{line, 0}, {line, 0}}
    else
      char_at = Enum.at(graphemes, clamped, " ")
      classifier = classifier_for(char_at)

      start_col = scan_left(graphemes, clamped, classifier)
      end_col = scan_right(graphemes, clamped, classifier)

      {{line, start_col}, {line, end_col}}
    end
  end

  @doc """
  Returns the range of the word under the cursor plus one adjacent whitespace
  run (trailing preferred; leading used when the word is at the end of line).

  Corresponds to Vim's `aw` motion in operator-pending mode.
  """
  @spec a_word(GapBuffer.t(), position()) :: {position(), position()}
  def a_word(buffer, {line, col}) do
    text = GapBuffer.line_at(buffer, line) || ""
    graphemes = String.graphemes(text)
    len = length(graphemes)

    if len == 0 do
      {{line, 0}, {line, 0}}
    else
      clamped = min(col, max(0, len - 1))
      char_at = Enum.at(graphemes, clamped, " ")
      classifier = classifier_for(char_at)

      start_col = scan_left(graphemes, clamped, classifier)
      end_col = scan_right(graphemes, clamped, classifier)

      # Try to extend end_col over trailing whitespace.
      after_end = end_col + 1

      cond do
        # There is trailing whitespace — consume it.
        after_end < len and whitespace?(Enum.at(graphemes, after_end, "")) ->
          trail_end = scan_right(graphemes, after_end, &whitespace?/1)
          {{line, start_col}, {line, trail_end}}

        # No trailing whitespace — consume leading whitespace instead.
        start_col > 0 and whitespace?(Enum.at(graphemes, start_col - 1, "")) ->
          lead_start = scan_left(graphemes, start_col - 1, &whitespace?/1)
          {{line, lead_start}, {line, end_col}}

        # Nothing to absorb — return the word alone.
        true ->
          {{line, start_col}, {line, end_col}}
      end
    end
  end

  # ── Quote text objects ────────────────────────────────────────────────────────

  @doc """
  Returns the range of text **inside** the nearest enclosing quote pair on the
  cursor's line, not including the quote characters.

  Returns `nil` if no enclosing quote pair is found.

  Corresponds to Vim's `i"` / `i'` motions.
  """
  @spec inner_quotes(GapBuffer.t(), position(), String.t()) :: range()
  def inner_quotes(buffer, {line, col}, quote_char) when is_binary(quote_char) do
    text = GapBuffer.line_at(buffer, line) || ""
    graphemes = String.graphemes(text)

    case find_quote_pair(graphemes, col, quote_char) do
      nil ->
        nil

      {open_idx, close_idx} when close_idx > open_idx + 1 ->
        {{line, open_idx + 1}, {line, close_idx - 1}}

      {open_idx, close_idx} when close_idx == open_idx + 1 ->
        # Empty — return a zero-width range just after the opening quote.
        {{line, open_idx + 1}, {line, open_idx}}

      _ ->
        nil
    end
  end

  @doc """
  Returns the range of text **including** the nearest enclosing quote pair on
  the cursor's line.

  Returns `nil` if no enclosing quote pair is found.

  Corresponds to Vim's `a"` / `a'` motions.
  """
  @spec a_quotes(GapBuffer.t(), position(), String.t()) :: range()
  def a_quotes(buffer, {line, col}, quote_char) when is_binary(quote_char) do
    text = GapBuffer.line_at(buffer, line) || ""
    graphemes = String.graphemes(text)

    case find_quote_pair(graphemes, col, quote_char) do
      nil -> nil
      {open_idx, close_idx} -> {{line, open_idx}, {line, close_idx}}
    end
  end

  # ── Paren / bracket text objects ──────────────────────────────────────────────

  @doc """
  Returns the range of text **inside** the nearest enclosing delimiter pair
  around the cursor, not including the delimiters.

  Searches across multiple lines. Handles nesting (the cursor's depth relative
  to the nearest enclosing pair is tracked).

  Returns `nil` if no enclosing pair is found.

  Corresponds to Vim's `i(`, `i{`, `i[`, etc.
  """
  @spec inner_parens(GapBuffer.t(), position(), String.t(), String.t()) :: range()
  def inner_parens(buffer, position, open_char, close_char)
      when is_binary(open_char) and is_binary(close_char) do
    case find_delimited_pair(buffer, position, open_char, close_char) do
      nil ->
        nil

      {{open_line, open_col}, {close_line, close_col}} ->
        # Start just after the opening delimiter.
        start_pos = advance_position(buffer, {open_line, open_col})
        # End just before the closing delimiter.
        end_pos = retreat_position(buffer, {close_line, close_col})

        case {start_pos, end_pos} do
          {nil, _} -> nil
          {_, nil} -> nil
          {s, e} -> {s, e}
        end
    end
  end

  @doc """
  Returns the range of text **including** the nearest enclosing delimiter pair
  around the cursor.

  Searches across multiple lines. Handles nesting.

  Returns `nil` if no enclosing pair is found.

  Corresponds to Vim's `a(`, `a{`, `a[`, etc.
  """
  @spec a_parens(GapBuffer.t(), position(), String.t(), String.t()) :: range()
  def a_parens(buffer, position, open_char, close_char)
      when is_binary(open_char) and is_binary(close_char) do
    case find_delimited_pair(buffer, position, open_char, close_char) do
      nil -> nil
      pair -> pair
    end
  end

  # ── Private — word helpers ────────────────────────────────────────────────────

  # Returns the character classifier function for a given character.
  @spec classifier_for(String.t()) :: (String.t() -> boolean())
  defp classifier_for(char) do
    cond do
      word_char?(char) -> &word_char?/1
      whitespace?(char) -> &whitespace?/1
      true -> fn c -> not word_char?(c) and not whitespace?(c) end
    end
  end

  @spec word_char?(String.t()) :: boolean()
  defp word_char?(<<c::utf8>>)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) or c == ?_,
       do: true

  defp word_char?(_), do: false

  @spec whitespace?(String.t()) :: boolean()
  defp whitespace?(" "), do: true
  defp whitespace?("\t"), do: true
  defp whitespace?(_), do: false

  # Scans left from `idx` while `pred` holds; returns the leftmost matching index.
  @spec scan_left([String.t()], non_neg_integer(), (String.t() -> boolean())) ::
          non_neg_integer()
  defp scan_left(_graphemes, 0, _pred), do: 0

  defp scan_left(graphemes, idx, pred) do
    left = idx - 1
    char = Enum.at(graphemes, left, "")

    if pred.(char) do
      scan_left(graphemes, left, pred)
    else
      idx
    end
  end

  # Scans right from `idx` while `pred` holds; returns the rightmost matching index.
  @spec scan_right([String.t()], non_neg_integer(), (String.t() -> boolean())) ::
          non_neg_integer()
  defp scan_right(graphemes, idx, pred) do
    right = idx + 1
    char = Enum.at(graphemes, right, "")

    if pred.(char) do
      scan_right(graphemes, right, pred)
    else
      idx
    end
  end

  # ── Private — quote helpers ───────────────────────────────────────────────────

  # Finds the innermost quote pair enclosing `col` on the given grapheme list.
  # Returns `{open_idx, close_idx}` or `nil`.
  @spec find_quote_pair([String.t()], non_neg_integer(), String.t()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp find_quote_pair(graphemes, col, quote_char) do
    indexed = Enum.with_index(graphemes)

    quote_positions =
      indexed
      |> Enum.filter(fn {g, _i} -> g == quote_char end)
      |> Enum.map(fn {_g, i} -> i end)

    # Find pairs: consecutive quote positions form open/close pairs.
    pairs = build_pairs(quote_positions)

    # Find the innermost pair that encloses col (open < col <= close  OR  cursor on quote).
    pairs
    |> Enum.filter(fn {open, close} ->
      (open < col and col < close) or col == open or col == close
    end)
    |> Enum.min_by(fn {open, close} -> close - open end, fn -> nil end)
  end

  # Groups a list of sorted quote positions into open/close pairs.
  @spec build_pairs([non_neg_integer()]) :: [{non_neg_integer(), non_neg_integer()}]
  defp build_pairs([]), do: []
  defp build_pairs([_]), do: []

  defp build_pairs([open, close | rest]) do
    [{open, close} | build_pairs(rest)]
  end

  # ── Private — paren helpers ───────────────────────────────────────────────────

  # Finds the innermost open/close delimiter pair enclosing `position`.
  # Returns `{{open_line, open_col}, {close_line, close_col}}` or `nil`.
  @spec find_delimited_pair(GapBuffer.t(), position(), String.t(), String.t()) ::
          {position(), position()} | nil
  defp find_delimited_pair(buffer, {line, col}, open_char, close_char) do
    content = GapBuffer.content(buffer)
    all_lines = String.split(content, "\n")
    flat = flatten_with_positions(all_lines)

    # Find the cursor's absolute index in the flat list.
    cursor_abs = find_abs_index(flat, line, col)

    case cursor_abs do
      nil ->
        nil

      abs_idx ->
        # Search backward for an unmatched open delimiter.
        case find_open(flat, abs_idx - 1, open_char, close_char, 0) do
          nil ->
            nil

          open_abs ->
            {open_line, open_col} = elem(Enum.at(flat, open_abs), 1)

            # Search forward from the open delimiter for the matching close.
            case find_close(flat, open_abs + 1, open_char, close_char, 1) do
              nil ->
                nil

              close_abs ->
                {close_line, close_col} = elem(Enum.at(flat, close_abs), 1)
                {{open_line, open_col}, {close_line, close_col}}
            end
        end
    end
  end

  # Flattens lines into a list of `{grapheme, {line, col}}` tuples.
  @spec flatten_with_positions([[String.t()]] | [String.t()]) ::
          [{String.t(), position()}]
  defp flatten_with_positions(lines) do
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line_text, line_idx} ->
      line_text
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.map(fn {g, col} -> {g, {line_idx, col}} end)
    end)
  end

  @spec find_abs_index([{String.t(), position()}], non_neg_integer(), non_neg_integer()) ::
          non_neg_integer() | nil
  defp find_abs_index(flat, target_line, target_col) do
    flat
    |> Enum.find_index(fn {_g, {l, c}} -> l == target_line and c == target_col end)
  end

  # Scans backward for an unmatched open delimiter. `depth` starts at 0.
  @spec find_open(
          [{String.t(), position()}],
          integer(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: non_neg_integer() | nil
  defp find_open(_flat, idx, _open, _close, _depth) when idx < 0, do: nil

  defp find_open(flat, idx, open_char, close_char, depth) do
    {g, _pos} = Enum.at(flat, idx)

    cond do
      g == close_char ->
        find_open(flat, idx - 1, open_char, close_char, depth + 1)

      g == open_char and depth > 0 ->
        find_open(flat, idx - 1, open_char, close_char, depth - 1)

      g == open_char ->
        idx

      true ->
        find_open(flat, idx - 1, open_char, close_char, depth)
    end
  end

  # Scans forward for the matching close delimiter. `depth` starts at 1 (we're
  # already inside one open delimiter).
  @spec find_close(
          [{String.t(), position()}],
          non_neg_integer(),
          String.t(),
          String.t(),
          pos_integer()
        ) :: non_neg_integer() | nil
  defp find_close(flat, idx, open_char, close_char, depth) do
    case Enum.at(flat, idx) do
      nil ->
        nil

      {g, _pos} ->
        cond do
          g == open_char ->
            find_close(flat, idx + 1, open_char, close_char, depth + 1)

          g == close_char and depth > 1 ->
            find_close(flat, idx + 1, open_char, close_char, depth - 1)

          g == close_char ->
            idx

          true ->
            find_close(flat, idx + 1, open_char, close_char, depth)
        end
    end
  end

  # Advances a position by one column (within the same line).
  # Returns `nil` if there is no next position on the line.
  @spec advance_position(GapBuffer.t(), position()) :: position() | nil
  defp advance_position(buffer, {line, col}) do
    text = GapBuffer.line_at(buffer, line) || ""
    len = String.length(text)

    cond do
      col + 1 < len -> {line, col + 1}
      # Try start of next line
      true ->
        next_line = line + 1
        next_text = GapBuffer.line_at(buffer, next_line)

        case next_text do
          nil -> nil
          _ -> {next_line, 0}
        end
    end
  end

  # Retreats a position by one grapheme. When col is 0, moves to the last
  # grapheme of the previous line. Returns `nil` when already at the very
  # start of the buffer.
  @spec retreat_position(GapBuffer.t(), position()) :: position() | nil
  defp retreat_position(_buffer, {0, 0}), do: nil

  defp retreat_position(buffer, {line, 0}) when line > 0 do
    prev_text = GapBuffer.line_at(buffer, line - 1) || ""
    prev_len = String.length(prev_text)

    if prev_len > 0 do
      {line - 1, prev_len - 1}
    else
      {line - 1, 0}
    end
  end

  defp retreat_position(_buffer, {line, col}), do: {line, col - 1}
end
