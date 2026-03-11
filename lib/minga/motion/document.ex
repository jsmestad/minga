defmodule Minga.Motion.Document do
  @moduledoc """
  Document-level and paragraph cursor motion functions.
  """

  alias Minga.Motion.Line
  alias Minga.Text.Readable

  @typedoc "A zero-indexed {line, col} cursor position."
  @type position :: {non_neg_integer(), non_neg_integer()}

  @doc """
  Move to the very start of the buffer (Vim's `gg`).
  Always returns `{0, 0}`.

  ## Examples

      iex> Minga.Motion.Document.document_start(Minga.Buffer.Document.new("hello\\nworld"))
      {0, 0}
  """
  @spec document_start(Readable.t()) :: position()
  def document_start(_buf), do: {0, 0}

  @doc """
  Move to the last character of the last line (Vim's `G`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello\\nworld")
      iex> Minga.Motion.Document.document_end(buf)
      {1, 4}
  """
  @spec document_end(Readable.t()) :: position()
  def document_end(buf) do
    last_line = Readable.line_count(buf) - 1
    Line.line_end(buf, {last_line, 0})
  end

  @doc """
  Move to the next blank line (Vim's `}`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello\\nworld\\n\\nfoo")
      iex> Minga.Motion.Document.paragraph_forward(buf, {0, 0})
      {2, 0}
  """
  @spec paragraph_forward(Readable.t(), position()) :: position()
  def paragraph_forward(buf, {line, _col}) do
    total = Readable.line_count(buf)
    find_paragraph_boundary(buf, line + 1, total, :forward)
  end

  @doc """
  Move to the previous blank line (Vim's `{`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello\\nworld\\n\\nfoo")
      iex> Minga.Motion.Document.paragraph_backward(buf, {3, 0})
      {2, 0}
  """
  @spec paragraph_backward(Readable.t(), position()) :: position()
  def paragraph_backward(buf, {line, _col}) do
    find_paragraph_boundary(buf, line - 1, Readable.line_count(buf), :backward)
  end

  @spec find_paragraph_boundary(
          Readable.t(),
          integer(),
          non_neg_integer(),
          :forward | :backward
        ) :: position()
  defp find_paragraph_boundary(_buf, line, _total, _dir) when line < 0, do: {0, 0}

  defp find_paragraph_boundary(_buf, line, total, _dir) when line >= total do
    {max(0, total - 1), 0}
  end

  defp find_paragraph_boundary(buf, line, total, dir) do
    line_text = Readable.line_at(buf, line) || ""
    next = if dir == :forward, do: line + 1, else: line - 1

    if blank_line?(line_text) do
      {line, 0}
    else
      find_paragraph_boundary(buf, next, total, dir)
    end
  end

  @spec blank_line?(String.t()) :: boolean()
  defp blank_line?(text), do: String.trim(text) == ""
end
