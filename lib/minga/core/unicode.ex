defmodule Minga.Core.Unicode do
  @moduledoc """
  Byte ↔ grapheme conversion utilities for UTF-8 text.

  Pure string functions for converting between byte offsets and grapheme
  indices, computing display widths, and navigating grapheme boundaries.
  Used by the buffer, editing, and rendering domains.
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

      iex> {gs, os} = Minga.Core.Unicode.graphemes_with_byte_offsets("café")
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

      iex> {_, os} = Minga.Core.Unicode.graphemes_with_byte_offsets("café")
      iex> Minga.Core.Unicode.grapheme_index_to_byte_offset(os, 3, 5)
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

      iex> {_, os} = Minga.Core.Unicode.graphemes_with_byte_offsets("café")
      iex> Minga.Core.Unicode.byte_offset_to_grapheme_index(os, 4)
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

      iex> Minga.Core.Unicode.byte_offset_for(["hello", "world"], 1, 3)
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

      iex> Minga.Core.Unicode.last_grapheme_byte_offset("café")
      4

      iex> Minga.Core.Unicode.last_grapheme_byte_offset("")
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

      iex> Minga.Core.Unicode.prev_grapheme_byte_offset("café", 4)
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

      iex> Minga.Core.Unicode.next_grapheme_byte_offset("café", 3)
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

      iex> Minga.Core.Unicode.grapheme_at("café", 3)
      "é"

      iex> Minga.Core.Unicode.grapheme_at("café", 10)
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

      iex> Minga.Core.Unicode.clamp_to_grapheme_boundary("café", 4)
      4

      iex> Minga.Core.Unicode.clamp_to_grapheme_boundary("café", 5)
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

      iex> Minga.Core.Unicode.grapheme_col("café", 4)
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
  Converts a byte column to a display column by summing grapheme display
  widths for the first `byte_col` bytes of `text`.

  Unlike `grapheme_col/2`, which counts graphemes (each +1), this function
  accounts for wide characters (CJK, emoji: +2) and zero-width characters
  (combining marks: +0). Use this at the rendering boundary wherever a
  screen column position is needed.

  ## Examples

      iex> Minga.Core.Unicode.display_col("hello", 3)
      3

      iex> Minga.Core.Unicode.display_col("你好世界", 6)
      4

      iex> Minga.Core.Unicode.display_col("café", 4)
      3
  """
  @spec display_col(String.t(), non_neg_integer()) :: non_neg_integer()
  def display_col(_text, 0), do: 0

  def display_col(text, byte_col) do
    do_display_col(text, byte_col, 0, 0)
  end

  @spec do_display_col(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_display_col(_text, target, current, width) when current >= target, do: width

  defp do_display_col(text, target, current, width) do
    case String.next_grapheme(text) do
      {g, rest} ->
        g_size = byte_size(text) - byte_size(rest)
        do_display_col(rest, target, current + g_size, width + grapheme_width(g))

      nil ->
        width
    end
  end

  @doc """
  Returns the display width (terminal columns) of a string.

  Most graphemes are 1 column wide. CJK characters and some emoji are 2
  columns. Combining marks and zero-width characters are 0 columns.

  Uses Unicode East Asian Width + emoji detection for correctness.

  ## Examples

      iex> Minga.Core.Unicode.display_width("hello")
      5

      iex> Minga.Core.Unicode.display_width("café")
      4

      iex> Minga.Core.Unicode.display_width("你好")
      4

      iex> Minga.Core.Unicode.display_width("")
      0
  """
  @spec display_width(String.t()) :: non_neg_integer()
  def display_width(text) when is_binary(text) do
    do_display_width(text, 0)
  end

  @spec do_display_width(String.t(), non_neg_integer()) :: non_neg_integer()
  defp do_display_width("", acc), do: acc

  defp do_display_width(text, acc) do
    case String.next_grapheme(text) do
      {g, rest} -> do_display_width(rest, acc + grapheme_width(g))
      nil -> acc
    end
  end

  @doc """
  Converts a display column (terminal columns) to a byte offset.

  Walks graphemes from the start of `text`, accumulating display width,
  until the target display column is reached or exceeded. Returns the
  byte offset of the grapheme at that display column.

  ## Examples

      iex> Minga.Core.Unicode.display_col_to_byte("hello", 3)
      3

      iex> Minga.Core.Unicode.display_col_to_byte("你好世界", 2)
      3
  """
  @spec display_col_to_byte(String.t(), non_neg_integer()) :: non_neg_integer()
  def display_col_to_byte(_text, 0), do: 0

  def display_col_to_byte(text, target_col) when is_binary(text) and target_col > 0 do
    do_display_col_to_byte(text, target_col, 0, 0)
  end

  @spec do_display_col_to_byte(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          non_neg_integer()
  defp do_display_col_to_byte("", _target, _col, bytes), do: bytes

  defp do_display_col_to_byte(text, target, col, bytes) do
    case String.next_grapheme(text) do
      {g, rest} ->
        w = grapheme_width(g)
        new_col = col + w

        if new_col >= target do
          bytes
        else
          do_display_col_to_byte(rest, target, new_col, bytes + byte_size(g))
        end

      nil ->
        bytes
    end
  end

  @doc """
  Returns the display width (terminal columns) of a single grapheme.

  ## Examples

      iex> Minga.Core.Unicode.grapheme_width("a")
      1

      iex> Minga.Core.Unicode.grapheme_width("你")
      2
  """
  @spec grapheme_width(String.t()) :: non_neg_integer()
  def grapheme_width(grapheme) when is_binary(grapheme) do
    case grapheme do
      "" ->
        0

      <<cp::utf8, _rest::binary>> ->
        codepoint_width(cp)

      # Partial or invalid UTF-8 byte sequence (e.g. <<226>> from a truncated
      # multi-byte character). Treat each raw byte as 1 column wide so the
      # renderer doesn't crash.
      _invalid ->
        byte_size(grapheme)
    end
  end

  # Width of a codepoint based on Unicode East Asian Width property.
  # Wide (W) and Fullwidth (F) characters are 2 columns.
  # Combining marks and zero-width characters are 0 columns.
  @spec codepoint_width(non_neg_integer()) :: non_neg_integer()
  defp codepoint_width(cp) when cp <= 0x001F, do: 0
  defp codepoint_width(0x007F), do: 0
  # Combining Diacritical Marks
  defp codepoint_width(cp) when cp in 0x0300..0x036F, do: 0
  # General combining marks
  defp codepoint_width(cp) when cp in 0x1AB0..0x1AFF, do: 0
  defp codepoint_width(cp) when cp in 0x1DC0..0x1DFF, do: 0
  defp codepoint_width(cp) when cp in 0x20D0..0x20FF, do: 0
  defp codepoint_width(cp) when cp in 0xFE20..0xFE2F, do: 0
  # Zero-width characters
  defp codepoint_width(0x200B), do: 0
  defp codepoint_width(0x200C), do: 0
  defp codepoint_width(0x200D), do: 0
  defp codepoint_width(0xFEFF), do: 0
  # Variation selectors
  defp codepoint_width(cp) when cp in 0xFE00..0xFE0F, do: 0
  defp codepoint_width(cp) when cp in 0xE0100..0xE01EF, do: 0
  # CJK Unified Ideographs and extensions
  defp codepoint_width(cp) when cp in 0x4E00..0x9FFF, do: 2
  defp codepoint_width(cp) when cp in 0x3400..0x4DBF, do: 2
  defp codepoint_width(cp) when cp in 0x20000..0x2A6DF, do: 2
  defp codepoint_width(cp) when cp in 0x2A700..0x2B73F, do: 2
  defp codepoint_width(cp) when cp in 0x2B740..0x2B81F, do: 2
  defp codepoint_width(cp) when cp in 0x2B820..0x2CEAF, do: 2
  defp codepoint_width(cp) when cp in 0x2CEB0..0x2EBEF, do: 2
  defp codepoint_width(cp) when cp in 0x30000..0x3134F, do: 2
  # CJK Compatibility Ideographs
  defp codepoint_width(cp) when cp in 0xF900..0xFAFF, do: 2
  defp codepoint_width(cp) when cp in 0x2F800..0x2FA1F, do: 2
  # Hangul Syllables
  defp codepoint_width(cp) when cp in 0xAC00..0xD7AF, do: 2
  # CJK Radicals, Kangxi, Description
  defp codepoint_width(cp) when cp in 0x2E80..0x2FFF, do: 2
  # CJK Symbols and Punctuation, Hiragana, Katakana, Bopomofo, etc.
  defp codepoint_width(cp) when cp in 0x3000..0x33FF, do: 2
  defp codepoint_width(cp) when cp in 0xFE30..0xFE6F, do: 2
  # Fullwidth Forms
  defp codepoint_width(cp) when cp in 0xFF01..0xFF60, do: 2
  defp codepoint_width(cp) when cp in 0xFFE0..0xFFE6, do: 2
  # Emoji modifiers and regional indicators (typically rendered wide)
  defp codepoint_width(cp) when cp in 0x1F1E0..0x1F1FF, do: 2
  defp codepoint_width(cp) when cp in 0x1F300..0x1F9FF, do: 2
  defp codepoint_width(cp) when cp in 0x1FA00..0x1FA6F, do: 2
  defp codepoint_width(cp) when cp in 0x1FA70..0x1FAFF, do: 2
  # Halfwidth Katakana (1 column, despite being in CJK block)
  defp codepoint_width(cp) when cp in 0xFF61..0xFFDC, do: 1
  defp codepoint_width(cp) when cp in 0xFFE8..0xFFEE, do: 1
  # Everything else is 1 column
  defp codepoint_width(_), do: 1

  @doc """
  Converts a grapheme (display) column to a byte column.

  ## Examples

      iex> Minga.Core.Unicode.byte_col_for_grapheme("café", 3)
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
