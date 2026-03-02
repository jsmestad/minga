defmodule Minga.Motion.Helpers do
  @moduledoc """
  Shared helper functions for Motion sub-modules.

  Contains character classification, offset calculation, and generic
  traversal primitives shared across word, line, and find-char motions.
  """

  # Inline hot character classification helpers for JIT optimization.
  @compile {:inline, word_char?: 1, whitespace?: 1, classify_char: 1}

  @typedoc "A zero-indexed {line, byte_col} cursor position."
  @type position :: Minga.Buffer.GapBuffer.position()

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

  # ── Offset helpers ────────────────────────────────────────────────────────

  @doc """
  Returns the byte offset for a given `{line, byte_col}` in pre-split lines.

  Uses `byte_size` for each line, consistent with byte-indexed positions.
  """
  @spec offset_for([String.t()], non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def offset_for(all_lines, line, col) do
    prefix =
      all_lines
      |> Enum.take(line)
      |> Enum.reduce(0, fn l, acc -> acc + byte_size(l) + 1 end)

    prefix + col
  end

  # ── Grapheme table with byte offsets ──────────────────────────────────────

  @typedoc "A grapheme table: {graphemes_tuple, byte_offsets_tuple}."
  @type grapheme_table :: {tuple(), tuple()}

  @doc """
  Builds a grapheme tuple with a parallel byte-offset lookup table.

  Returns `{graphemes, byte_offsets}` where `elem(graphemes, i)` is the
  i-th grapheme and `elem(byte_offsets, i)` is its byte offset in the
  original text.

  This enables word/char motions to scan by grapheme index (for character
  classification) while converting results to byte offsets (for positions).
  """
  @spec graphemes_with_byte_offsets(String.t()) :: grapheme_table()
  def graphemes_with_byte_offsets(text) do
    {gs, os} = do_graphemes_with_offsets(text, 0, [], [])
    {gs |> Enum.reverse() |> List.to_tuple(), os |> Enum.reverse() |> List.to_tuple()}
  end

  @spec do_graphemes_with_offsets(String.t(), non_neg_integer(), [String.t()], [
          non_neg_integer()
        ]) ::
          {[String.t()], [non_neg_integer()]}
  defp do_graphemes_with_offsets("", _byte_pos, gs, os), do: {gs, os}

  defp do_graphemes_with_offsets(text, byte_pos, gs, os) do
    case String.next_grapheme(text) do
      {g, rest} ->
        g_size = byte_size(text) - byte_size(rest)
        do_graphemes_with_offsets(rest, byte_pos + g_size, [g | gs], [byte_pos | os])

      nil ->
        {gs, os}
    end
  end

  @doc """
  Converts a grapheme index to its byte offset using the byte_offsets tuple.
  Clamps to `byte_size(text)` if index is at or past the end of the tuple.
  """
  @spec grapheme_index_to_byte_offset(tuple(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def grapheme_index_to_byte_offset(byte_offsets, grapheme_index, text_byte_size) do
    if grapheme_index >= tuple_size(byte_offsets) do
      text_byte_size
    else
      elem(byte_offsets, grapheme_index)
    end
  end

  @doc """
  Finds the grapheme index for a given byte offset using the byte_offsets tuple.
  Returns the index of the grapheme whose byte offset matches or is the largest
  not exceeding `byte_offset`.
  """
  @spec byte_offset_to_grapheme_index(tuple(), non_neg_integer()) :: non_neg_integer()
  def byte_offset_to_grapheme_index(byte_offsets, byte_offset) do
    size = tuple_size(byte_offsets)
    do_byte_offset_to_grapheme_index(byte_offsets, byte_offset, 0, size)
  end

  @spec do_byte_offset_to_grapheme_index(
          tuple(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          non_neg_integer()
  defp do_byte_offset_to_grapheme_index(_byte_offsets, _target, idx, size) when idx >= size do
    max(0, size - 1)
  end

  defp do_byte_offset_to_grapheme_index(byte_offsets, target, idx, size) do
    if elem(byte_offsets, idx) == target do
      idx
    else
      if idx + 1 < size and elem(byte_offsets, idx + 1) > target do
        idx
      else
        do_byte_offset_to_grapheme_index(byte_offsets, target, idx + 1, size)
      end
    end
  end

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
