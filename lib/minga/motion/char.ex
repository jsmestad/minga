defmodule Minga.Motion.Char do
  @moduledoc """
  Character find motions (`f`/`F`/`t`/`T`) and bracket matching (`%`).
  """

  alias Minga.Buffer.GapBuffer
  alias Minga.Motion.Helpers

  @typedoc "A zero-indexed {line, col} cursor position."
  @type position :: GapBuffer.position()

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

      iex> buf = Minga.Buffer.GapBuffer.new("hello world")
      iex> Minga.Motion.Char.find_char_forward(buf, {0, 0}, "o")
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
      iex> Minga.Motion.Char.find_char_backward(buf, {0, 7}, "o")
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
      iex> Minga.Motion.Char.till_char_forward(buf, {0, 0}, "o")
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
      iex> Minga.Motion.Char.till_char_backward(buf, {0, 7}, "o")
      {0, 5}
  """
  @spec till_char_backward(GapBuffer.t(), position(), String.t()) :: position()
  def till_char_backward(%GapBuffer{} = buf, {line, col}, char) do
    case find_char_backward(buf, {line, col}, char) do
      {^line, ^col} -> {line, col}
      {^line, found_col} -> {line, min(col, found_col + 1)}
    end
  end

  @doc """
  Jump to the matching bracket/paren/brace (Vim's `%`).

  Scans forward from cursor to find the first bracket character, then
  finds its match counting nesting. Returns original position if no
  bracket is found or match is unbalanced.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("(hello)")
      iex> Minga.Motion.Char.match_bracket(buf, {0, 0})
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
        abs_offset = Helpers.offset_for(all_lines, line, col) - col + bracket_col

        case scan_for_match(graphemes, abs_offset, open, close, direction) do
          nil -> pos
          match_offset -> GapBuffer.offset_to_position(buf, match_offset)
        end
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Walk forward through the binary, tracking grapheme index.
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

  # Reverse find in a tuple.
  @spec rfind_in_tuple(tuple(), String.t(), integer()) :: non_neg_integer() | nil
  defp rfind_in_tuple(_graphemes, _char, to) when to < 0, do: nil

  defp rfind_in_tuple(graphemes, char, to) do
    if elem(graphemes, to) == char do
      to
    else
      rfind_in_tuple(graphemes, char, to - 1)
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
