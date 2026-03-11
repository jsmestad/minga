defmodule Minga.Motion do
  @moduledoc """
  Pure cursor-motion functions for the Minga editor.

  Each function takes a `Readable.t()` and a current `position()`, and
  returns the new `position()` after applying the motion.  No buffer state
  is mutated — the caller is responsible for moving the buffer cursor via
  `Document.move_to/2` or `Buffer.Server.move_to/2`.

  This module is a facade over focused sub-modules:

  * `Motion.Word`     — `w`/`b`/`e`/`W`/`B`/`E` word motions
  * `Motion.Line`     — `0`/`$`/`^` line motions
  * `Motion.Document` — `gg`/`G`/`{`/`}` document & paragraph motions
  * `Motion.Char`     — `f`/`F`/`t`/`T` find-char and `%` bracket match

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

  alias Minga.Motion.Char
  alias Minga.Motion.Document, as: MotionDoc
  alias Minga.Motion.Line
  alias Minga.Motion.Word
  alias Minga.Text.Readable

  @typedoc "A zero-indexed {line, col} cursor position."
  @type position :: {non_neg_integer(), non_neg_integer()}

  # ── Word motions ─────────────────────────────────────────────────────────

  @doc """
  Move forward to the start of the next word (like Vim's `w`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Motion.word_forward(buf, {0, 0})
      {0, 6}
  """
  @spec word_forward(Readable.t(), position()) :: position()
  defdelegate word_forward(buf, pos), to: Word

  @doc """
  Move backward to the start of the previous word (like Vim's `b`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Motion.word_backward(buf, {0, 6})
      {0, 0}
  """
  @spec word_backward(Readable.t(), position()) :: position()
  defdelegate word_backward(buf, pos), to: Word

  @doc """
  Move to the end of the current or next word (like Vim's `e`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Motion.word_end(buf, {0, 0})
      {0, 4}
  """
  @spec word_end(Readable.t(), position()) :: position()
  defdelegate word_end(buf, pos), to: Word

  @doc """
  Move forward to the start of the next WORD (Vim's `W`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("foo.bar baz")
      iex> Minga.Motion.word_forward_big(buf, {0, 0})
      {0, 8}
  """
  @spec word_forward_big(Readable.t(), position()) :: position()
  defdelegate word_forward_big(buf, pos), to: Word

  @doc """
  Move backward to the start of the previous WORD (Vim's `B`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("foo.bar baz")
      iex> Minga.Motion.word_backward_big(buf, {0, 8})
      {0, 0}
  """
  @spec word_backward_big(Readable.t(), position()) :: position()
  defdelegate word_backward_big(buf, pos), to: Word

  @doc """
  Move to the end of the current or next WORD (Vim's `E`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("foo.bar baz")
      iex> Minga.Motion.word_end_big(buf, {0, 0})
      {0, 6}
  """
  @spec word_end_big(Readable.t(), position()) :: position()
  defdelegate word_end_big(buf, pos), to: Word

  # ── Line motions ─────────────────────────────────────────────────────────

  @doc """
  Move to the first column of the current line (like Vim's `0`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("  hello")
      iex> Minga.Motion.line_start(buf, {0, 4})
      {0, 0}
  """
  @spec line_start(Readable.t(), position()) :: position()
  defdelegate line_start(buf, pos), to: Line

  @doc """
  Move to the last column of the current line (like Vim's `$`).
  Returns the position of the last grapheme on the line.
  For an empty line, returns `{line, 0}`.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello\\nworld")
      iex> Minga.Motion.line_end(buf, {0, 0})
      {0, 4}
  """
  @spec line_end(Readable.t(), position()) :: position()
  defdelegate line_end(buf, pos), to: Line

  @doc """
  Move to the first non-blank character on the current line (like Vim's `^`).
  Falls back to `{line, 0}` when the line is entirely blank.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("  hello")
      iex> Minga.Motion.first_non_blank(buf, {0, 0})
      {0, 2}
  """
  @spec first_non_blank(Readable.t(), position()) :: position()
  defdelegate first_non_blank(buf, pos), to: Line

  # ── Document motions ──────────────────────────────────────────────────────

  @doc """
  Move to the very start of the buffer (like Vim's `gg`).
  Always returns `{0, 0}`.

  ## Examples

      iex> Minga.Motion.document_start(Minga.Buffer.Document.new("hello\\nworld"))
      {0, 0}
  """
  @spec document_start(Readable.t()) :: position()
  defdelegate document_start(buf), to: MotionDoc

  @doc """
  Move to the last character of the last line (like Vim's `G`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello\\nworld")
      iex> Minga.Motion.document_end(buf)
      {1, 4}
  """
  @spec document_end(Readable.t()) :: position()
  defdelegate document_end(buf), to: MotionDoc

  @doc """
  Move to the next blank line (Vim's `}`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello\\nworld\\n\\nfoo")
      iex> Minga.Motion.paragraph_forward(buf, {0, 0})
      {2, 0}
  """
  @spec paragraph_forward(Readable.t(), position()) :: position()
  defdelegate paragraph_forward(buf, pos), to: MotionDoc

  @doc """
  Move to the previous blank line (Vim's `{`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello\\nworld\\n\\nfoo")
      iex> Minga.Motion.paragraph_backward(buf, {3, 0})
      {2, 0}
  """
  @spec paragraph_backward(Readable.t(), position()) :: position()
  defdelegate paragraph_backward(buf, pos), to: MotionDoc

  # ── Find-char motions ─────────────────────────────────────────────────────

  @doc """
  Move forward to the next occurrence of `char` on the current line (Vim's `f`).
  Returns the original position if `char` is not found.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Motion.find_char_forward(buf, {0, 0}, "o")
      {0, 4}
  """
  @spec find_char_forward(Readable.t(), position(), String.t()) :: position()
  defdelegate find_char_forward(buf, pos, char), to: Char

  @doc """
  Move backward to the previous occurrence of `char` on the current line (Vim's `F`).
  Returns the original position if `char` is not found.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Motion.find_char_backward(buf, {0, 7}, "o")
      {0, 4}
  """
  @spec find_char_backward(Readable.t(), position(), String.t()) :: position()
  defdelegate find_char_backward(buf, pos, char), to: Char

  @doc """
  Move to one before the next occurrence of `char` on the current line (Vim's `t`).
  Returns the original position if `char` is not found.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Motion.till_char_forward(buf, {0, 0}, "o")
      {0, 3}
  """
  @spec till_char_forward(Readable.t(), position(), String.t()) :: position()
  defdelegate till_char_forward(buf, pos, char), to: Char

  @doc """
  Move to one after the previous occurrence of `char` on the current line (Vim's `T`).
  Returns the original position if `char` is not found.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Motion.till_char_backward(buf, {0, 7}, "o")
      {0, 5}
  """
  @spec till_char_backward(Readable.t(), position(), String.t()) :: position()
  defdelegate till_char_backward(buf, pos, char), to: Char

  @doc """
  Jump to the matching bracket/paren/brace (Vim's `%`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("(hello)")
      iex> Minga.Motion.match_bracket(buf, {0, 0})
      {0, 6}
  """
  @spec match_bracket(Readable.t(), position()) :: position()
  defdelegate match_bracket(buf, pos), to: Char
end
