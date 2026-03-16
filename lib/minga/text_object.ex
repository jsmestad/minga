defmodule Minga.TextObject do
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

  alias Minga.Buffer.Unicode
  alias Minga.Motion.Helpers
  alias Minga.Parser.Manager, as: ParserManager
  alias Minga.Text.Readable

  @typedoc "A zero-indexed `{line, byte_col}` position."
  @type position :: {non_neg_integer(), non_neg_integer()}

  @typedoc "An inclusive `{start_pos, end_pos}` range, or `nil` when not found."
  @type range :: {position(), position()} | nil

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

      after_end = end_g + 1

      {final_start_g, final_end_g} =
        cond do
          after_end < len and whitespace?(elem(graphemes, after_end)) ->
            trail_end = scan_right_tuple(graphemes, after_end, &whitespace?/1)
            {start_g, trail_end}

          start_g > 0 and whitespace?(elem(graphemes, start_g - 1)) ->
            lead_start = scan_left_tuple(graphemes, start_g - 1, &whitespace?/1)
            {lead_start, end_g}

          true ->
            {start_g, end_g}
        end

      start_byte = elem(byte_offsets, final_start_g)
      end_byte = elem(byte_offsets, final_end_g)

      {{line, start_byte}, {line, end_byte}}
    end
  end

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
    case find_delimited_pair(buffer, position, open_char, close_char) do
      nil -> nil
      pair -> pair
    end
  end

  # ── Tree-sitter structural text objects ────────────────────────────────────────
  #
  # These query the Zig parser for structural ranges using textobjects.scm.
  # Helix uses @X.inside / @X.around capture names (e.g., @function.inside).

  @typedoc "Structural text object type."
  @type structural_type :: :function | :class | :parameter | :block | :comment | :test

  @doc """
  Returns the inner range of a structural text object (e.g., function body,
  class body, parameter) at the cursor position.

  Uses tree-sitter textobjects.scm queries. Returns `nil` if no text object
  of the requested type contains the cursor, or if tree-sitter is unavailable.
  """
  @spec structural_inner(structural_type(), position(), non_neg_integer()) :: range()
  def structural_inner(type, {line, col}, buffer_id) when is_atom(type) do
    capture = Atom.to_string(type) <> ".inside"
    query_structural(line, col, capture, buffer_id)
  end

  @doc """
  Returns the outer range of a structural text object at the cursor position.

  Includes the structural delimiters (e.g., `def...end`, braces, etc.).
  """
  @spec structural_around(structural_type(), position(), non_neg_integer()) :: range()
  def structural_around(type, {line, col}, buffer_id) when is_atom(type) do
    capture = Atom.to_string(type) <> ".around"
    query_structural(line, col, capture, buffer_id)
  end

  @spec query_structural(non_neg_integer(), non_neg_integer(), String.t(), non_neg_integer()) ::
          range()
  defp query_structural(row, col, capture_name, buffer_id) do
    case ParserManager.request_textobject(buffer_id, row, col, capture_name) do
      {start_row, start_col, end_row, end_col} ->
        # Zig returns byte columns. The end position from tree-sitter is
        # exclusive, so we subtract 1 to make it inclusive for Vim semantics.
        end_pos = adjust_end_position(end_row, end_col)
        {{start_row, start_col}, end_pos}

      nil ->
        nil
    end
  end

  # Tree-sitter end positions are exclusive. Convert to inclusive for Vim.
  @spec adjust_end_position(non_neg_integer(), non_neg_integer()) :: position()
  defp adjust_end_position(row, 0) when row > 0, do: {row - 1, 0}
  defp adjust_end_position(row, col) when col > 0, do: {row, col - 1}
  defp adjust_end_position(row, col), do: {row, col}

  # ── Private — word helpers ────────────────────────────────────────────────────

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
  defp find_quote_pair(graphemes, col, quote_char) do
    size = tuple_size(graphemes)
    quote_positions = collect_quote_positions(graphemes, quote_char, 0, size, [])
    pairs = build_pairs(quote_positions)

    pairs
    |> Enum.filter(fn {open, close} ->
      (open < col and col < close) or col == open or col == close
    end)
    |> Enum.min_by(fn {open, close} -> close - open end, fn -> nil end)
  end

  @spec collect_quote_positions(tuple(), String.t(), non_neg_integer(), non_neg_integer(), [
          non_neg_integer()
        ]) :: [non_neg_integer()]
  defp collect_quote_positions(_graphemes, _char, idx, size, acc) when idx >= size do
    Enum.reverse(acc)
  end

  defp collect_quote_positions(graphemes, char, idx, size, acc) do
    if elem(graphemes, idx) == char do
      collect_quote_positions(graphemes, char, idx + 1, size, [idx | acc])
    else
      collect_quote_positions(graphemes, char, idx + 1, size, acc)
    end
  end

  @spec build_pairs([non_neg_integer()]) :: [{non_neg_integer(), non_neg_integer()}]
  defp build_pairs([]), do: []
  defp build_pairs([_]), do: []
  defp build_pairs([open, close | rest]), do: [{open, close} | build_pairs(rest)]

  # ── Private — paren helpers ───────────────────────────────────────────────────

  @spec find_delimited_pair(Readable.t(), position(), String.t(), String.t()) ::
          {position(), position()} | nil
  defp find_delimited_pair(buffer, {line, col}, open_char, close_char) do
    content = Readable.content(buffer)
    all_lines = :binary.split(content, "\n", [:global])
    flat = flatten_with_byte_positions(all_lines)

    cursor_abs = find_abs_index(flat, line, col)

    case cursor_abs do
      nil -> nil
      abs_idx -> find_pair_from_index(flat, abs_idx, open_char, close_char)
    end
  end

  @spec find_pair_from_index(list(), non_neg_integer(), String.t(), String.t()) ::
          {position(), position()} | nil
  defp find_pair_from_index(flat, abs_idx, open_char, close_char) do
    case find_open(flat, abs_idx - 1, open_char, close_char, 0) do
      nil ->
        nil

      open_abs ->
        {open_line, open_col} = elem(Enum.at(flat, open_abs), 1)
        find_matching_close(flat, open_abs, open_line, open_col, open_char, close_char)
    end
  end

  @spec find_matching_close(
          list(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          String.t()
        ) :: {position(), position()} | nil
  defp find_matching_close(flat, open_abs, open_line, open_col, open_char, close_char) do
    case find_close(flat, open_abs + 1, open_char, close_char, 1) do
      nil ->
        nil

      close_abs ->
        {close_line, close_col} = elem(Enum.at(flat, close_abs), 1)
        {{open_line, open_col}, {close_line, close_col}}
    end
  end

  # Flattens lines into a list of `{grapheme, {line, byte_col}}` tuples.
  @spec flatten_with_byte_positions([String.t()]) :: [{String.t(), position()}]
  defp flatten_with_byte_positions(lines) do
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line_text, line_idx} ->
      graphemes_with_byte_cols(line_text, line_idx)
    end)
  end

  @spec graphemes_with_byte_cols(String.t(), non_neg_integer()) :: [{String.t(), position()}]
  defp graphemes_with_byte_cols(text, line_idx) do
    do_graphemes_with_byte_cols(text, line_idx, 0, [])
  end

  @spec do_graphemes_with_byte_cols(String.t(), non_neg_integer(), non_neg_integer(), [
          {String.t(), position()}
        ]) :: [{String.t(), position()}]
  defp do_graphemes_with_byte_cols(text, line_idx, byte_pos, acc) do
    case String.next_grapheme(text) do
      {g, rest} ->
        g_size = byte_size(text) - byte_size(rest)

        do_graphemes_with_byte_cols(rest, line_idx, byte_pos + g_size, [
          {g, {line_idx, byte_pos}} | acc
        ])

      nil ->
        Enum.reverse(acc)
    end
  end

  @spec find_abs_index([{String.t(), position()}], non_neg_integer(), non_neg_integer()) ::
          non_neg_integer() | nil
  defp find_abs_index(flat, target_line, target_col) do
    flat
    |> Enum.find_index(fn {_g, {l, c}} -> l == target_line and c == target_col end)
  end

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

  # Advances a position by one grapheme (byte-aware).
  @spec advance_position(Readable.t(), position()) :: position() | nil
  defp advance_position(buffer, {line, col}) do
    text = Readable.line_at(buffer, line) || ""
    next_byte = Unicode.next_grapheme_byte_offset(text, col)

    if next_byte > col and next_byte < byte_size(text) do
      {line, next_byte}
    else
      next_line = line + 1

      case Readable.line_at(buffer, next_line) do
        nil -> nil
        _ -> {next_line, 0}
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
