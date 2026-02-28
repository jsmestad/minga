defmodule Minga.Motion do
  @moduledoc """
  Pure cursor-motion functions for the Minga editor.

  Each function takes a `GapBuffer.t()` and a current `position()`, and
  returns the new `position()` after applying the motion.  No buffer state
  is mutated — the caller is responsible for moving the buffer cursor via
  `GapBuffer.move_to/2` or `Buffer.Server.move_to/2`.

  ## Word boundary rules

  A **word character** is any alphanumeric character or underscore
  (`[a-zA-Z0-9_]`).  This matches Vim's lowercase `w`/`b`/`e` motions.
  Whitespace (space, tab, newline) acts as word separator.

  ## Line and document motions

  | Function          | Vim key | Description                              |
  |-------------------|---------|------------------------------------------|
  | `line_start/2`    | `0`     | First column of the current line         |
  | `line_end/2`      | `$`     | Last column of the current line          |
  | `first_non_blank/2` | `^`   | First non-whitespace column on the line  |
  | `document_start/1` | `gg`  | First character of the buffer            |
  | `document_end/1`  | `G`     | Last character of the last line          |
  """

  alias Minga.Buffer.GapBuffer

  @typedoc "A zero-indexed {line, col} cursor position."
  @type position :: GapBuffer.position()

  # Inline hot character classification helpers for JIT optimization.
  @compile {:inline, word_char?: 1, whitespace?: 1, classify_char: 1}

  # ── Word motions ────────────────────────────────────────────────────────────

  @doc """
  Move forward to the start of the next word (like Vim's `w`).

  From any non-whitespace run, advances past the current run, then skips
  leading whitespace.  From whitespace, just skips to the next non-whitespace.
  Stops at the last position in the buffer rather than going out of bounds.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello world")
      iex> Minga.Motion.word_forward(buf, {0, 0})
      {0, 6}
  """
  @spec word_forward(GapBuffer.t(), position()) :: position()
  def word_forward(%GapBuffer{} = buf, {line, col} = pos) do
    text = GapBuffer.content(buf)
    graphemes = text |> String.graphemes() |> List.to_tuple()
    total = tuple_size(graphemes)

    if total == 0 do
      pos
    else
      all_lines = String.split(text, "\n")
      offset = offset_for(all_lines, line, col)
      new_offset = do_word_forward(graphemes, offset, total - 1)
      GapBuffer.offset_to_position(buf, new_offset)
    end
  end

  @doc """
  Move backward to the start of the previous word (like Vim's `b`).

  Skips backward past whitespace, then backward past the word run,
  stopping at the first character of that run.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello world")
      iex> Minga.Motion.word_backward(buf, {0, 6})
      {0, 0}
  """
  @spec word_backward(GapBuffer.t(), position()) :: position()
  def word_backward(%GapBuffer{} = buf, {line, col} = pos) do
    text = GapBuffer.content(buf)
    graphemes = text |> String.graphemes() |> List.to_tuple()

    if tuple_size(graphemes) == 0 do
      pos
    else
      all_lines = String.split(text, "\n")
      offset = offset_for(all_lines, line, col)

      if offset == 0 do
        {0, 0}
      else
        new_offset = do_word_backward(graphemes, offset - 1)
        GapBuffer.offset_to_position(buf, new_offset)
      end
    end
  end

  @doc """
  Move to the end of the current or next word (like Vim's `e`).

  Skips forward past any whitespace, then advances to the last character
  of the next non-whitespace run.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello world")
      iex> Minga.Motion.word_end(buf, {0, 0})
      {0, 4}
  """
  @spec word_end(GapBuffer.t(), position()) :: position()
  def word_end(%GapBuffer{} = buf, {line, col} = pos) do
    text = GapBuffer.content(buf)
    graphemes = text |> String.graphemes() |> List.to_tuple()
    total = tuple_size(graphemes)

    if total == 0 do
      pos
    else
      all_lines = String.split(text, "\n")
      offset = offset_for(all_lines, line, col)
      new_offset = do_word_end(graphemes, offset, total - 1)
      GapBuffer.offset_to_position(buf, new_offset)
    end
  end

  # ── Line motions ─────────────────────────────────────────────────────────────

  @doc """
  Move to the first column of the current line (like Vim's `0`).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("  hello")
      iex> Minga.Motion.line_start(buf, {0, 4})
      {0, 0}
  """
  @spec line_start(GapBuffer.t(), position()) :: position()
  def line_start(%GapBuffer{}, {line, _col}), do: {line, 0}

  @doc """
  Move to the last column of the current line (like Vim's `$`).
  Returns the position of the last grapheme on the line.
  For an empty line, returns `{line, 0}`.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello\\nworld")
      iex> Minga.Motion.line_end(buf, {0, 0})
      {0, 4}
  """
  @spec line_end(GapBuffer.t(), position()) :: position()
  def line_end(%GapBuffer{} = buf, {line, _col}) do
    case GapBuffer.line_at(buf, line) do
      nil -> {line, 0}
      "" -> {line, 0}
      text -> {line, max(0, String.length(text) - 1)}
    end
  end

  @doc """
  Move to the first non-blank character on the current line (like Vim's `^`).
  Falls back to `{line, 0}` when the line is entirely blank.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("  hello")
      iex> Minga.Motion.first_non_blank(buf, {0, 0})
      {0, 2}
  """
  @spec first_non_blank(GapBuffer.t(), position()) :: position()
  def first_non_blank(%GapBuffer{} = buf, {line, _col}) do
    case GapBuffer.line_at(buf, line) do
      nil ->
        {line, 0}

      text ->
        col = find_first_non_blank(text, 0)
        {line, col}
    end
  end

  # Walk the binary to find first non-blank, avoiding String.graphemes allocation.
  @spec find_first_non_blank(String.t(), non_neg_integer()) :: non_neg_integer()
  defp find_first_non_blank(text, col) do
    case String.next_grapheme(text) do
      {g, rest} when g in [" ", "\t"] -> find_first_non_blank(rest, col + 1)
      {_g, _rest} -> col
      nil -> 0
    end
  end

  # ── Document motions ─────────────────────────────────────────────────────────

  @doc """
  Move to the very start of the buffer (like Vim's `gg`).
  Always returns `{0, 0}`.

  ## Examples

      iex> Minga.Motion.document_start(Minga.Buffer.GapBuffer.new("hello\\nworld"))
      {0, 0}
  """
  @spec document_start(GapBuffer.t()) :: position()
  def document_start(%GapBuffer{}), do: {0, 0}

  @doc """
  Move to the last character of the last line (like Vim's `G`).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello\\nworld")
      iex> Minga.Motion.document_end(buf)
      {1, 4}
  """
  @spec document_end(GapBuffer.t()) :: position()
  def document_end(%GapBuffer{} = buf) do
    last_line = GapBuffer.line_count(buf) - 1
    line_end(buf, {last_line, 0})
  end

  # ── Find-char motions ─────────────────────────────────────────────────────

  @doc """
  Move forward to the next occurrence of `char` on the current line (Vim's `f`).
  Returns the original position if `char` is not found.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello world")
      iex> Minga.Motion.find_char_forward(buf, {0, 0}, "o")
      {0, 4}
  """
  @spec find_char_forward(GapBuffer.t(), position(), String.t()) :: position()
  def find_char_forward(%GapBuffer{} = buf, {line, col}, char) do
    case GapBuffer.line_at(buf, line) do
      nil ->
        {line, col}

      text ->
        case find_in_binary(text, char, col + 1, 0) do
          nil -> {line, col}
          idx -> {line, idx}
        end
    end
  end

  @doc """
  Move backward to the previous occurrence of `char` on the current line (Vim's `F`).
  Returns the original position if `char` is not found.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello world")
      iex> Minga.Motion.find_char_backward(buf, {0, 7}, "o")
      {0, 4}
  """
  @spec find_char_backward(GapBuffer.t(), position(), String.t()) :: position()
  def find_char_backward(%GapBuffer{} = buf, {line, col}, char) do
    case GapBuffer.line_at(buf, line) do
      nil ->
        {line, col}

      text ->
        graphemes = text |> String.graphemes() |> List.to_tuple()

        case rfind_in_tuple(graphemes, char, col - 1) do
          nil -> {line, col}
          idx -> {line, idx}
        end
    end
  end

  @doc """
  Move to one before the next occurrence of `char` on the current line (Vim's `t`).
  Returns the original position if `char` is not found.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello world")
      iex> Minga.Motion.till_char_forward(buf, {0, 0}, "o")
      {0, 3}
  """
  @spec till_char_forward(GapBuffer.t(), position(), String.t()) :: position()
  def till_char_forward(%GapBuffer{} = buf, {line, col}, char) do
    case find_char_forward(buf, {line, col}, char) do
      {^line, ^col} -> {line, col}
      {^line, found_col} -> {line, max(col, found_col - 1)}
    end
  end

  @doc """
  Move to one after the previous occurrence of `char` on the current line (Vim's `T`).
  Returns the original position if `char` is not found.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello world")
      iex> Minga.Motion.till_char_backward(buf, {0, 7}, "o")
      {0, 5}
  """
  @spec till_char_backward(GapBuffer.t(), position(), String.t()) :: position()
  def till_char_backward(%GapBuffer{} = buf, {line, col}, char) do
    case find_char_backward(buf, {line, col}, char) do
      {^line, ^col} -> {line, col}
      {^line, found_col} -> {line, min(col, found_col + 1)}
    end
  end

  # ── Bracket matching ─────────────────────────────────────────────────────

  @bracket_pairs %{
    "(" => {"(", ")", :forward},
    ")" => {"(", ")", :backward},
    "[" => {"[", "]", :forward},
    "]" => {"[", "]", :backward},
    "{" => {"{", "}", :forward},
    "}" => {"{", "}", :backward},
    "<" => {"<", ">", :forward},
    ">" => {"<", ">", :backward}
  }

  @doc """
  Jump to the matching bracket/paren/brace (Vim's `%`).

  Scans forward from cursor to find the first bracket character, then
  finds its match counting nesting. Returns original position if no
  bracket is found or match is unbalanced.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("(hello)")
      iex> Minga.Motion.match_bracket(buf, {0, 0})
      {0, 6}
  """
  @spec match_bracket(GapBuffer.t(), position()) :: position()
  def match_bracket(%GapBuffer{} = buf, {line, col} = pos) do
    current_line_text = GapBuffer.line_at(buf, line) || ""
    line_graphemes = current_line_text |> String.graphemes() |> List.to_tuple()

    case find_bracket_on_line(line_graphemes, col, tuple_size(line_graphemes)) do
      nil -> pos
      bracket_col -> do_match_bracket(buf, pos, line_graphemes, bracket_col)
    end
  end

  @spec do_match_bracket(GapBuffer.t(), position(), tuple(), non_neg_integer()) ::
          position()
  defp do_match_bracket(buf, {line, col} = pos, line_graphemes, bracket_col) do
    bracket_char = elem(line_graphemes, bracket_col)

    case Map.get(@bracket_pairs, bracket_char) do
      nil ->
        pos

      {open, close, direction} ->
        text = GapBuffer.content(buf)
        graphemes = text |> String.graphemes() |> List.to_tuple()
        all_lines = String.split(text, "\n")
        abs_offset = offset_for(all_lines, line, col) - col + bracket_col

        case scan_for_match(graphemes, abs_offset, open, close, direction) do
          nil -> pos
          match_offset -> GapBuffer.offset_to_position(buf, match_offset)
        end
    end
  end

  # ── Paragraph motions ─────────────────────────────────────────────────────

  @doc """
  Move to the next blank line (Vim's `}`).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello\\nworld\\n\\nfoo")
      iex> Minga.Motion.paragraph_forward(buf, {0, 0})
      {2, 0}
  """
  @spec paragraph_forward(GapBuffer.t(), position()) :: position()
  def paragraph_forward(%GapBuffer{} = buf, {line, _col}) do
    total = GapBuffer.line_count(buf)
    find_paragraph_boundary(buf, line + 1, total, :forward)
  end

  @doc """
  Move to the previous blank line (Vim's `{`).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello\\nworld\\n\\nfoo")
      iex> Minga.Motion.paragraph_backward(buf, {3, 0})
      {2, 0}
  """
  @spec paragraph_backward(GapBuffer.t(), position()) :: position()
  def paragraph_backward(%GapBuffer{} = buf, {line, _col}) do
    find_paragraph_boundary(buf, line - 1, GapBuffer.line_count(buf), :backward)
  end

  # ── WORD motions (whitespace-delimited) ──────────────────────────────────

  @doc """
  Move forward to the start of the next WORD (Vim's `W`).
  WORDs are separated by whitespace only (no punctuation boundaries).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("foo.bar baz")
      iex> Minga.Motion.word_forward_big(buf, {0, 0})
      {0, 8}
  """
  @spec word_forward_big(GapBuffer.t(), position()) :: position()
  def word_forward_big(%GapBuffer{} = buf, {line, col} = pos) do
    text = GapBuffer.content(buf)
    graphemes = text |> String.graphemes() |> List.to_tuple()
    total = tuple_size(graphemes)

    if total == 0 do
      pos
    else
      all_lines = String.split(text, "\n")
      offset = offset_for(all_lines, line, col)
      new_offset = do_word_forward_big(graphemes, offset, total - 1)
      GapBuffer.offset_to_position(buf, new_offset)
    end
  end

  @doc """
  Move backward to the start of the previous WORD (Vim's `B`).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("foo.bar baz")
      iex> Minga.Motion.word_backward_big(buf, {0, 8})
      {0, 0}
  """
  @spec word_backward_big(GapBuffer.t(), position()) :: position()
  def word_backward_big(%GapBuffer{} = buf, {line, col} = pos) do
    text = GapBuffer.content(buf)
    graphemes = text |> String.graphemes() |> List.to_tuple()

    if tuple_size(graphemes) == 0 do
      pos
    else
      all_lines = String.split(text, "\n")
      offset = offset_for(all_lines, line, col)

      if offset == 0 do
        {0, 0}
      else
        new_offset = do_word_backward_big(graphemes, offset - 1)
        GapBuffer.offset_to_position(buf, new_offset)
      end
    end
  end

  @doc """
  Move to the end of the current or next WORD (Vim's `E`).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("foo.bar baz")
      iex> Minga.Motion.word_end_big(buf, {0, 0})
      {0, 6}
  """
  @spec word_end_big(GapBuffer.t(), position()) :: position()
  def word_end_big(%GapBuffer{} = buf, {line, col} = pos) do
    text = GapBuffer.content(buf)
    graphemes = text |> String.graphemes() |> List.to_tuple()
    total = tuple_size(graphemes)

    if total == 0 do
      pos
    else
      all_lines = String.split(text, "\n")
      offset = offset_for(all_lines, line, col)
      new_offset = do_word_end_big(graphemes, offset, total - 1)
      GapBuffer.offset_to_position(buf, new_offset)
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Returns the grapheme offset for a given {line, col} in the already-split lines.
  @spec offset_for([String.t()], non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp offset_for(all_lines, line, col) do
    prefix =
      all_lines
      |> Enum.take(line)
      |> Enum.reduce(0, fn l, acc -> acc + String.length(l) + 1 end)

    prefix + col
  end

  # ── Character classification (JIT-friendly binary pattern matching) ──────

  @spec classify_char(String.t()) :: :word | :whitespace | :punctuation
  defp classify_char(<<c, _::binary>>) when c >= ?a and c <= ?z, do: :word
  defp classify_char(<<c, _::binary>>) when c >= ?A and c <= ?Z, do: :word
  defp classify_char(<<c, _::binary>>) when c >= ?0 and c <= ?9, do: :word
  defp classify_char(<<?_, _::binary>>), do: :word
  defp classify_char(<<?\s, _::binary>>), do: :whitespace
  defp classify_char(<<?\t, _::binary>>), do: :whitespace
  defp classify_char(<<?\n, _::binary>>), do: :whitespace
  defp classify_char(_), do: :punctuation

  @spec word_char?(String.t() | nil) :: boolean()
  defp word_char?(nil), do: false
  defp word_char?(g), do: classify_char(g) == :word

  @spec whitespace?(String.t() | nil) :: boolean()
  defp whitespace?(nil), do: false
  defp whitespace?(g), do: classify_char(g) == :whitespace

  # ── `b` motion helpers ──

  @spec do_word_backward(tuple(), non_neg_integer()) :: non_neg_integer()
  defp do_word_backward(graphemes, offset) do
    non_ws = backward_find(graphemes, offset, fn g -> not whitespace?(g) end)

    if non_ws < 0 do
      0
    else
      find_run_start_at(graphemes, non_ws)
    end
  end

  @spec find_run_start_at(tuple(), non_neg_integer()) :: non_neg_integer()
  defp find_run_start_at(graphemes, index) do
    current = elem(graphemes, index)

    if word_char?(current) do
      find_run_start(graphemes, index, &word_char?/1)
    else
      find_run_start(graphemes, index, fn g -> not word_char?(g) and not whitespace?(g) end)
    end
  end

  @spec backward_find(tuple(), integer(), (String.t() -> boolean())) :: integer()
  defp backward_find(_graphemes, offset, _pred) when offset < 0, do: -1

  defp backward_find(graphemes, offset, pred) do
    if pred.(elem(graphemes, offset)) do
      offset
    else
      backward_find(graphemes, offset - 1, pred)
    end
  end

  @spec find_run_start(tuple(), non_neg_integer(), (String.t() -> boolean())) ::
          non_neg_integer()
  defp find_run_start(graphemes, offset, pred) do
    if offset > 0 and pred.(elem(graphemes, offset - 1)) do
      find_run_start(graphemes, offset - 1, pred)
    else
      offset
    end
  end

  # ── `w` motion helpers ──

  @spec do_word_forward(tuple(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp do_word_forward(_graphemes, offset, max) when offset >= max, do: max

  defp do_word_forward(graphemes, offset, max) do
    current = elem(graphemes, offset)
    advance_word_forward(graphemes, offset, max, classify_char(current))
  end

  @spec advance_word_forward(
          tuple(),
          non_neg_integer(),
          non_neg_integer(),
          :word | :whitespace | :punctuation
        ) :: non_neg_integer()
  defp advance_word_forward(graphemes, offset, max, :whitespace) do
    skip_while(graphemes, offset + 1, max, &whitespace?/1)
  end

  defp advance_word_forward(graphemes, offset, max, :word) do
    after_word = skip_while(graphemes, offset + 1, max, &word_char?/1)
    skip_while(graphemes, after_word, max, &whitespace?/1)
  end

  defp advance_word_forward(graphemes, offset, max, :punctuation) do
    after_punct =
      skip_while(graphemes, offset + 1, max, fn g ->
        not word_char?(g) and not whitespace?(g)
      end)

    skip_while(graphemes, after_punct, max, &whitespace?/1)
  end

  # ── `e` motion helpers ──

  @spec do_word_end(tuple(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp do_word_end(_graphemes, offset, max) when offset >= max, do: max

  defp do_word_end(graphemes, offset, max) do
    start = min(offset + 1, max)
    current = elem(graphemes, start)

    run_start =
      if whitespace?(current),
        do: skip_while(graphemes, start, max, &whitespace?/1),
        else: start

    run_char = elem(graphemes, run_start)
    advance_word_end(graphemes, run_start, max, classify_char(run_char))
  end

  @spec advance_word_end(
          tuple(),
          non_neg_integer(),
          non_neg_integer(),
          :word | :whitespace | :punctuation
        ) :: non_neg_integer()
  defp advance_word_end(graphemes, run_start, max, :word) do
    last_in_run(graphemes, run_start, max, &word_char?/1)
  end

  defp advance_word_end(graphemes, run_start, max, :punctuation) do
    last_in_run(graphemes, run_start, max, fn g ->
      not word_char?(g) and not whitespace?(g)
    end)
  end

  defp advance_word_end(_graphemes, run_start, _max, :whitespace), do: run_start

  @spec last_in_run(tuple(), non_neg_integer(), non_neg_integer(), (String.t() -> boolean())) ::
          non_neg_integer()
  defp last_in_run(graphemes, offset, max, pred) do
    next = offset + 1

    if next <= max and pred.(elem(graphemes, next)) do
      last_in_run(graphemes, next, max, pred)
    else
      offset
    end
  end

  @spec skip_while(tuple(), non_neg_integer(), non_neg_integer(), (String.t() -> boolean())) ::
          non_neg_integer()
  defp skip_while(_graphemes, offset, max, _pred) when offset > max, do: max

  defp skip_while(graphemes, offset, max, pred) do
    if pred.(elem(graphemes, offset)) do
      skip_while(graphemes, offset + 1, max, pred)
    else
      offset
    end
  end

  # ── Find-char helpers ────────────────────────────────────────────────────

  # Walk forward through the binary, tracking grapheme index. O(n) single pass.
  @spec find_in_binary(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer() | nil
  defp find_in_binary(text, char, from, current_idx) do
    case String.next_grapheme(text) do
      {g, rest} ->
        if current_idx >= from and g == char do
          current_idx
        else
          find_in_binary(rest, char, from, current_idx + 1)
        end

      nil ->
        nil
    end
  end

  # Reverse find in a tuple (backward from `to` index).
  @spec rfind_in_tuple(tuple(), String.t(), integer()) :: non_neg_integer() | nil
  defp rfind_in_tuple(_graphemes, _char, to) when to < 0, do: nil

  defp rfind_in_tuple(graphemes, char, to) do
    if elem(graphemes, to) == char do
      to
    else
      rfind_in_tuple(graphemes, char, to - 1)
    end
  end

  # ── Bracket matching helpers ─────────────────────────────────────────────

  @bracket_chars MapSet.new(["(", ")", "[", "]", "{", "}", "<", ">"])

  @spec find_bracket_on_line(tuple(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer() | nil
  defp find_bracket_on_line(_graphemes, col, size) when col >= size, do: nil

  defp find_bracket_on_line(graphemes, col, size) do
    g = elem(graphemes, col)

    if MapSet.member?(@bracket_chars, g) do
      col
    else
      find_bracket_on_line(graphemes, col + 1, size)
    end
  end

  @spec scan_for_match(
          tuple(),
          non_neg_integer(),
          String.t(),
          String.t(),
          :forward | :backward
        ) ::
          non_neg_integer() | nil
  defp scan_for_match(graphemes, offset, open, close, :forward) do
    do_scan_forward(graphemes, offset + 1, tuple_size(graphemes), open, close, 1)
  end

  defp scan_for_match(graphemes, offset, open, close, :backward) do
    do_scan_backward(graphemes, offset - 1, open, close, 1)
  end

  @spec do_scan_forward(
          tuple(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) ::
          non_neg_integer() | nil
  defp do_scan_forward(_graphemes, idx, total, _open, _close, _depth) when idx >= total, do: nil

  defp do_scan_forward(graphemes, idx, total, open, close, depth) do
    g = elem(graphemes, idx)
    do_scan_forward_match(graphemes, idx, total, open, close, depth, g)
  end

  @spec do_scan_forward_match(
          tuple(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          String.t(),
          non_neg_integer(),
          String.t()
        ) :: non_neg_integer() | nil
  defp do_scan_forward_match(_graphemes, idx, _total, _open, close, 1, g) when g == close, do: idx

  defp do_scan_forward_match(graphemes, idx, total, open, close, depth, g) when g == close do
    do_scan_forward(graphemes, idx + 1, total, open, close, depth - 1)
  end

  defp do_scan_forward_match(graphemes, idx, total, open, close, depth, g) when g == open do
    do_scan_forward(graphemes, idx + 1, total, open, close, depth + 1)
  end

  defp do_scan_forward_match(graphemes, idx, total, open, close, depth, _g) do
    do_scan_forward(graphemes, idx + 1, total, open, close, depth)
  end

  @spec do_scan_backward(tuple(), integer(), String.t(), String.t(), non_neg_integer()) ::
          non_neg_integer() | nil
  defp do_scan_backward(_graphemes, idx, _open, _close, _depth) when idx < 0, do: nil

  defp do_scan_backward(graphemes, idx, open, close, depth) do
    g = elem(graphemes, idx)
    do_scan_backward_match(graphemes, idx, open, close, depth, g)
  end

  @spec do_scan_backward_match(
          tuple(),
          integer(),
          String.t(),
          String.t(),
          non_neg_integer(),
          String.t()
        ) :: non_neg_integer() | nil
  defp do_scan_backward_match(_graphemes, idx, open, _close, 1, g) when g == open, do: idx

  defp do_scan_backward_match(graphemes, idx, open, close, depth, g) when g == open do
    do_scan_backward(graphemes, idx - 1, open, close, depth - 1)
  end

  defp do_scan_backward_match(graphemes, idx, open, close, depth, g) when g == close do
    do_scan_backward(graphemes, idx - 1, open, close, depth + 1)
  end

  defp do_scan_backward_match(graphemes, idx, open, close, depth, _g) do
    do_scan_backward(graphemes, idx - 1, open, close, depth)
  end

  # ── Paragraph helpers ────────────────────────────────────────────────────

  @spec find_paragraph_boundary(GapBuffer.t(), integer(), non_neg_integer(), :forward | :backward) ::
          position()
  defp find_paragraph_boundary(_buf, line, _total, _dir) when line < 0, do: {0, 0}

  defp find_paragraph_boundary(_buf, line, total, _dir) when line >= total do
    {max(0, total - 1), 0}
  end

  defp find_paragraph_boundary(buf, line, total, dir) do
    line_text = GapBuffer.line_at(buf, line) || ""
    next = if dir == :forward, do: line + 1, else: line - 1

    if blank_line?(line_text) do
      {line, 0}
    else
      find_paragraph_boundary(buf, next, total, dir)
    end
  end

  @spec blank_line?(String.t()) :: boolean()
  defp blank_line?(text), do: String.trim(text) == ""

  # ── WORD motion helpers (whitespace-delimited) ───────────────────────────

  @spec do_word_forward_big(tuple(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_word_forward_big(_graphemes, offset, max) when offset >= max, do: max

  defp do_word_forward_big(graphemes, offset, max) do
    current = elem(graphemes, offset)

    if whitespace?(current) do
      skip_while(graphemes, offset + 1, max, &whitespace?/1)
    else
      after_word = skip_while(graphemes, offset + 1, max, fn g -> not whitespace?(g) end)
      skip_while(graphemes, after_word, max, &whitespace?/1)
    end
  end

  @spec do_word_backward_big(tuple(), non_neg_integer()) :: non_neg_integer()
  defp do_word_backward_big(graphemes, offset) do
    non_ws = backward_find(graphemes, offset, fn g -> not whitespace?(g) end)

    if non_ws < 0 do
      0
    else
      find_run_start(graphemes, non_ws, fn g -> not whitespace?(g) end)
    end
  end

  @spec do_word_end_big(tuple(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_word_end_big(_graphemes, offset, max) when offset >= max, do: max

  defp do_word_end_big(graphemes, offset, max) do
    start = min(offset + 1, max)
    current = elem(graphemes, start)

    run_start =
      if whitespace?(current),
        do: skip_while(graphemes, start, max, &whitespace?/1),
        else: start

    last_in_run(graphemes, run_start, max, fn g -> not whitespace?(g) end)
  end
end
