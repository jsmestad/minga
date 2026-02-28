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
  """
  @spec line_start(GapBuffer.t(), position()) :: position()
  def line_start(%GapBuffer{}, {line, _col}), do: {line, 0}

  @doc """
  Move to the last column of the current line (like Vim's `$`).
  Returns the position of the last grapheme on the line.
  For an empty line, returns `{line, 0}`.
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
  """
  @spec document_start(GapBuffer.t()) :: position()
  def document_start(%GapBuffer{}), do: {0, 0}

  @doc """
  Move to the last character of the last line (like Vim's `G`).
  """
  @spec document_end(GapBuffer.t()) :: position()
  def document_end(%GapBuffer{} = buf) do
    last_line = GapBuffer.line_count(buf) - 1
    line_end(buf, {last_line, 0})
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
      current = Enum.at(graphemes, non_ws)

      # Step 2: find the start of this word/punctuation run.
      if word_char?(current) do
        find_run_start(graphemes, non_ws, &word_char?/1)
      else
        find_run_start(graphemes, non_ws, fn g -> not word_char?(g) and not whitespace?(g) end)
      end
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
        after_punct = skip_while(graphemes, offset + 1, max, fn g -> not word_char?(g) and not whitespace?(g) end)
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
        last_in_run(graphemes, run_start, max, fn g -> not word_char?(g) and not whitespace?(g) end)

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
end
