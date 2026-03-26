defmodule Minga.Editing.Motion.Helpers do
  @moduledoc """
  Shared helper functions for Motion sub-modules.

  Contains character classification, offset calculation, and generic
  traversal primitives shared across word, line, and find-char motions.

  Byte ↔ grapheme conversion is delegated to `Minga.Buffer.Unicode`.
  """

  alias Minga.Buffer.Unicode

  # Inline hot character classification helpers for JIT optimization.
  @compile {:inline, word_char?: 1, whitespace?: 1, classify_char: 1}

  @typedoc "A zero-indexed {line, byte_col} cursor position."
  @type position :: Minga.Buffer.Document.position()

  # ── Character classification ─────────────────────────────────────────────

  @doc "Classifies a grapheme as `:word`, `:whitespace`, or `:punctuation`."
  @spec classify_char(String.t()) :: :word | :whitespace | :punctuation
  def classify_char(<<c, _::binary>>) when c >= ?a and c <= ?z, do: :word
  def classify_char(<<c, _::binary>>) when c >= ?A and c <= ?Z, do: :word
  def classify_char(<<c, _::binary>>) when c >= ?0 and c <= ?9, do: :word
  def classify_char(<<?_, _::binary>>), do: :word
  def classify_char(<<?\s, _::binary>>), do: :whitespace
  def classify_char(<<?\t, _::binary>>), do: :whitespace
  def classify_char(<<?\n, _::binary>>), do: :whitespace
  def classify_char(_), do: :punctuation

  @doc "Returns `true` when the grapheme is a word character (`[a-zA-Z0-9_]`)."
  @spec word_char?(String.t() | nil) :: boolean()
  def word_char?(nil), do: false
  def word_char?(g), do: classify_char(g) == :word

  @doc "Returns `true` when the grapheme is whitespace (space, tab, or newline)."
  @spec whitespace?(String.t() | nil) :: boolean()
  def whitespace?(nil), do: false
  def whitespace?(g), do: classify_char(g) == :whitespace

  # ── Delegated Unicode helpers ─────────────────────────────────────────────

  @doc "Delegates to `Minga.Buffer.Unicode.byte_offset_for/3`."
  @spec offset_for([String.t()], non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defdelegate offset_for(all_lines, line, col), to: Unicode, as: :byte_offset_for

  @doc "Delegates to `Minga.Buffer.Unicode.graphemes_with_byte_offsets/1`."
  @spec graphemes_with_byte_offsets(String.t()) :: Unicode.grapheme_table()
  defdelegate graphemes_with_byte_offsets(text), to: Unicode

  @doc "Delegates to `Minga.Buffer.Unicode.grapheme_index_to_byte_offset/3`."
  @spec grapheme_index_to_byte_offset(tuple(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defdelegate grapheme_index_to_byte_offset(byte_offsets, grapheme_index, text_byte_size),
    to: Unicode

  @doc "Delegates to `Minga.Buffer.Unicode.byte_offset_to_grapheme_index/2`."
  @spec byte_offset_to_grapheme_index(tuple(), non_neg_integer()) :: non_neg_integer()
  defdelegate byte_offset_to_grapheme_index(byte_offsets, byte_offset), to: Unicode

  # ── Generic traversal helpers ─────────────────────────────────────────────

  @doc "Skips forward while `pred` holds, stopping at `max`."
  @spec skip_while(tuple(), non_neg_integer(), non_neg_integer(), (String.t() -> boolean())) ::
          non_neg_integer()
  def skip_while(_graphemes, offset, max, _pred) when offset > max, do: max

  def skip_while(graphemes, offset, max, pred) do
    if pred.(elem(graphemes, offset)) do
      skip_while(graphemes, offset + 1, max, pred)
    else
      offset
    end
  end

  @doc "Finds the last index in a contiguous run where `pred` holds, starting from `offset`."
  @spec last_in_run(tuple(), non_neg_integer(), non_neg_integer(), (String.t() -> boolean())) ::
          non_neg_integer()
  def last_in_run(graphemes, offset, max, pred) do
    next = offset + 1

    if next <= max and pred.(elem(graphemes, next)) do
      last_in_run(graphemes, next, max, pred)
    else
      offset
    end
  end

  @doc "Walks backward from `offset`, returning the first index where `pred` holds. Returns `-1` if none."
  @spec backward_find(tuple(), integer(), (String.t() -> boolean())) :: integer()
  def backward_find(_graphemes, offset, _pred) when offset < 0, do: -1

  def backward_find(graphemes, offset, pred) do
    if pred.(elem(graphemes, offset)) do
      offset
    else
      backward_find(graphemes, offset - 1, pred)
    end
  end

  @doc "Finds the start of the run at `index` according to `pred`."
  @spec find_run_start(tuple(), non_neg_integer(), (String.t() -> boolean())) ::
          non_neg_integer()
  def find_run_start(graphemes, offset, pred) do
    if offset > 0 and pred.(elem(graphemes, offset - 1)) do
      find_run_start(graphemes, offset - 1, pred)
    else
      offset
    end
  end

  @doc "Finds the start of a word or punctuation run at `index`."
  @spec find_run_start_at(tuple(), non_neg_integer()) :: non_neg_integer()
  def find_run_start_at(graphemes, index) do
    current = elem(graphemes, index)

    if word_char?(current) do
      find_run_start(graphemes, index, &word_char?/1)
    else
      find_run_start(graphemes, index, fn g -> not word_char?(g) and not whitespace?(g) end)
    end
  end
end
