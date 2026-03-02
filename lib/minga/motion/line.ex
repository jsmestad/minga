defmodule Minga.Motion.Line do
  @moduledoc """
  Line-level cursor motion functions: start, end, and first-non-blank.
  """

  alias Minga.Buffer.GapBuffer
  alias Minga.Buffer.Unicode

  @typedoc "A zero-indexed {line, col} cursor position."
  @type position :: GapBuffer.position()

  @doc """
  Move to the first column of the current line (Vim's `0`).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("  hello")
      iex> Minga.Motion.Line.line_start(buf, {0, 4})
      {0, 0}
  """
  @spec line_start(GapBuffer.t(), position()) :: position()
  def line_start(%GapBuffer{}, {line, _col}), do: {line, 0}

  @doc """
  Move to the last column of the current line (Vim's `$`).
  Returns `{line, 0}` for an empty line.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello\\nworld")
      iex> Minga.Motion.Line.line_end(buf, {0, 0})
      {0, 4}
  """
  @spec line_end(GapBuffer.t(), position()) :: position()
  def line_end(%GapBuffer{} = buf, {line, _col}) do
    case GapBuffer.line_at(buf, line) do
      nil -> {line, 0}
      "" -> {line, 0}
      text -> {line, Unicode.last_grapheme_byte_offset(text)}
    end
  end

  @doc """
  Move to the first non-blank character on the current line (Vim's `^`).
  Falls back to `{line, 0}` when the line is entirely blank.

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("  hello")
      iex> Minga.Motion.Line.first_non_blank(buf, {0, 0})
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

  # Walk the binary to find first non-blank, tracking byte offset.
  @spec find_first_non_blank(String.t(), non_neg_integer()) :: non_neg_integer()
  defp find_first_non_blank(text, byte_col) do
    case String.next_grapheme(text) do
      {g, rest} when g in [" ", "\t"] -> find_first_non_blank(rest, byte_col + byte_size(g))
      {_g, _rest} -> byte_col
      nil -> 0
    end
  end
end
