defmodule Minga.Motion.Char do
  @moduledoc """
  Character find motions (`f`/`F`/`t`/`T`) and bracket matching (`%`).

  All positions use byte-indexed columns. Character search functions
  track byte offsets while scanning graphemes.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Unicode
  alias Minga.Motion.Helpers

  @typedoc "A zero-indexed {line, byte_col} cursor position."
  @type position :: Document.position()

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

  @bracket_chars MapSet.new(["(", ")", "[", "]", "{", "}", "<", ">"])

  @doc """
  Move forward to the next occurrence of `char` on the current line (Vim's `f`).
  Returns the original position if `char` is not found.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Motion.Char.find_char_forward(buf, {0, 0}, "o")
      {0, 4}
  """
  @spec find_char_forward(Document.t(), position(), String.t()) :: position()
  def find_char_forward(%Document{} = buf, {line, col}, char) do
    case Document.line_at(buf, line) do
      nil ->
        {line, col}

      text ->
        # Search starting after current byte_col
        case find_forward_byte(text, char, col) do
          nil -> {line, col}
          byte_col -> {line, byte_col}
        end
    end
  end

  @doc """
  Move backward to the previous occurrence of `char` on the current line (Vim's `F`).
  Returns the original position if `char` is not found.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Motion.Char.find_char_backward(buf, {0, 7}, "o")
      {0, 4}
  """
  @spec find_char_backward(Document.t(), position(), String.t()) :: position()
  def find_char_backward(%Document{} = buf, {line, col}, char) do
    case Document.line_at(buf, line) do
      nil ->
        {line, col}

      text ->
        case find_backward_byte(text, char, col) do
          nil -> {line, col}
          byte_col -> {line, byte_col}
        end
    end
  end

  @doc """
  Move to one before the next occurrence of `char` on the current line (Vim's `t`).
  Returns the original position if `char` is not found.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Motion.Char.till_char_forward(buf, {0, 0}, "o")
      {0, 3}
  """
  @spec till_char_forward(Document.t(), position(), String.t()) :: position()
  def till_char_forward(%Document{} = buf, {line, col}, char) do
    case find_char_forward(buf, {line, col}, char) do
      {^line, ^col} ->
        {line, col}

      {^line, found_col} ->
        # Move to the grapheme before found_col
        line_text = Document.line_at(buf, line) || ""
        prev_byte = Unicode.prev_grapheme_byte_offset(line_text, found_col)
        {line, max(col, prev_byte)}
    end
  end

  @doc """
  Move to one after the previous occurrence of `char` on the current line (Vim's `T`).
  Returns the original position if `char` is not found.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Motion.Char.till_char_backward(buf, {0, 7}, "o")
      {0, 5}
  """
  @spec till_char_backward(Document.t(), position(), String.t()) :: position()
  def till_char_backward(%Document{} = buf, {line, col}, char) do
    case find_char_backward(buf, {line, col}, char) do
      {^line, ^col} ->
        {line, col}

      {^line, found_col} ->
        # Move to the grapheme after found_col
        line_text = Document.line_at(buf, line) || ""
        next_byte = Unicode.next_grapheme_byte_offset(line_text, found_col)
        {line, min(col, next_byte)}
    end
  end

  @doc """
  Jump to the matching bracket/paren/brace (Vim's `%`).

  Scans forward from cursor to find the first bracket character, then
  finds its match counting nesting. Returns original position if no
  bracket is found or match is unbalanced.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("(hello)")
      iex> Minga.Motion.Char.match_bracket(buf, {0, 0})
      {0, 6}
  """
  @spec match_bracket(Document.t(), position()) :: position()
  def match_bracket(%Document{} = buf, {line, col} = pos) do
    current_line_text = Document.line_at(buf, line) || ""
    {graphemes, byte_offsets} = Helpers.graphemes_with_byte_offsets(current_line_text)
    g_col = Helpers.byte_offset_to_grapheme_index(byte_offsets, col)

    case find_bracket_on_line(graphemes, g_col, tuple_size(graphemes)) do
      nil -> pos
      bracket_g_idx -> do_match_bracket(buf, pos, graphemes, byte_offsets, bracket_g_idx)
    end
  end

  @spec do_match_bracket(Document.t(), position(), tuple(), tuple(), non_neg_integer()) ::
          position()
  defp do_match_bracket(buf, {line, col} = pos, line_graphemes, line_byte_offsets, bracket_g_idx) do
    bracket_char = elem(line_graphemes, bracket_g_idx)

    case Map.get(@bracket_pairs, bracket_char) do
      nil ->
        pos

      {open, close, direction} ->
        text = Document.content(buf)
        {graphemes, byte_offsets} = Helpers.graphemes_with_byte_offsets(text)
        all_lines = :binary.split(text, "\n", [:global])
        g_col = Helpers.byte_offset_to_grapheme_index(line_byte_offsets, col)
        byte_off = Helpers.offset_for(all_lines, line, col)
        g_offset = Helpers.byte_offset_to_grapheme_index(byte_offsets, byte_off)
        abs_g_offset = g_offset - g_col + bracket_g_idx

        case scan_for_match(graphemes, abs_g_offset, open, close, direction) do
          nil ->
            pos

          match_g_idx ->
            match_byte =
              Helpers.grapheme_index_to_byte_offset(byte_offsets, match_g_idx, byte_size(text))

            Document.offset_to_position(buf, match_byte)
        end
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Find char forward in text, starting after `after_byte_col`. Returns byte offset or nil.
  @spec find_forward_byte(String.t(), String.t(), non_neg_integer()) :: non_neg_integer() | nil
  defp find_forward_byte(text, char, after_byte_col) do
    do_find_forward_byte(text, char, after_byte_col, 0, false)
  end

  @spec do_find_forward_byte(
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          boolean()
        ) ::
          non_neg_integer() | nil
  defp do_find_forward_byte(text, char, after_byte_col, current_byte, past_start) do
    case String.next_grapheme(text) do
      {g, rest} ->
        g_size = byte_size(text) - byte_size(rest)
        new_past = past_start or current_byte >= after_byte_col

        if new_past and current_byte > after_byte_col and g == char do
          current_byte
        else
          do_find_forward_byte(rest, char, after_byte_col, current_byte + g_size, new_past)
        end

      nil ->
        nil
    end
  end

  # Find char backward in text, before `before_byte_col`. Returns byte offset or nil.
  @spec find_backward_byte(String.t(), String.t(), non_neg_integer()) :: non_neg_integer() | nil
  defp find_backward_byte(text, char, before_byte_col) do
    # Build list of {byte_offset, grapheme} for positions before before_byte_col
    do_find_backward_byte(text, char, before_byte_col, 0, nil)
  end

  @spec do_find_backward_byte(
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer() | nil
        ) ::
          non_neg_integer() | nil
  defp do_find_backward_byte(text, char, before_byte_col, current_byte, last_match) do
    case String.next_grapheme(text) do
      {g, rest} ->
        g_size = byte_size(text) - byte_size(rest)

        new_match =
          if current_byte < before_byte_col and g == char, do: current_byte, else: last_match

        do_find_backward_byte(rest, char, before_byte_col, current_byte + g_size, new_match)

      nil ->
        last_match
    end
  end

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
        ) :: non_neg_integer() | nil
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
        ) :: non_neg_integer() | nil
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
end
