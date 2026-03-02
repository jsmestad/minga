defmodule Minga.Buffer.Unicode do
  @moduledoc """
  Byte ↔ grapheme conversion utilities for byte-indexed buffer positions.

  This module is the single source of truth for converting between byte
  offsets (used internally by the gap buffer, motions, and tree-sitter)
  and grapheme indices (used for display rendering).

  All functions operate on UTF-8 binary strings.
  """

  # ── Grapheme table ────────────────────────────────────────────────────────

  @typedoc "A grapheme table: `{graphemes_tuple, byte_offsets_tuple}`."
  @type grapheme_table :: {tuple(), tuple()}

  @doc """
  Builds a grapheme tuple with a parallel byte-offset lookup table.

  Returns `{graphemes, byte_offsets}` where `elem(graphemes, i)` is the
  i-th grapheme and `elem(byte_offsets, i)` is its byte offset in the
  original text.

  ## Examples

      iex> {gs, os} = Minga.Buffer.Unicode.graphemes_with_byte_offsets("café")
      iex> tuple_size(gs)
      4
      iex> elem(os, 3)
      4
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

  # ── Index conversion ──────────────────────────────────────────────────────

  @doc """
  Converts a grapheme index to its byte offset using the byte_offsets tuple.
  Clamps to `text_byte_size` if index is at or past the end.

  ## Examples

      iex> {_, os} = Minga.Buffer.Unicode.graphemes_with_byte_offsets("café")
      iex> Minga.Buffer.Unicode.grapheme_index_to_byte_offset(os, 3, 5)
      4
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
  Returns the index of the grapheme at or just before `byte_offset`.

  ## Examples

      iex> {_, os} = Minga.Buffer.Unicode.graphemes_with_byte_offsets("café")
      iex> Minga.Buffer.Unicode.byte_offset_to_grapheme_index(os, 4)
      3
  """
  @spec byte_offset_to_grapheme_index(tuple(), non_neg_integer()) :: non_neg_integer()
  def byte_offset_to_grapheme_index(byte_offsets, byte_offset) do
    size = tuple_size(byte_offsets)
    do_byte_to_grapheme(byte_offsets, byte_offset, 0, size)
  end

  @spec do_byte_to_grapheme(tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_byte_to_grapheme(_byte_offsets, _target, idx, size) when idx >= size do
    max(0, size - 1)
  end

  defp do_byte_to_grapheme(byte_offsets, target, idx, size) do
    if elem(byte_offsets, idx) == target do
      idx
    else
      if idx + 1 < size and elem(byte_offsets, idx + 1) > target do
        idx
      else
        do_byte_to_grapheme(byte_offsets, target, idx + 1, size)
      end
    end
  end

  # ── Byte offset for all lines ─────────────────────────────────────────────

  @doc """
  Returns the absolute byte offset for a `{line, byte_col}` position given
  pre-split lines. Each line contributes `byte_size(line) + 1` bytes
  (the +1 accounts for the `\\n` separator).

  ## Examples

      iex> Minga.Buffer.Unicode.byte_offset_for(["hello", "world"], 1, 3)
      9
  """
  @spec byte_offset_for([String.t()], non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def byte_offset_for(all_lines, line, col) do
    prefix =
      all_lines
      |> Enum.take(line)
      |> Enum.reduce(0, fn l, acc -> acc + byte_size(l) + 1 end)

    prefix + col
  end

  # ── Single-position helpers ───────────────────────────────────────────────

  @doc """
  Returns the byte offset of the last grapheme's first byte in `text`.
  Returns 0 for empty strings.

  ## Examples

      iex> Minga.Buffer.Unicode.last_grapheme_byte_offset("café")
      4

      iex> Minga.Buffer.Unicode.last_grapheme_byte_offset("")
      0
  """
  @spec last_grapheme_byte_offset(String.t()) :: non_neg_integer()
  def last_grapheme_byte_offset(""), do: 0

  def last_grapheme_byte_offset(text) do
    do_last_grapheme_byte_offset(text, 0, 0)
  end

  @spec do_last_grapheme_byte_offset(String.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_last_grapheme_byte_offset(text, byte_pos, last_pos) do
    case String.next_grapheme(text) do
      {_g, rest} ->
        g_size = byte_size(text) - byte_size(rest)
        do_last_grapheme_byte_offset(rest, byte_pos + g_size, byte_pos)

      nil ->
        last_pos
    end
  end

  @doc """
  Returns the byte offset of the grapheme just before `target_byte`.
  Returns 0 if `target_byte` is 0 or at the first grapheme.

  ## Examples

      iex> Minga.Buffer.Unicode.prev_grapheme_byte_offset("café", 4)
      3
  """
  @spec prev_grapheme_byte_offset(String.t(), non_neg_integer()) :: non_neg_integer()
  def prev_grapheme_byte_offset(_text, 0), do: 0

  def prev_grapheme_byte_offset(text, target_byte) do
    do_prev_grapheme(text, target_byte, 0, 0)
  end

  @spec do_prev_grapheme(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_prev_grapheme(text, target, current_byte, prev_byte) do
    case String.next_grapheme(text) do
      {_g, rest} ->
        g_size = byte_size(text) - byte_size(rest)
        next_byte = current_byte + g_size

        if next_byte >= target do
          current_byte
        else
          do_prev_grapheme(rest, target, next_byte, current_byte)
        end

      nil ->
        prev_byte
    end
  end

  @doc """
  Returns the byte offset of the grapheme just after the one at `byte_col`.

  ## Examples

      iex> Minga.Buffer.Unicode.next_grapheme_byte_offset("café", 3)
      5
  """
  @spec next_grapheme_byte_offset(String.t(), non_neg_integer()) :: non_neg_integer()
  def next_grapheme_byte_offset(text, byte_col) do
    do_next_grapheme(text, byte_col, 0)
  end

  @spec do_next_grapheme(String.t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp do_next_grapheme(text, target, current_byte) do
    case String.next_grapheme(text) do
      {_g, rest} ->
        g_size = byte_size(text) - byte_size(rest)
        next_byte = current_byte + g_size

        if current_byte >= target do
          next_byte
        else
          do_next_grapheme(rest, target, next_byte)
        end

      nil ->
        current_byte
    end
  end

  @doc """
  Returns the grapheme at `byte_col` in `text`, or nil if out of bounds.

  ## Examples

      iex> Minga.Buffer.Unicode.grapheme_at("café", 3)
      "é"

      iex> Minga.Buffer.Unicode.grapheme_at("café", 10)
      nil
  """
  @spec grapheme_at(String.t(), non_neg_integer()) :: String.t() | nil
  def grapheme_at(text, byte_col) when byte_col >= byte_size(text), do: nil

  def grapheme_at(text, byte_col) do
    rest = binary_part(text, byte_col, byte_size(text) - byte_col)

    case String.next_grapheme(rest) do
      {g, _} -> g
      nil -> nil
    end
  end

  @doc """
  Clamps a byte offset to land on a grapheme boundary.
  If `byte_col` falls mid-grapheme, returns the start of that grapheme.

  ## Examples

      iex> Minga.Buffer.Unicode.clamp_to_grapheme_boundary("café", 4)
      4

      iex> Minga.Buffer.Unicode.clamp_to_grapheme_boundary("café", 5)
      4
  """
  @spec clamp_to_grapheme_boundary(String.t(), non_neg_integer()) :: non_neg_integer()
  def clamp_to_grapheme_boundary(_text, 0), do: 0

  def clamp_to_grapheme_boundary(text, byte_col) do
    do_clamp_boundary(text, byte_col, 0)
  end

  @spec do_clamp_boundary(String.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_clamp_boundary(text, target, current) do
    case String.next_grapheme(text) do
      {_g, rest} ->
        g_size = byte_size(text) - byte_size(rest)
        next = current + g_size

        cond do
          current == target -> current
          next > target -> current
          true -> do_clamp_boundary(rest, target, next)
        end

      nil ->
        current
    end
  end

  @doc """
  Converts a byte column to a grapheme (display) column by counting
  graphemes in the first `byte_col` bytes of `text`.

  ## Examples

      iex> Minga.Buffer.Unicode.grapheme_col("café", 4)
      3
  """
  @spec grapheme_col(String.t(), non_neg_integer()) :: non_neg_integer()
  def grapheme_col(_text, 0), do: 0

  def grapheme_col(text, byte_col) do
    do_grapheme_col(text, byte_col, 0, 0)
  end

  @spec do_grapheme_col(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_grapheme_col(_text, target, current, count) when current >= target, do: count

  defp do_grapheme_col(text, target, current, count) do
    case String.next_grapheme(text) do
      {_g, rest} ->
        g_size = byte_size(text) - byte_size(rest)
        do_grapheme_col(rest, target, current + g_size, count + 1)

      nil ->
        count
    end
  end

  @doc """
  Converts a grapheme (display) column to a byte column.

  ## Examples

      iex> Minga.Buffer.Unicode.byte_col_for_grapheme("café", 3)
      4
  """
  @spec byte_col_for_grapheme(String.t(), non_neg_integer()) :: non_neg_integer()
  def byte_col_for_grapheme(_text, 0), do: 0

  def byte_col_for_grapheme(text, grapheme_col) do
    do_byte_col_for_grapheme(text, grapheme_col, 0, 0)
  end

  @spec do_byte_col_for_grapheme(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp do_byte_col_for_grapheme(_text, target, _byte_pos, count) when count >= target, do: 0

  defp do_byte_col_for_grapheme(text, target, byte_pos, count) do
    case String.next_grapheme(text) do
      {_g, rest} ->
        g_size = byte_size(text) - byte_size(rest)
        new_count = count + 1

        if new_count >= target do
          byte_pos + g_size
        else
          do_byte_col_for_grapheme(rest, target, byte_pos + g_size, new_count)
        end

      nil ->
        byte_pos
    end
  end
end
