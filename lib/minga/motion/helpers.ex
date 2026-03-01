defmodule Minga.Motion.Helpers do
  @moduledoc """
  Shared helper functions for Motion sub-modules.

  Contains character classification, offset calculation, and generic
  traversal primitives shared across word, line, and find-char motions.
  """

  # Inline hot character classification helpers for JIT optimization.
  @compile {:inline, word_char?: 1, whitespace?: 1, classify_char: 1}

  @typedoc "A zero-indexed {line, col} cursor position."
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

  @doc "Returns the grapheme offset for a given `{line, col}` in pre-split lines."
  @spec offset_for([String.t()], non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def offset_for(all_lines, line, col) do
    prefix =
      all_lines
      |> Enum.take(line)
      |> Enum.reduce(0, fn l, acc -> acc + String.length(l) + 1 end)

    prefix + col
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
