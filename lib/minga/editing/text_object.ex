defmodule Minga.Editing.TextObject do
  @moduledoc """
  Text object selection for Vim operator-pending mode.

  Each function takes a `Readable.t()` and a cursor `position()` and returns
  a `{start_pos, end_pos}` range (both positions inclusive), or `nil` when no
  matching text object exists around the cursor.

  All positions use byte-indexed columns (`{line, byte_col}`).

  ## Word text objects

  * `inner_word/2` (`iw`) — the word (or whitespace run) under the cursor,
    without surrounding whitespace.
  * `a_word/2` (`aw`) — the word plus one surrounding whitespace run
    (trailing preferred; leading used when at end of line).

  ## Paragraph text objects

  * `inner_paragraph/2` (`ip`) — contiguous non-blank lines around the cursor,
    or the current blank-line run when the cursor is on a blank line.
  * `a_paragraph/2` (`ap`) — the paragraph plus one surrounding blank line,
    preferring a trailing blank line and using a leading blank at end of file.

  ## Sentence text objects

  * `inner_sentence/2` (`is`) — the current sentence without trailing whitespace.
  * `a_sentence/2` (`as`) — the current sentence including trailing whitespace.

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

  alias Minga.Buffer.{Document, Lines, Position}
  alias Minga.Core.Unicode
  alias Minga.Editing.Motion.Helpers
  alias Minga.Editing.Text.Readable

  @typedoc "A zero-indexed `{line, byte_col}` position."
  @type position :: {non_neg_integer(), non_neg_integer()}

  @typedoc "An inclusive `{start_pos, end_pos}` range, or `nil` when not found."
  @type range :: {position(), position()} | nil

  @typep sentence_tokens :: tuple()
  @typep delimiter_open :: {position(), non_neg_integer()}
  @typep delimiter_open_scan ::
           {:found, position(), non_neg_integer()} | {:miss, non_neg_integer()}
  @typep delimiter_scan_result ::
           {:found, position()}
           | {:cont, non_neg_integer(), non_neg_integer(), pos_integer(), non_neg_integer()}

  @doc "Projects one exact pending review region onto Vim's inclusive selection coordinates."
  @spec review_change(Document.t(), {non_neg_integer(), non_neg_integer()}, :inner | :around) ::
          {:charwise | :linewise, position(), position()} | nil
  def review_change(%Document{} = doc, {first, stop}, :inner) when first < stop do
    {:charwise, review_character_at(doc, first), review_character_at(doc, stop - 1)}
  end

  def review_change(%Document{}, {_first, _stop}, :inner), do: nil

  def review_change(%Document{} = doc, {first, stop}, :around) do
    {first_line, _} = Position.from_point(doc, first)
    {last_line, _} = Position.from_point(doc, max(first, stop - 1))
    {:linewise, {first_line, 0}, {last_line, 0}}
  end

  @spec review_character_at(Document.t(), non_neg_integer()) :: position()
  defp review_character_at(doc, point) do
    {line, column} = Position.from_point(doc, point)
    text = Lines.fetch(doc, line)

    column =
      if column < byte_size(text),
        do: Unicode.prev_grapheme_byte_offset(text, column + 1),
        else: byte_size(text)

    {line, column}
  end

  # ── Word text objects ────────────────────────────────────────────────────────

  @doc """
  Returns the range of the word (or whitespace / symbol run) under the cursor,
  excluding any surrounding whitespace.

  Corresponds to Vim's `iw` motion in operator-pending mode.
  """
  @spec inner_word(Readable.t(), position()) :: {position(), position()}
  def inner_word(buffer, {line, col}) do
    text = Readable.line_at(buffer, line) || ""
    {graphemes, byte_offsets} = Helpers.graphemes_with_byte_offsets(text)
    len = tuple_size(graphemes)

    if len == 0 do
      {{line, 0}, {line, 0}}
    else
      g_idx = Helpers.byte_offset_to_grapheme_index(byte_offsets, col)
      clamped = min(g_idx, max(0, len - 1))
      char_at = elem(graphemes, clamped)
      classifier = classifier_for(char_at)

      start_g = scan_left_tuple(graphemes, clamped, classifier)
      end_g = scan_right_tuple(graphemes, clamped, classifier)

      start_byte = elem(byte_offsets, start_g)
      end_byte = elem(byte_offsets, end_g)

      {{line, start_byte}, {line, end_byte}}
    end
  end

  @doc """
  Returns the range of the word under the cursor plus one adjacent whitespace
  run (trailing preferred; leading used when the word is at the end of line).

  Corresponds to Vim's `aw` motion in operator-pending mode.
  """
  @spec a_word(Readable.t(), position()) :: {position(), position()}
  def a_word(buffer, {line, col}) do
    text = Readable.line_at(buffer, line) || ""
    {graphemes, byte_offsets} = Helpers.graphemes_with_byte_offsets(text)
    len = tuple_size(graphemes)

    if len == 0 do
      {{line, 0}, {line, 0}}
    else
      g_idx = Helpers.byte_offset_to_grapheme_index(byte_offsets, col)
      clamped = min(g_idx, max(0, len - 1))
      char_at = elem(graphemes, clamped)
      classifier = classifier_for(char_at)

      start_g = scan_left_tuple(graphemes, clamped, classifier)
      end_g = scan_right_tuple(graphemes, clamped, classifier)

      {final_start_g, final_end_g} =
        around_word_indexes(graphemes, start_g, end_g)

      start_byte = elem(byte_offsets, final_start_g)
      end_byte = elem(byte_offsets, final_end_g)

      {{line, start_byte}, {line, end_byte}}
    end
  end

  # ── Paragraph text objects ────────────────────────────────────────────────────

  @doc """
  Returns the current paragraph range without surrounding blank lines.

  A paragraph is a contiguous run of non-blank lines. When the cursor is on a
  blank line, the current blank-line run is returned so operators still have a
  stable linewise target.

  Corresponds to Vim's `ip` text object.
  """
  @spec inner_paragraph(Readable.t(), position()) :: range()
  def inner_paragraph(buffer, position) do
    case paragraph_bounds(buffer, position) do
      nil -> nil
      {first_line, last_line} -> line_range(buffer, first_line, last_line)
    end
  end

  @doc """
  Returns the current paragraph plus one surrounding blank line.

  A trailing blank line is preferred. If the paragraph reaches end of file and
  has a leading blank line, that leading blank is included instead.

  Corresponds to Vim's `ap` text object.
  """
  @spec a_paragraph(Readable.t(), position()) :: range()
  def a_paragraph(buffer, {line, _col} = position) do
    case paragraph_bounds(buffer, position) do
      nil ->
        nil

      {first_line, last_line} ->
        line_text = Readable.line_at(buffer, line) || ""

        if blank_line?(line_text) do
          around_blank_paragraph_range(buffer, first_line, last_line)
        else
          around_paragraph_range(buffer, first_line, last_line)
        end
    end
  end

  # ── Sentence text objects ─────────────────────────────────────────────────────

  @doc """
  Returns the current sentence without trailing whitespace.

  Sentences end at `.`, `!`, or `?`, may include closing delimiters after the
  punctuation, and stop at paragraph boundaries.

  Corresponds to Vim's `is` text object.
  """
  @spec inner_sentence(Readable.t(), position()) :: range()
  def inner_sentence(buffer, position), do: sentence_range(buffer, position, :inner)

  @doc """
  Returns the current sentence including trailing whitespace.

  When the cursor is on whitespace between two sentences, this follows Vim's
  around-sentence behavior and selects the following sentence.

  Corresponds to Vim's `as` text object.
  """
  @spec a_sentence(Readable.t(), position()) :: range()
  def a_sentence(buffer, position), do: sentence_range(buffer, position, :around)

  # ── Quote text objects ────────────────────────────────────────────────────────

  @doc """
  Returns the range of text **inside** the nearest enclosing quote pair on the
  cursor's line, not including the quote characters.

  Returns `nil` if no enclosing quote pair is found.

  Corresponds to Vim's `i"` / `i'` motions.
  """
  @spec inner_quotes(Readable.t(), position(), String.t()) :: range()
  def inner_quotes(buffer, {line, col}, quote_char) when is_binary(quote_char) do
    text = Readable.line_at(buffer, line) || ""
    {graphemes, byte_offsets} = Helpers.graphemes_with_byte_offsets(text)
    g_col = Helpers.byte_offset_to_grapheme_index(byte_offsets, col)

    case find_quote_pair(graphemes, g_col, quote_char) do
      nil ->
        nil

      {open_g, close_g} when close_g > open_g + 1 ->
        {{line, elem(byte_offsets, open_g + 1)}, {line, elem(byte_offsets, close_g - 1)}}

      {open_g, close_g} when close_g == open_g + 1 ->
        # Empty — return a zero-width range just after the opening quote.
        {{line, elem(byte_offsets, open_g + 1)}, {line, elem(byte_offsets, open_g)}}

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
  @spec a_quotes(Readable.t(), position(), String.t()) :: range()
  def a_quotes(buffer, {line, col}, quote_char) when is_binary(quote_char) do
    text = Readable.line_at(buffer, line) || ""
    {graphemes, byte_offsets} = Helpers.graphemes_with_byte_offsets(text)
    g_col = Helpers.byte_offset_to_grapheme_index(byte_offsets, col)

    case find_quote_pair(graphemes, g_col, quote_char) do
      nil ->
        nil

      {open_g, close_g} ->
        {{line, elem(byte_offsets, open_g)}, {line, elem(byte_offsets, close_g)}}
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
  @spec inner_parens(Readable.t(), position(), String.t(), String.t()) :: range()
  def inner_parens(buffer, position, open_char, close_char)
      when is_binary(open_char) and is_binary(close_char) do
    case find_delimited_pair(buffer, position, open_char, close_char) do
      nil ->
        nil

      {{open_line, open_col}, {close_line, close_col}} ->
        start_pos = advance_position(buffer, {open_line, open_col})
        end_pos = retreat_position(buffer, {close_line, close_col})

        case {start_pos, end_pos} do
          {nil, _} -> nil
          {_, nil} -> nil
          # An empty pair (e.g. `()`) advances the start past the retreated end,
          # producing an inverted range. There is no inner content, so report no
          # range; `ci(` still enters insert via the mode transition.
          {s, e} when s > e -> nil
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
  @spec a_parens(Readable.t(), position(), String.t(), String.t()) :: range()
  def a_parens(buffer, position, open_char, close_char)
      when is_binary(open_char) and is_binary(close_char) do
    find_delimited_pair(buffer, position, open_char, close_char)
  end

  # ── Tree-sitter structural text objects ────────────────────────────────────────
  #
  # These query the Zig parser for structural ranges using textobjects.scm.
  # Helix uses @X.inside / @X.around capture names (e.g., @function.inside).

  @typedoc "Structural text object type."
  @type structural_type :: :function | :class | :parameter | :block | :comment | :test

  @typedoc "Raw tree-sitter textobject result: `{start_row, start_col, end_row, end_col}` or `nil`."
  @type tree_range ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil

  @doc """
  Converts a raw tree-sitter textobject range into an inclusive Vim-style
  inner range.

  The caller is responsible for querying the parser (via
  `Parser.Manager.request_textobject/4`) and passing the result here.
  Returns `nil` when `tree_data` is `nil` (no match found by the parser).
  """
  @spec structural_inner(tree_range()) :: range()
  def structural_inner(tree_data) do
    convert_tree_range(tree_data)
  end

  @doc """
  Converts a raw tree-sitter textobject range into an inclusive Vim-style
  outer range.

  Semantically identical to `structural_inner/1` (tree-sitter already
  distinguishes inside vs around via the capture name). This function exists
  so callers can express intent clearly.
  """
  @spec structural_around(tree_range()) :: range()
  def structural_around(tree_data) do
    convert_tree_range(tree_data)
  end

  @spec convert_tree_range(tree_range()) :: range()
  defp convert_tree_range(nil), do: nil

  defp convert_tree_range({start_row, start_col, end_row, end_col}) do
    # Zig returns byte columns. The end position from tree-sitter is
    # exclusive, so we subtract 1 to make it inclusive for Vim semantics.
    end_pos = adjust_end_position(end_row, end_col)
    {{start_row, start_col}, end_pos}
  end

  # Tree-sitter end positions are exclusive. Convert to inclusive for Vim.
  @spec adjust_end_position(non_neg_integer(), non_neg_integer()) :: position()
  defp adjust_end_position(row, 0) when row > 0, do: {row - 1, 0}
  defp adjust_end_position(row, col) when col > 0, do: {row, col - 1}
  defp adjust_end_position(row, col), do: {row, col}

  # ── Private — paragraph helpers ───────────────────────────────────────────────

  @spec paragraph_bounds(Readable.t(), position()) :: {non_neg_integer(), non_neg_integer()} | nil
  defp paragraph_bounds(buffer, {line, _col}) do
    if empty_buffer?(buffer) do
      nil
    else
      paragraph_bounds_for_line(buffer, line, Readable.line_at(buffer, line))
    end
  end

  @spec paragraph_bounds_for_line(Readable.t(), non_neg_integer(), String.t() | nil) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp paragraph_bounds_for_line(_buffer, _line, nil), do: nil

  defp paragraph_bounds_for_line(buffer, line, text) do
    if blank_line?(text) do
      {blank_run_start(buffer, line), blank_run_end(buffer, line)}
    else
      {paragraph_start(buffer, line), paragraph_end(buffer, line)}
    end
  end

  @spec empty_buffer?(Readable.t()) :: boolean()
  defp empty_buffer?(buffer) do
    Readable.line_count(buffer) == 1 and (Readable.line_at(buffer, 0) || "") == ""
  end

  @spec paragraph_start(Readable.t(), non_neg_integer()) :: non_neg_integer()
  defp paragraph_start(_buffer, 0), do: 0

  defp paragraph_start(buffer, line) do
    prev_line = line - 1

    if blank_line?(Readable.line_at(buffer, prev_line) || "") do
      line
    else
      paragraph_start(buffer, prev_line)
    end
  end

  @spec paragraph_end(Readable.t(), non_neg_integer()) :: non_neg_integer()
  defp paragraph_end(buffer, line) do
    next_line = line + 1

    case Readable.line_at(buffer, next_line) do
      nil ->
        line

      text ->
        if blank_line?(text), do: line, else: paragraph_end(buffer, next_line)
    end
  end

  @spec blank_run_start(Readable.t(), non_neg_integer()) :: non_neg_integer()
  defp blank_run_start(_buffer, 0), do: 0

  defp blank_run_start(buffer, line) do
    prev_line = line - 1

    if blank_line?(Readable.line_at(buffer, prev_line) || "") do
      blank_run_start(buffer, prev_line)
    else
      line
    end
  end

  @spec blank_run_end(Readable.t(), non_neg_integer()) :: non_neg_integer()
  defp blank_run_end(buffer, line) do
    next_line = line + 1

    case Readable.line_at(buffer, next_line) do
      nil ->
        line

      text ->
        if blank_line?(text), do: blank_run_end(buffer, next_line), else: line
    end
  end

  @spec around_paragraph_range(Readable.t(), non_neg_integer(), non_neg_integer()) :: range()
  defp around_paragraph_range(buffer, first_line, last_line) do
    line_count = Readable.line_count(buffer)

    extended =
      case paragraph_extension(buffer, first_line, last_line, line_count) do
        :trailing -> {first_line, last_line + 1}
        :leading -> {first_line - 1, last_line}
        :none -> {first_line, last_line}
      end

    {range_first, range_last} = extended
    line_range(buffer, range_first, range_last)
  end

  @spec around_blank_paragraph_range(Readable.t(), non_neg_integer(), non_neg_integer()) ::
          range()
  defp around_blank_paragraph_range(buffer, first_blank_line, last_blank_line) do
    case next_non_blank_line(buffer, last_blank_line + 1) do
      nil ->
        case previous_non_blank_line(buffer, first_blank_line - 1) do
          nil ->
            line_range(buffer, first_blank_line, last_blank_line)

          prev_line ->
            line_range(buffer, paragraph_start(buffer, prev_line), last_blank_line)
        end

      next_line ->
        around_paragraph_range(buffer, next_line, paragraph_end(buffer, next_line))
    end
  end

  @spec paragraph_extension(
          Readable.t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer()
        ) :: :trailing | :leading | :none
  defp paragraph_extension(buffer, _first_line, last_line, line_count)
       when last_line + 1 < line_count do
    if blank_line?(Readable.line_at(buffer, last_line + 1) || ""), do: :trailing, else: :none
  end

  defp paragraph_extension(buffer, first_line, _last_line, _line_count) when first_line > 0 do
    if blank_line?(Readable.line_at(buffer, first_line - 1) || ""), do: :leading, else: :none
  end

  defp paragraph_extension(_buffer, _first_line, _last_line, _line_count), do: :none

  @spec line_range(Readable.t(), non_neg_integer(), non_neg_integer()) :: range()
  defp line_range(buffer, first_line, last_line) do
    {{first_line, 0}, {last_line, last_line_col(buffer, last_line)}}
  end

  @spec last_line_col(Readable.t(), non_neg_integer()) :: non_neg_integer()
  defp last_line_col(buffer, line) do
    case Readable.line_at(buffer, line) do
      nil -> 0
      "" -> 0
      text -> Unicode.last_grapheme_byte_offset(text)
    end
  end

  @spec next_non_blank_line(Readable.t(), integer()) :: non_neg_integer() | nil
  defp next_non_blank_line(buffer, line) do
    case Readable.line_at(buffer, line) do
      nil ->
        nil

      text ->
        if blank_line?(text), do: next_non_blank_line(buffer, line + 1), else: line
    end
  end

  @spec previous_non_blank_line(Readable.t(), integer()) :: non_neg_integer() | nil
  defp previous_non_blank_line(_buffer, line) when line < 0, do: nil

  defp previous_non_blank_line(buffer, line) do
    case Readable.line_at(buffer, line) do
      nil ->
        previous_non_blank_line(buffer, line - 1)

      text ->
        if blank_line?(text), do: previous_non_blank_line(buffer, line - 1), else: line
    end
  end

  @spec blank_line?(String.t()) :: boolean()
  defp blank_line?(text), do: String.trim(text) == ""

  # ── Private — sentence helpers ────────────────────────────────────────────────

  @spec sentence_range(Readable.t(), position(), :inner | :around) :: range()
  defp sentence_range(buffer, position, kind) do
    case sentence_context(buffer, position) do
      nil ->
        nil

      {tokens, cursor_idx} ->
        start = next_non_whitespace_index(tokens, 0)
        select_sentence(tokens, start, cursor_idx, kind)
    end
  end

  @spec sentence_context(Readable.t(), position()) :: {sentence_tokens(), non_neg_integer()} | nil
  defp sentence_context(buffer, position) do
    case paragraph_bounds(buffer, position) do
      nil -> nil
      bounds -> sentence_context_in_bounds(buffer, position, bounds)
    end
  end

  @spec sentence_context_in_bounds(
          Readable.t(),
          position(),
          {non_neg_integer(), non_neg_integer()}
        ) :: {sentence_tokens(), non_neg_integer()} | nil
  defp sentence_context_in_bounds(buffer, {line, _col} = position, {first_line, last_line}) do
    line_text = Readable.line_at(buffer, line) || ""

    if blank_line?(line_text) do
      nil
    else
      tokens = sentence_tokens(buffer, first_line, last_line)
      cursor_idx = sentence_cursor_index(tokens, position)
      if cursor_idx == nil, do: nil, else: {tokens, cursor_idx}
    end
  end

  @spec sentence_tokens(Readable.t(), non_neg_integer(), non_neg_integer()) :: sentence_tokens()
  defp sentence_tokens(buffer, first_line, last_line) do
    first_line..last_line
    |> Enum.reduce([], fn line, acc -> prepend_sentence_line(buffer, line, last_line, acc) end)
    |> Enum.reverse()
    |> List.to_tuple()
  end

  @spec prepend_sentence_line(
          Readable.t(),
          non_neg_integer(),
          non_neg_integer(),
          [{String.t(), position()}]
        ) :: [{String.t(), position()}]
  defp prepend_sentence_line(buffer, line, last_line, acc) do
    text = Readable.line_at(buffer, line) || ""
    acc = prepend_graphemes(text, line, 0, acc)

    if line < last_line, do: [{"\n", {line, byte_size(text)}} | acc], else: acc
  end

  @spec prepend_graphemes(String.t(), non_neg_integer(), non_neg_integer(), [
          {String.t(), position()}
        ]) :: [{String.t(), position()}]
  defp prepend_graphemes(text, line_idx, byte_pos, acc) do
    case String.next_grapheme(text) do
      {g, rest} ->
        g_size = byte_size(text) - byte_size(rest)

        prepend_graphemes(rest, line_idx, byte_pos + g_size, [
          {g, {line_idx, byte_pos}} | acc
        ])

      nil ->
        acc
    end
  end

  # Token positions are ordered by line and byte column; the last token is the fallback.
  @spec sentence_cursor_index(sentence_tokens(), position()) :: non_neg_integer() | nil
  defp sentence_cursor_index({}, _position), do: nil

  defp sentence_cursor_index(tokens, position) do
    sentence_cursor_index(tokens, position, 0, tuple_size(tokens) - 1)
  end

  @spec sentence_cursor_index(
          sentence_tokens(),
          position(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp sentence_cursor_index(_tokens, _position, last_idx, last_idx), do: last_idx

  defp sentence_cursor_index(tokens, position, idx, last_idx) do
    {_char, token_pos} = elem(tokens, idx)

    if token_pos >= position do
      idx
    else
      sentence_cursor_index(tokens, position, idx + 1, last_idx)
    end
  end

  @spec select_sentence(
          sentence_tokens(),
          non_neg_integer() | nil,
          non_neg_integer(),
          :inner | :around
        ) :: range()
  defp select_sentence(_tokens, nil, _cursor, _kind), do: nil

  defp select_sentence(tokens, start, cursor, kind) do
    inner_end = sentence_end_or_paragraph_end(tokens, start)
    trailing_end = trailing_whitespace_end(tokens, inner_end + 1)
    select_sentence_span(tokens, {start, inner_end, trailing_end}, cursor, kind)
  end

  @spec select_sentence_span(
          sentence_tokens(),
          {non_neg_integer(), non_neg_integer(), non_neg_integer()},
          non_neg_integer(),
          :inner | :around
        ) :: range()
  defp select_sentence_span(tokens, {start, inner_end, _trailing}, cursor, :inner)
       when cursor <= inner_end do
    range_from_token_indices(tokens, leading_start(start, cursor), inner_end)
  end

  defp select_sentence_span(tokens, {start, inner_end, trailing}, cursor, :around)
       when cursor <= inner_end do
    range_from_token_indices(tokens, leading_start(start, cursor), trailing)
  end

  defp select_sentence_span(tokens, {_start, inner_end, trailing}, cursor, :inner)
       when cursor <= trailing do
    range_from_token_indices(tokens, inner_end + 1, trailing)
  end

  defp select_sentence_span(tokens, {_start, inner_end, trailing}, cursor, :around)
       when cursor <= trailing and trailing + 1 < tuple_size(tokens) do
    next_end = sentence_end_or_paragraph_end(tokens, trailing + 1)
    next_trailing = trailing_whitespace_end(tokens, next_end + 1)
    range_from_token_indices(tokens, inner_end + 1, next_trailing)
  end

  defp select_sentence_span(tokens, {_start, _inner_end, trailing}, cursor, kind)
       when trailing + 1 < tuple_size(tokens) do
    select_sentence(tokens, trailing + 1, cursor, kind)
  end

  defp select_sentence_span(_tokens, _span, _cursor, _kind), do: nil

  @spec leading_start(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp leading_start(start, cursor) when cursor < start, do: 0
  defp leading_start(start, _cursor), do: start

  @spec sentence_end_or_paragraph_end(sentence_tokens(), non_neg_integer()) :: non_neg_integer()
  defp sentence_end_or_paragraph_end(tokens, start_idx) do
    case find_sentence_end(tokens, start_idx) do
      nil -> last_non_whitespace_index(tokens, tuple_size(tokens) - 1)
      end_idx -> end_idx
    end
  end

  @spec find_sentence_end(sentence_tokens(), non_neg_integer()) :: non_neg_integer() | nil
  defp find_sentence_end(tokens, idx) when idx >= tuple_size(tokens), do: nil

  defp find_sentence_end(tokens, idx) do
    {char, _pos} = elem(tokens, idx)

    if sentence_terminal?(char) do
      sentence_end_after_terminal(tokens, idx)
    else
      find_sentence_end(tokens, idx + 1)
    end
  end

  @spec sentence_end_after_terminal(sentence_tokens(), non_neg_integer()) ::
          non_neg_integer() | nil
  defp sentence_end_after_terminal(tokens, idx) do
    close_idx = closing_delimiter_end(tokens, idx + 1)

    if sentence_boundary_after?(tokens, close_idx + 1) do
      close_idx
    else
      find_sentence_end(tokens, idx + 1)
    end
  end

  @spec closing_delimiter_end(sentence_tokens(), non_neg_integer()) :: non_neg_integer()
  defp closing_delimiter_end(tokens, idx) when idx >= tuple_size(tokens), do: idx - 1

  defp closing_delimiter_end(tokens, idx) do
    {char, _pos} = elem(tokens, idx)

    if closing_sentence_delimiter?(char) do
      closing_delimiter_end(tokens, idx + 1)
    else
      idx - 1
    end
  end

  @spec sentence_boundary_after?(sentence_tokens(), non_neg_integer()) :: boolean()
  defp sentence_boundary_after?(tokens, idx) when idx >= tuple_size(tokens), do: true

  defp sentence_boundary_after?(tokens, idx) do
    {char, _pos} = elem(tokens, idx)
    sentence_whitespace?(char)
  end

  @spec trailing_whitespace_end(sentence_tokens(), non_neg_integer()) :: non_neg_integer()
  defp trailing_whitespace_end(tokens, idx) when idx >= tuple_size(tokens),
    do: tuple_size(tokens) - 1

  defp trailing_whitespace_end(tokens, idx) do
    {char, _pos} = elem(tokens, idx)

    if sentence_whitespace?(char) do
      trailing_whitespace_end(tokens, idx + 1)
    else
      idx - 1
    end
  end

  @spec next_non_whitespace_index(sentence_tokens(), non_neg_integer()) :: non_neg_integer() | nil
  defp next_non_whitespace_index(tokens, idx) when idx >= tuple_size(tokens), do: nil

  defp next_non_whitespace_index(tokens, idx) do
    {char, _pos} = elem(tokens, idx)

    if sentence_whitespace?(char) do
      next_non_whitespace_index(tokens, idx + 1)
    else
      idx
    end
  end

  @spec last_non_whitespace_index(sentence_tokens(), integer()) :: non_neg_integer()
  defp last_non_whitespace_index(tokens, idx) do
    {char, _pos} = elem(tokens, idx)

    if sentence_whitespace?(char) do
      last_non_whitespace_index(tokens, idx - 1)
    else
      idx
    end
  end

  @spec range_from_token_indices(sentence_tokens(), non_neg_integer(), non_neg_integer()) ::
          range()
  defp range_from_token_indices(tokens, start_idx, end_idx) when end_idx >= start_idx do
    {_start_char, start_pos} = elem(tokens, start_idx)
    {_end_char, end_pos} = elem(tokens, end_idx)
    {start_pos, end_pos}
  end

  defp range_from_token_indices(_tokens, _start_idx, _end_idx), do: nil

  @spec sentence_terminal?(String.t()) :: boolean()
  defp sentence_terminal?(char), do: char in [".", "!", "?"]

  @spec closing_sentence_delimiter?(String.t()) :: boolean()
  defp closing_sentence_delimiter?(char), do: char in [")", "]", "}", "\"", "'"]

  @spec sentence_whitespace?(String.t()) :: boolean()
  defp sentence_whitespace?(char), do: char in [" ", "\t", "\n"]

  # ── Private — word helpers ────────────────────────────────────────────────────

  @spec around_word_indexes(tuple(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp around_word_indexes(graphemes, start_g, end_g) do
    len = tuple_size(graphemes)
    after_end = end_g + 1

    if after_end < len and whitespace?(elem(graphemes, after_end)) do
      trail_end = scan_right_tuple(graphemes, after_end, &whitespace?/1)
      {start_g, trail_end}
    else
      around_word_indexes_before_start(graphemes, start_g, end_g)
    end
  end

  @spec around_word_indexes_before_start(tuple(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp around_word_indexes_before_start(graphemes, start_g, end_g) when start_g > 0 do
    if whitespace?(elem(graphemes, start_g - 1)) do
      lead_start = scan_left_tuple(graphemes, start_g - 1, &whitespace?/1)
      {lead_start, end_g}
    else
      {start_g, end_g}
    end
  end

  defp around_word_indexes_before_start(_graphemes, start_g, end_g), do: {start_g, end_g}

  @spec classifier_for(String.t()) :: (String.t() -> boolean())
  defp classifier_for(char) do
    case Helpers.classify_char(char) do
      :word -> &word_char?/1
      :whitespace -> &whitespace?/1
      :punctuation -> fn c -> not word_char?(c) and not whitespace?(c) end
    end
  end

  @spec word_char?(String.t()) :: boolean()
  defp word_char?(char), do: Helpers.word_char?(char)

  @spec whitespace?(String.t()) :: boolean()
  defp whitespace?(char), do: Helpers.whitespace?(char)

  # Scans left in a grapheme tuple while `pred` holds.
  @spec scan_left_tuple(tuple(), non_neg_integer(), (String.t() -> boolean())) ::
          non_neg_integer()
  defp scan_left_tuple(_graphemes, 0, _pred), do: 0

  defp scan_left_tuple(graphemes, idx, pred) do
    left = idx - 1

    if pred.(elem(graphemes, left)) do
      scan_left_tuple(graphemes, left, pred)
    else
      idx
    end
  end

  # Scans right in a grapheme tuple while `pred` holds.
  @spec scan_right_tuple(tuple(), non_neg_integer(), (String.t() -> boolean())) ::
          non_neg_integer()
  defp scan_right_tuple(graphemes, idx, pred) do
    right = idx + 1

    if right < tuple_size(graphemes) and pred.(elem(graphemes, right)) do
      scan_right_tuple(graphemes, right, pred)
    else
      idx
    end
  end

  # ── Private — quote helpers ───────────────────────────────────────────────────

  @spec find_quote_pair(tuple(), non_neg_integer(), String.t()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp find_quote_pair(graphemes, col, quote_char),
    do: find_quote_pair(graphemes, col, quote_char, 0, nil, false)

  @spec find_quote_pair(
          tuple(),
          non_neg_integer(),
          String.t(),
          non_neg_integer(),
          non_neg_integer() | nil,
          boolean()
        ) :: {non_neg_integer(), non_neg_integer()} | nil
  # Past the cursor, only a pending opener can still enclose it.
  defp find_quote_pair(graphemes, col, _quote_char, idx, open, _escaped?)
       when idx >= tuple_size(graphemes) or (idx > col and is_nil(open)),
       do: nil

  defp find_quote_pair(graphemes, col, quote_char, idx, open, escaped?) do
    grapheme = elem(graphemes, idx)
    next_escaped? = grapheme == "\\" and not escaped?

    cond do
      grapheme != quote_char or escaped? ->
        find_quote_pair(graphemes, col, quote_char, idx + 1, open, next_escaped?)

      is_nil(open) ->
        find_quote_pair(graphemes, col, quote_char, idx + 1, idx, next_escaped?)

      col <= idx ->
        {open, idx}

      true ->
        find_quote_pair(graphemes, col, quote_char, idx + 1, nil, next_escaped?)
    end
  end

  # ── Private — paren helpers ───────────────────────────────────────────────────

  @spec find_delimited_pair(Readable.t(), position(), String.t(), String.t()) ::
          {position(), position()} | nil
  defp find_delimited_pair(%Document{} = buffer, position, open_char, close_char)
       when byte_size(open_char) == 1 and byte_size(close_char) == 1 do
    doc = align_document_cursor(buffer, position)

    case find_open_in_before(doc.before, doc.cursor_line, doc.cursor_col, open_char, close_char) do
      nil ->
        nil

      {open_pos, open_byte_offset} ->
        case find_close_from_open(doc, open_pos, open_byte_offset, open_char, close_char) do
          nil -> nil
          close_pos -> {open_pos, close_pos}
        end
    end
  end

  defp find_delimited_pair(buffer, position, open_char, close_char)
       when byte_size(open_char) == 1 and byte_size(close_char) == 1 do
    case find_open_by_lines(buffer, position, open_char, close_char) do
      nil ->
        nil

      {open_line, open_col} = open_pos ->
        case find_close_by_lines(
               buffer,
               open_line,
               open_col + byte_size(open_char),
               open_char,
               close_char
             ) do
          nil -> nil
          close_pos -> {open_pos, close_pos}
        end
    end
  end

  defp find_delimited_pair(_buffer, _position, _open_char, _close_char), do: nil

  @spec align_document_cursor(Document.t(), position()) :: Document.t()
  defp align_document_cursor(%Document{} = doc, position) do
    if Document.cursor(doc) == position do
      doc
    else
      Document.move_to(doc, position)
    end
  end

  @spec find_open_in_before(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          String.t()
        ) ::
          delimiter_open() | nil
  defp find_open_in_before(before, line, col, open_char, close_char) do
    case find_open_byte_before(
           before,
           byte_size(before) - 1,
           line,
           col,
           :binary.first(open_char),
           :binary.first(close_char),
           0
         ) do
      {:found, open_pos, open_byte_offset} -> {open_pos, open_byte_offset}
      {:miss, _depth} -> nil
    end
  end

  @spec find_open_byte_before(
          String.t(),
          integer(),
          non_neg_integer(),
          non_neg_integer(),
          byte(),
          byte(),
          non_neg_integer()
        ) :: delimiter_open_scan()
  defp find_open_byte_before(_binary, idx, _line, _col, _open_byte, _close_byte, depth)
       when idx < 0,
       do: {:miss, depth}

  defp find_open_byte_before(binary, idx, line, col, open_byte, close_byte, depth) do
    byte = :binary.at(binary, idx)
    find_open_for_byte(binary, idx, line, col, open_byte, close_byte, depth, byte)
  end

  @spec find_open_for_byte(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          byte(),
          byte(),
          non_neg_integer(),
          byte()
        ) :: delimiter_open_scan()
  defp find_open_for_byte(binary, idx, line, _col, open_byte, close_byte, depth, ?\n) do
    previous_col = byte_col_before_newline(binary, idx)
    find_open_byte_before(binary, idx - 1, line - 1, previous_col, open_byte, close_byte, depth)
  end

  defp find_open_for_byte(binary, idx, line, col, open_byte, close_byte, depth, byte) do
    pos_col = col - 1
    escaped? = escaped_byte?(binary, idx)

    case {byte, escaped?, depth} do
      {^close_byte, false, current_depth} ->
        find_open_byte_before(
          binary,
          idx - 1,
          line,
          pos_col,
          open_byte,
          close_byte,
          current_depth + 1
        )

      {^open_byte, false, 0} ->
        {:found, {line, pos_col}, idx}

      {^open_byte, false, current_depth} ->
        find_open_byte_before(
          binary,
          idx - 1,
          line,
          pos_col,
          open_byte,
          close_byte,
          current_depth - 1
        )

      _ ->
        find_open_byte_before(binary, idx - 1, line, pos_col, open_byte, close_byte, depth)
    end
  end

  @spec find_close_from_open(Document.t(), position(), non_neg_integer(), String.t(), String.t()) ::
          position() | nil
  defp find_close_from_open(
         %Document{} = doc,
         {open_line, open_col},
         open_byte_offset,
         open_char,
         close_char
       ) do
    start_offset = open_byte_offset + byte_size(open_char)
    before_tail = binary_part(doc.before, start_offset, byte_size(doc.before) - start_offset)
    open_byte = :binary.first(open_char)
    close_byte = :binary.first(close_char)

    case scan_forward_delimiter_bytes(
           before_tail,
           0,
           open_line,
           open_col + byte_size(open_char),
           open_byte,
           close_byte,
           1,
           0
         ) do
      {:found, close_pos} ->
        close_pos

      {:cont, line, col, depth, slash_run} ->
        case scan_forward_delimiter_bytes(
               doc.after,
               0,
               line,
               col,
               open_byte,
               close_byte,
               depth,
               slash_run
             ) do
          {:found, close_pos} -> close_pos
          {:cont, _line, _col, _depth, _slash_run} -> nil
        end
    end
  end

  @spec scan_forward_delimiter_bytes(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          byte(),
          byte(),
          pos_integer(),
          non_neg_integer()
        ) :: delimiter_scan_result()
  defp scan_forward_delimiter_bytes(
         binary,
         idx,
         line,
         col,
         _open_byte,
         _close_byte,
         depth,
         slash_run
       )
       when idx >= byte_size(binary),
       do: {:cont, line, col, depth, slash_run}

  defp scan_forward_delimiter_bytes(
         binary,
         idx,
         line,
         col,
         open_byte,
         close_byte,
         depth,
         slash_run
       ) do
    case :binary.at(binary, idx) do
      ?\n ->
        scan_forward_delimiter_bytes(
          binary,
          idx + 1,
          line + 1,
          0,
          open_byte,
          close_byte,
          depth,
          0
        )

      byte ->
        scan_forward_delimiter_byte(
          binary,
          idx,
          {line, col},
          {open_byte, close_byte},
          depth,
          slash_run,
          byte
        )
    end
  end

  @spec scan_forward_delimiter_byte(
          String.t(),
          non_neg_integer(),
          position(),
          {byte(), byte()},
          pos_integer(),
          non_neg_integer(),
          byte()
        ) :: delimiter_scan_result()
  defp scan_forward_delimiter_byte(
         binary,
         idx,
         {line, col},
         {open_byte, close_byte},
         depth,
         slash_run,
         byte
       ) do
    escaped? = rem(slash_run, 2) == 1
    next_slash_run = next_byte_slash_run(byte, slash_run)

    case {byte, escaped?, depth} do
      {^open_byte, false, current_depth} ->
        scan_forward_delimiter_bytes(
          binary,
          idx + 1,
          line,
          col + 1,
          open_byte,
          close_byte,
          current_depth + 1,
          next_slash_run
        )

      {^close_byte, false, 1} ->
        {:found, {line, col}}

      {^close_byte, false, current_depth} ->
        scan_forward_delimiter_bytes(
          binary,
          idx + 1,
          line,
          col + 1,
          open_byte,
          close_byte,
          current_depth - 1,
          next_slash_run
        )

      _ ->
        scan_forward_delimiter_bytes(
          binary,
          idx + 1,
          line,
          col + 1,
          open_byte,
          close_byte,
          depth,
          next_slash_run
        )
    end
  end

  @spec find_open_by_lines(Readable.t(), position(), String.t(), String.t()) :: position() | nil
  defp find_open_by_lines(buffer, {line, col}, open_char, close_char) do
    find_open_by_lines(buffer, line, col, open_char, close_char, 0)
  end

  @spec find_open_by_lines(
          Readable.t(),
          integer(),
          non_neg_integer(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) ::
          position() | nil
  defp find_open_by_lines(_buffer, line, _col, _open_char, _close_char, _depth) when line < 0,
    do: nil

  defp find_open_by_lines(buffer, line, col, open_char, close_char, depth) do
    case Readable.line_at(buffer, line) do
      nil ->
        nil

      line_text ->
        clamped_col = min(col, byte_size(line_text))
        prefix = binary_part(line_text, 0, clamped_col)
        open_byte = :binary.first(open_char)
        close_byte = :binary.first(close_char)

        case find_open_byte_before(
               prefix,
               byte_size(prefix) - 1,
               line,
               clamped_col,
               open_byte,
               close_byte,
               depth
             ) do
          {:miss, next_depth} ->
            find_open_by_previous_line(buffer, line - 1, open_char, close_char, next_depth)

          {:found, open_pos, _byte_offset} ->
            open_pos
        end
    end
  end

  @spec find_open_by_previous_line(
          Readable.t(),
          integer(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) ::
          position() | nil
  defp find_open_by_previous_line(_buffer, line, _open_char, _close_char, _depth) when line < 0,
    do: nil

  defp find_open_by_previous_line(buffer, line, open_char, close_char, depth) do
    case Readable.line_at(buffer, line) do
      nil ->
        nil

      line_text ->
        find_open_by_lines(buffer, line, byte_size(line_text), open_char, close_char, depth)
    end
  end

  @spec find_close_by_lines(
          Readable.t(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          String.t()
        ) ::
          position() | nil
  defp find_close_by_lines(buffer, line, col, open_char, close_char) do
    open_byte = :binary.first(open_char)
    close_byte = :binary.first(close_char)
    find_close_by_lines(buffer, line, col, open_byte, close_byte, 1)
  end

  @spec find_close_by_lines(
          Readable.t(),
          non_neg_integer(),
          non_neg_integer(),
          byte(),
          byte(),
          pos_integer()
        ) ::
          position() | nil
  defp find_close_by_lines(buffer, line, col, open_byte, close_byte, depth) do
    case Readable.line_at(buffer, line) do
      nil ->
        nil

      line_text ->
        start_col = min(col, byte_size(line_text))
        tail = binary_part(line_text, start_col, byte_size(line_text) - start_col)

        case scan_forward_delimiter_bytes(
               tail,
               0,
               line,
               start_col,
               open_byte,
               close_byte,
               depth,
               0
             ) do
          {:found, close_pos} ->
            close_pos

          {:cont, _line, _col, next_depth, _slash_run} ->
            find_close_by_lines(buffer, line + 1, 0, open_byte, close_byte, next_depth)
        end
    end
  end

  @spec byte_col_before_newline(String.t(), non_neg_integer()) :: non_neg_integer()
  defp byte_col_before_newline(binary, newline_idx) do
    newline_idx - previous_newline_index(binary, newline_idx - 1) - 1
  end

  @spec previous_newline_index(String.t(), integer()) :: integer()
  defp previous_newline_index(_binary, idx) when idx < 0, do: -1

  defp previous_newline_index(binary, idx) do
    case :binary.at(binary, idx) do
      ?\n -> idx
      _ -> previous_newline_index(binary, idx - 1)
    end
  end

  @spec escaped_byte?(String.t(), non_neg_integer()) :: boolean()
  defp escaped_byte?(binary, idx), do: rem(preceding_slash_count(binary, idx - 1, 0), 2) == 1

  @spec preceding_slash_count(String.t(), integer(), non_neg_integer()) :: non_neg_integer()
  defp preceding_slash_count(_binary, idx, acc) when idx < 0, do: acc

  defp preceding_slash_count(binary, idx, acc) do
    case :binary.at(binary, idx) do
      ?\\ -> preceding_slash_count(binary, idx - 1, acc + 1)
      _ -> acc
    end
  end

  @spec next_byte_slash_run(byte(), non_neg_integer()) :: non_neg_integer()
  defp next_byte_slash_run(?\\, slash_run), do: slash_run + 1
  defp next_byte_slash_run(_byte, _slash_run), do: 0

  # Advances a position by one grapheme (byte-aware).
  @spec advance_position(Readable.t(), position()) :: position() | nil
  defp advance_position(buffer, {line, col}) do
    text = Readable.line_at(buffer, line) || ""
    next_byte = Unicode.next_grapheme_byte_offset(text, col)
    next_line = Readable.line_at(buffer, line + 1)

    if next_byte > col and (next_byte < byte_size(text) or next_line != nil) do
      {line, next_byte}
    else
      case next_line do
        nil -> nil
        _ -> {line + 1, 0}
      end
    end
  end

  # Retreats a position by one grapheme (byte-aware).
  @spec retreat_position(Readable.t(), position()) :: position() | nil
  defp retreat_position(_buffer, {0, 0}), do: nil

  defp retreat_position(buffer, {line, 0}) when line > 0 do
    prev_text = Readable.line_at(buffer, line - 1) || ""

    if byte_size(prev_text) > 0 do
      {line - 1, Unicode.last_grapheme_byte_offset(prev_text)}
    else
      {line - 1, 0}
    end
  end

  defp retreat_position(buffer, {line, col}) do
    text = Readable.line_at(buffer, line) || ""
    {line, Unicode.prev_grapheme_byte_offset(text, col)}
  end
end
