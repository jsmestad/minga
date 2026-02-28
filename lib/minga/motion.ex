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
    graphemes = String.graphemes(text)
    total = length(graphemes)

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
    graphemes = String.graphemes(text)

    if graphemes == [] do
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
    graphemes = String.graphemes(text)
    total = length(graphemes)

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
        col =
          text
          |> String.graphemes()
          |> Enum.find_index(fn g -> g not in [" ", "\t"] end)

        {line, col || 0}
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
        graphemes = String.graphemes(text)

        case find_in_graphemes(graphemes, char, col + 1) do
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
        graphemes = String.graphemes(text)

        case rfind_in_graphemes(graphemes, char, col - 1) do
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
    line_graphemes = String.graphemes(current_line_text)

    case find_bracket_on_line(line_graphemes, col) do
      nil -> pos
      bracket_col -> do_match_bracket(buf, pos, line_graphemes, bracket_col)
    end
  end

  @spec do_match_bracket(GapBuffer.t(), position(), [String.t()], non_neg_integer()) ::
          position()
  defp do_match_bracket(buf, {line, col} = pos, line_graphemes, bracket_col) do
    bracket_char = Enum.at(line_graphemes, bracket_col)

    case Map.get(@bracket_pairs, bracket_char) do
      nil ->
        pos

      {open, close, direction} ->
        text = GapBuffer.content(buf)
        graphemes = String.graphemes(text)
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
    # Skip non-blank lines, then find next blank line
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
    graphemes = String.graphemes(text)
    total = length(graphemes)

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
    graphemes = String.graphemes(text)

    if graphemes == [] do
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
    graphemes = String.graphemes(text)
    total = length(graphemes)

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

  # `b` motion helpers: move backward to start of the previous/current word.

  # Moves backward from `offset`, first skipping whitespace, then finding the
  # start of the word (or punctuation) run. Returns the starting grapheme index.
  @spec do_word_backward([String.t()], non_neg_integer()) :: non_neg_integer()
  defp do_word_backward(graphemes, offset) do
    # Step 1: skip backward past any whitespace to land on a non-whitespace char.
    non_ws = backward_find(graphemes, offset, fn g -> not whitespace?(g) end)

    if non_ws < 0 do
      0
    else
      find_run_start_at(graphemes, non_ws)
    end
  end

  # Step 2: find the start of the word/punctuation run at `index`.
  @spec find_run_start_at([String.t()], non_neg_integer()) :: non_neg_integer()
  defp find_run_start_at(graphemes, index) do
    current = Enum.at(graphemes, index)

    if word_char?(current) do
      find_run_start(graphemes, index, &word_char?/1)
    else
      find_run_start(graphemes, index, fn g -> not word_char?(g) and not whitespace?(g) end)
    end
  end

  # Searches backward from `offset` for the first index where `pred` is true.
  # Returns -1 if no such index is found.
  @spec backward_find([String.t()], integer(), (String.t() -> boolean())) :: integer()
  defp backward_find(_graphemes, offset, _pred) when offset < 0, do: -1

  defp backward_find(graphemes, offset, pred) do
    if pred.(Enum.at(graphemes, offset)) do
      offset
    else
      backward_find(graphemes, offset - 1, pred)
    end
  end

  # Finds the leftmost consecutive index satisfying `pred`, starting from `offset`
  # and scanning backward. Returns `offset` itself if the char before it does not
  # satisfy `pred` (or we are at position 0).
  @spec find_run_start([String.t()], non_neg_integer(), (String.t() -> boolean())) ::
          non_neg_integer()
  defp find_run_start(graphemes, offset, pred) do
    if offset > 0 and pred.(Enum.at(graphemes, offset - 1)) do
      find_run_start(graphemes, offset - 1, pred)
    else
      offset
    end
  end

  # `w` motion: skip current non-whitespace run, then skip whitespace.
  # Works on a grapheme list; `max` is the last valid index.
  @spec do_word_forward([String.t()], non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp do_word_forward(_graphemes, offset, max) when offset >= max, do: max

  defp do_word_forward(graphemes, offset, max) do
    current = Enum.at(graphemes, offset)

    cond do
      # On whitespace (including newline): skip to first non-whitespace
      whitespace?(current) ->
        skip_while(graphemes, offset + 1, max, &whitespace?/1)

      # On a word char: skip word chars, then skip whitespace
      word_char?(current) ->
        after_word = skip_while(graphemes, offset + 1, max, &word_char?/1)
        skip_while(graphemes, after_word, max, &whitespace?/1)

      # On punctuation: skip punctuation, then skip whitespace
      true ->
        after_punct =
          skip_while(graphemes, offset + 1, max, fn g ->
            not word_char?(g) and not whitespace?(g)
          end)

        skip_while(graphemes, after_punct, max, &whitespace?/1)
    end
  end

  # `e` motion: skip whitespace forward, then go to last char of the next run.
  @spec do_word_end([String.t()], non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp do_word_end(_graphemes, offset, max) when offset >= max, do: max

  defp do_word_end(graphemes, offset, max) do
    # If we're not at end of buffer, start from offset+1 to look ahead
    start = min(offset + 1, max)
    current = Enum.at(graphemes, start)

    # Skip leading whitespace
    run_start =
      if whitespace?(current),
        do: skip_while(graphemes, start, max, &whitespace?/1),
        else: start

    # Now advance to the end of the word run
    run_char = Enum.at(graphemes, run_start)

    cond do
      word_char?(run_char) ->
        last_in_run(graphemes, run_start, max, &word_char?/1)

      not whitespace?(run_char) ->
        last_in_run(graphemes, run_start, max, fn g ->
          not word_char?(g) and not whitespace?(g)
        end)

      true ->
        run_start
    end
  end

  # Returns the index of the last consecutive element satisfying `pred`, starting at `offset`.
  @spec last_in_run([String.t()], non_neg_integer(), non_neg_integer(), (String.t() -> boolean())) ::
          non_neg_integer()
  defp last_in_run(graphemes, offset, max, pred) do
    next = offset + 1

    if next <= max and pred.(Enum.at(graphemes, next)) do
      last_in_run(graphemes, next, max, pred)
    else
      offset
    end
  end

  # Advances `offset` while the grapheme at `offset` satisfies `pred`, up to `max`.
  @spec skip_while([String.t()], non_neg_integer(), non_neg_integer(), (String.t() -> boolean())) ::
          non_neg_integer()
  defp skip_while(_graphemes, offset, max, _pred) when offset > max, do: max

  defp skip_while(graphemes, offset, max, pred) do
    g = Enum.at(graphemes, offset)

    if g != nil and pred.(g) do
      skip_while(graphemes, offset + 1, max, pred)
    else
      offset
    end
  end

  @spec word_char?(String.t() | nil) :: boolean()
  defp word_char?(nil), do: false
  defp word_char?(g), do: g =~ ~r/^[a-zA-Z0-9_]$/

  @spec whitespace?(String.t() | nil) :: boolean()
  defp whitespace?(nil), do: false
  defp whitespace?(g), do: g in [" ", "\t", "\n"]

  # ── Find-char helpers ────────────────────────────────────────────────────

  # Find first occurrence of `char` in `graphemes` starting from `from` index.
  @spec find_in_graphemes([String.t()], String.t(), non_neg_integer()) ::
          non_neg_integer() | nil
  defp find_in_graphemes(graphemes, char, from) do
    graphemes
    |> Enum.with_index()
    |> Enum.find_value(fn {g, idx} ->
      if idx >= from and g == char, do: idx
    end)
  end

  # Find last occurrence of `char` in `graphemes` at or before `to` index.
  @spec rfind_in_graphemes([String.t()], String.t(), integer()) ::
          non_neg_integer() | nil
  defp rfind_in_graphemes(_graphemes, _char, to) when to < 0, do: nil

  defp rfind_in_graphemes(graphemes, char, to) do
    graphemes
    |> Enum.with_index()
    |> Enum.filter(fn {g, idx} -> idx <= to and g == char end)
    |> List.last()
    |> case do
      nil -> nil
      {_g, idx} -> idx
    end
  end

  # ── Bracket matching helpers ─────────────────────────────────────────────

  @bracket_chars MapSet.new(["(", ")", "[", "]", "{", "}", "<", ">"])

  # Find first bracket char at or after `col` on the line.
  @spec find_bracket_on_line([String.t()], non_neg_integer()) :: non_neg_integer() | nil
  defp find_bracket_on_line(graphemes, col) do
    graphemes
    |> Enum.with_index()
    |> Enum.find_value(fn {g, idx} ->
      if idx >= col and MapSet.member?(@bracket_chars, g), do: idx
    end)
  end

  # Scan for matching bracket, counting nesting.
  @spec scan_for_match(
          [String.t()],
          non_neg_integer(),
          String.t(),
          String.t(),
          :forward | :backward
        ) ::
          non_neg_integer() | nil
  defp scan_for_match(graphemes, offset, open, close, :forward) do
    do_scan_forward(graphemes, offset + 1, length(graphemes), open, close, 1)
  end

  defp scan_for_match(graphemes, offset, open, close, :backward) do
    do_scan_backward(graphemes, offset - 1, open, close, 1)
  end

  @spec do_scan_forward(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) ::
          non_neg_integer() | nil
  defp do_scan_forward(_graphemes, idx, total, _open, _close, _depth) when idx >= total, do: nil

  defp do_scan_forward(graphemes, idx, total, open, close, depth) do
    g = Enum.at(graphemes, idx)

    cond do
      g == close and depth == 1 -> idx
      g == close -> do_scan_forward(graphemes, idx + 1, total, open, close, depth - 1)
      g == open -> do_scan_forward(graphemes, idx + 1, total, open, close, depth + 1)
      true -> do_scan_forward(graphemes, idx + 1, total, open, close, depth)
    end
  end

  @spec do_scan_backward([String.t()], integer(), String.t(), String.t(), non_neg_integer()) ::
          non_neg_integer() | nil
  defp do_scan_backward(_graphemes, idx, _open, _close, _depth) when idx < 0, do: nil

  defp do_scan_backward(graphemes, idx, open, close, depth) do
    g = Enum.at(graphemes, idx)

    cond do
      g == open and depth == 1 -> idx
      g == open -> do_scan_backward(graphemes, idx - 1, open, close, depth - 1)
      g == close -> do_scan_backward(graphemes, idx - 1, open, close, depth + 1)
      true -> do_scan_backward(graphemes, idx - 1, open, close, depth)
    end
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

  @spec do_word_forward_big([String.t()], non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_word_forward_big(_graphemes, offset, max) when offset >= max, do: max

  defp do_word_forward_big(graphemes, offset, max) do
    current = Enum.at(graphemes, offset)

    if whitespace?(current) do
      # On whitespace: skip to first non-whitespace
      skip_while(graphemes, offset + 1, max, &whitespace?/1)
    else
      # On non-whitespace: skip to whitespace, then skip whitespace
      after_word = skip_while(graphemes, offset + 1, max, fn g -> not whitespace?(g) end)
      skip_while(graphemes, after_word, max, &whitespace?/1)
    end
  end

  @spec do_word_backward_big([String.t()], non_neg_integer()) :: non_neg_integer()
  defp do_word_backward_big(graphemes, offset) do
    # Skip backward past whitespace
    non_ws = backward_find(graphemes, offset, fn g -> not whitespace?(g) end)

    if non_ws < 0 do
      0
    else
      # Find start of non-whitespace run
      find_run_start(graphemes, non_ws, fn g -> not whitespace?(g) end)
    end
  end

  @spec do_word_end_big([String.t()], non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_word_end_big(_graphemes, offset, max) when offset >= max, do: max

  defp do_word_end_big(graphemes, offset, max) do
    start = min(offset + 1, max)
    current = Enum.at(graphemes, start)

    run_start =
      if whitespace?(current),
        do: skip_while(graphemes, start, max, &whitespace?/1),
        else: start

    # Advance to end of non-whitespace run
    last_in_run(graphemes, run_start, max, fn g -> not whitespace?(g) end)
  end
end
