defmodule Minga.Buffer.UnicodeTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Unicode

  # ── graphemes_with_byte_offsets/1 ─────────────────────────────────────────

  describe "graphemes_with_byte_offsets/1" do
    test "ASCII text has byte offsets equal to grapheme indices" do
      {graphemes, offsets} = Unicode.graphemes_with_byte_offsets("hello")
      assert tuple_size(graphemes) == 5
      assert tuple_size(offsets) == 5

      for i <- 0..4 do
        assert elem(offsets, i) == i
      end
    end

    test "multi-byte characters have increasing byte offsets" do
      # "café" — é is 2 bytes (U+00E9)
      {graphemes, offsets} = Unicode.graphemes_with_byte_offsets("café")
      assert tuple_size(graphemes) == 4
      assert elem(graphemes, 0) == "c"
      assert elem(graphemes, 1) == "a"
      assert elem(graphemes, 2) == "f"
      assert elem(graphemes, 3) == "é"
      assert elem(offsets, 0) == 0
      assert elem(offsets, 1) == 1
      assert elem(offsets, 2) == 2
      assert elem(offsets, 3) == 3
      # "é" is 2 bytes, so total byte_size is 5
      assert byte_size("café") == 5
    end

    test "emoji (4-byte grapheme)" do
      {graphemes, offsets} = Unicode.graphemes_with_byte_offsets("a🥨b")
      assert tuple_size(graphemes) == 3
      assert elem(graphemes, 0) == "a"
      assert elem(graphemes, 1) == "🥨"
      assert elem(graphemes, 2) == "b"
      assert elem(offsets, 0) == 0
      assert elem(offsets, 1) == 1
      assert elem(offsets, 2) == 5
    end

    test "empty string returns empty tuples" do
      {graphemes, offsets} = Unicode.graphemes_with_byte_offsets("")
      assert tuple_size(graphemes) == 0
      assert tuple_size(offsets) == 0
    end

    test "mixed ASCII and multi-byte" do
      # "héllo" — é at index 1 is 2 bytes
      {_graphemes, offsets} = Unicode.graphemes_with_byte_offsets("héllo")
      assert elem(offsets, 0) == 0
      # h is 1 byte
      assert elem(offsets, 1) == 1
      # é is 2 bytes, so next starts at 3
      assert elem(offsets, 2) == 3
      assert elem(offsets, 3) == 4
      assert elem(offsets, 4) == 5
    end
  end

  # ── grapheme_index_to_byte_offset/3 ──────────────────────────────────────

  describe "grapheme_index_to_byte_offset/3" do
    test "ASCII: index equals byte offset" do
      {_, offsets} = Unicode.graphemes_with_byte_offsets("hello")
      assert Unicode.grapheme_index_to_byte_offset(offsets, 0, 5) == 0
      assert Unicode.grapheme_index_to_byte_offset(offsets, 4, 5) == 4
    end

    test "multi-byte: maps grapheme index to correct byte offset" do
      {_, offsets} = Unicode.graphemes_with_byte_offsets("a🥨b")
      assert Unicode.grapheme_index_to_byte_offset(offsets, 0, 6) == 0
      assert Unicode.grapheme_index_to_byte_offset(offsets, 1, 6) == 1
      assert Unicode.grapheme_index_to_byte_offset(offsets, 2, 6) == 5
    end

    test "past-end index clamps to text byte size" do
      {_, offsets} = Unicode.graphemes_with_byte_offsets("abc")
      assert Unicode.grapheme_index_to_byte_offset(offsets, 10, 3) == 3
    end
  end

  # ── byte_offset_to_grapheme_index/2 ──────────────────────────────────────

  describe "byte_offset_to_grapheme_index/2" do
    test "ASCII: byte offset equals grapheme index" do
      {_, offsets} = Unicode.graphemes_with_byte_offsets("hello")
      assert Unicode.byte_offset_to_grapheme_index(offsets, 0) == 0
      assert Unicode.byte_offset_to_grapheme_index(offsets, 4) == 4
    end

    test "multi-byte: maps byte offset to grapheme index" do
      {_, offsets} = Unicode.graphemes_with_byte_offsets("a🥨b")
      assert Unicode.byte_offset_to_grapheme_index(offsets, 0) == 0
      assert Unicode.byte_offset_to_grapheme_index(offsets, 1) == 1
      assert Unicode.byte_offset_to_grapheme_index(offsets, 5) == 2
    end

    test "mid-grapheme byte offset returns the grapheme it falls within" do
      # "a🥨b" — bytes 2,3,4 are inside the emoji (grapheme index 1)
      {_, offsets} = Unicode.graphemes_with_byte_offsets("a🥨b")
      assert Unicode.byte_offset_to_grapheme_index(offsets, 2) == 1
      assert Unicode.byte_offset_to_grapheme_index(offsets, 3) == 1
      assert Unicode.byte_offset_to_grapheme_index(offsets, 4) == 1
    end

    test "past-end byte offset returns last grapheme index" do
      {_, offsets} = Unicode.graphemes_with_byte_offsets("abc")
      assert Unicode.byte_offset_to_grapheme_index(offsets, 99) == 2
    end
  end

  # ── byte_offset_for/3 ────────────────────────────────────────────────────

  describe "byte_offset_for/3" do
    test "single line" do
      assert Unicode.byte_offset_for(["hello"], 0, 3) == 3
    end

    test "multi-line accounts for newline bytes" do
      assert Unicode.byte_offset_for(["hello", "world"], 1, 3) == 9
      # "hello" = 5 bytes + 1 newline = 6, then col 3 = offset 9
    end

    test "first line, first col" do
      assert Unicode.byte_offset_for(["abc", "def"], 0, 0) == 0
    end

    test "multi-byte lines" do
      # "café" is 5 bytes
      assert Unicode.byte_offset_for(["café", "xyz"], 1, 2) == 8
      # 5 + 1 (newline) + 2 = 8
    end
  end

  # ── last_grapheme_byte_offset/1 ──────────────────────────────────────────

  describe "last_grapheme_byte_offset/1" do
    test "empty string returns 0" do
      assert Unicode.last_grapheme_byte_offset("") == 0
    end

    test "single ASCII char returns 0" do
      assert Unicode.last_grapheme_byte_offset("a") == 0
    end

    test "ASCII string returns length - 1" do
      assert Unicode.last_grapheme_byte_offset("hello") == 4
    end

    test "trailing multi-byte char" do
      # "café" — é is 2 bytes (bytes 3-4), last grapheme starts at byte 3
      assert Unicode.last_grapheme_byte_offset("café") == 3
    end

    test "emoji at end" do
      # "hi🥨" — emoji starts at byte 2
      assert Unicode.last_grapheme_byte_offset("hi🥨") == 2
    end

    test "single emoji returns 0" do
      assert Unicode.last_grapheme_byte_offset("🥨") == 0
    end
  end

  # ── prev_grapheme_byte_offset/2 ──────────────────────────────────────────

  describe "prev_grapheme_byte_offset/2" do
    test "at position 0 returns 0" do
      assert Unicode.prev_grapheme_byte_offset("hello", 0) == 0
    end

    test "ASCII: previous is col - 1" do
      assert Unicode.prev_grapheme_byte_offset("hello", 3) == 2
    end

    test "after multi-byte char returns start of that char" do
      # "aé" — é starts at byte 1, is 2 bytes, so byte 3 is past it
      # prev of byte 3 should be byte 1
      assert Unicode.prev_grapheme_byte_offset("aéb", 3) == 1
    end

    test "after emoji returns start of emoji" do
      # "a🥨b" — emoji at byte 1, 4 bytes, b at byte 5
      assert Unicode.prev_grapheme_byte_offset("a🥨b", 5) == 1
    end
  end

  # ── next_grapheme_byte_offset/2 ──────────────────────────────────────────

  describe "next_grapheme_byte_offset/2" do
    test "ASCII: next is col + 1" do
      assert Unicode.next_grapheme_byte_offset("hello", 0) == 1
      assert Unicode.next_grapheme_byte_offset("hello", 3) == 4
    end

    test "on multi-byte char skips past it" do
      # "café" — é at byte 3, 2 bytes wide
      assert Unicode.next_grapheme_byte_offset("café", 3) == 5
    end

    test "on emoji skips 4 bytes" do
      # "a🥨b" — emoji at byte 1, 4 bytes
      assert Unicode.next_grapheme_byte_offset("a🥨b", 1) == 5
    end

    test "at last grapheme returns byte_size" do
      assert Unicode.next_grapheme_byte_offset("abc", 2) == 3
    end
  end

  # ── grapheme_at/2 ────────────────────────────────────────────────────────

  describe "grapheme_at/2" do
    test "ASCII character" do
      assert Unicode.grapheme_at("hello", 0) == "h"
      assert Unicode.grapheme_at("hello", 4) == "o"
    end

    test "multi-byte character" do
      assert Unicode.grapheme_at("café", 3) == "é"
    end

    test "emoji" do
      assert Unicode.grapheme_at("a🥨b", 1) == "🥨"
    end

    test "out of bounds returns nil" do
      assert Unicode.grapheme_at("hello", 5) == nil
      assert Unicode.grapheme_at("hello", 99) == nil
    end

    test "empty string returns nil" do
      assert Unicode.grapheme_at("", 0) == nil
    end
  end

  # ── clamp_to_grapheme_boundary/2 ─────────────────────────────────────────

  describe "clamp_to_grapheme_boundary/2" do
    test "on grapheme boundary returns same offset" do
      assert Unicode.clamp_to_grapheme_boundary("café", 0) == 0
      assert Unicode.clamp_to_grapheme_boundary("café", 3) == 3
    end

    test "mid-grapheme clamps to start of grapheme" do
      # "a🥨b" — bytes 2,3,4 are mid-emoji, should clamp to 1
      assert Unicode.clamp_to_grapheme_boundary("a🥨b", 2) == 1
      assert Unicode.clamp_to_grapheme_boundary("a🥨b", 3) == 1
      assert Unicode.clamp_to_grapheme_boundary("a🥨b", 4) == 1
    end

    test "at byte 0 returns 0" do
      assert Unicode.clamp_to_grapheme_boundary("hello", 0) == 0
    end

    test "past end of 2-byte char clamps correctly" do
      # "aé" — é starts at 1, is 2 bytes. Byte 2 is mid-é? No, byte 2 is past é.
      # Actually é = <<195, 169>>, so byte 1 = start, byte 2 = mid-grapheme
      assert Unicode.clamp_to_grapheme_boundary("aé", 2) == 1
    end
  end

  # ── grapheme_col/2 ───────────────────────────────────────────────────────

  describe "grapheme_col/2" do
    test "ASCII: byte col equals grapheme col" do
      assert Unicode.grapheme_col("hello", 0) == 0
      assert Unicode.grapheme_col("hello", 3) == 3
    end

    test "multi-byte: byte col maps to smaller grapheme col" do
      # "café" — byte 4 is grapheme 3 (é start)
      assert Unicode.grapheme_col("café", 3) == 3
      # Actually wait: c=0, a=1, f=2, é=3 (byte 3). grapheme_col counts graphemes before byte 3.
      # Bytes 0-2 contain c,a,f = 3 graphemes. So grapheme_col("café", 3) = 3. Correct.
    end

    test "after emoji" do
      # "a🥨b" — b is at byte 5, grapheme index 2
      assert Unicode.grapheme_col("a🥨b", 5) == 2
    end

    test "at 0 returns 0" do
      assert Unicode.grapheme_col("anything", 0) == 0
    end
  end

  # ── display_col/2 ───────────────────────────────────────────────────────

  describe "display_col/2" do
    test "ASCII: display col equals byte col equals grapheme col" do
      assert Unicode.display_col("hello", 0) == 0
      assert Unicode.display_col("hello", 3) == 3
      assert Unicode.display_col("hello", 5) == 5
    end

    test "CJK: each character contributes 2 display columns" do
      # "你好世界" — 3 bytes each, 2 display cols each
      assert Unicode.display_col("你好世界", 0) == 0
      assert Unicode.display_col("你好世界", 3) == 2
      assert Unicode.display_col("你好世界", 6) == 4
      assert Unicode.display_col("你好世界", 9) == 6
      assert Unicode.display_col("你好世界", 12) == 8
    end

    test "emoji: 2 display columns" do
      # "🎉" is 4 bytes, 2 display cols
      assert Unicode.display_col("🎉x", 0) == 0
      assert Unicode.display_col("🎉x", 4) == 2
      assert Unicode.display_col("🎉x", 5) == 3
    end

    test "combining mark: 0 additional display columns" do
      # "e\u0301" (é via combining acute) = 3 bytes total, 1 display col
      text = "e\u0301x"
      assert Unicode.display_col(text, 0) == 0
      # After the base grapheme "e\u0301" (3 bytes) → 1 display col
      assert Unicode.display_col(text, 3) == 1
      # After "x" (1 byte) → 2 display cols
      assert Unicode.display_col(text, 4) == 2
    end

    test "mixed ASCII and CJK" do
      # "hi你" — h(1 byte/1 col), i(1 byte/1 col), 你(3 bytes/2 cols)
      assert Unicode.display_col("hi你", 0) == 0
      assert Unicode.display_col("hi你", 1) == 1
      assert Unicode.display_col("hi你", 2) == 2
      assert Unicode.display_col("hi你", 5) == 4
    end

    test "at 0 always returns 0" do
      assert Unicode.display_col("anything", 0) == 0
      assert Unicode.display_col("你好", 0) == 0
    end

    test "pure ASCII: display_col matches grapheme_col for all positions" do
      text = "hello world"

      for byte_col <- 0..byte_size(text) do
        assert Unicode.display_col(text, byte_col) == Unicode.grapheme_col(text, byte_col),
               "Mismatch at byte_col=#{byte_col}"
      end
    end
  end

  # ── byte_col_for_grapheme/2 ──────────────────────────────────────────────

  describe "byte_col_for_grapheme/2" do
    test "ASCII: grapheme col equals byte col" do
      assert Unicode.byte_col_for_grapheme("hello", 0) == 0
      assert Unicode.byte_col_for_grapheme("hello", 3) == 3
    end

    test "multi-byte: grapheme col maps to larger byte col" do
      # "a🥨b" — grapheme 2 (b) is at byte 5
      assert Unicode.byte_col_for_grapheme("a🥨b", 2) == 5
    end

    test "at 0 returns 0" do
      assert Unicode.byte_col_for_grapheme("anything", 0) == 0
    end
  end

  # ── Round-trip consistency ───────────────────────────────────────────────

  describe "round-trip consistency" do
    test "grapheme_index → byte_offset → grapheme_index" do
      text = "héllo🥨wörld"
      {_, offsets} = Unicode.graphemes_with_byte_offsets(text)

      for i <- 0..(tuple_size(offsets) - 1) do
        byte_off = Unicode.grapheme_index_to_byte_offset(offsets, i, byte_size(text))
        assert Unicode.byte_offset_to_grapheme_index(offsets, byte_off) == i
      end
    end

    test "grapheme_col and byte_col_for_grapheme are inverses" do
      text = "a🥨café🎉x"

      # Walk each grapheme and verify round-trip
      {graphemes, offsets} = Unicode.graphemes_with_byte_offsets(text)

      for i <- 0..(tuple_size(graphemes) - 1) do
        byte_col = elem(offsets, i)
        g_col = Unicode.grapheme_col(text, byte_col)

        assert Unicode.byte_col_for_grapheme(text, g_col) == byte_col,
               "round-trip failed for grapheme #{i} (#{elem(graphemes, i)}): " <>
                 "byte_col=#{byte_col} → g_col=#{g_col} → byte=#{Unicode.byte_col_for_grapheme(text, g_col)}"
      end
    end

    test "prev and next are inverses for all grapheme boundaries" do
      text = "a🥨é"
      {_, offsets} = Unicode.graphemes_with_byte_offsets(text)

      # For each grapheme after the first, prev(next_start) should give current start
      for i <- 1..(tuple_size(offsets) - 1) do
        current = elem(offsets, i)
        prev = Unicode.prev_grapheme_byte_offset(text, current)
        assert prev == elem(offsets, i - 1)
      end

      # For each grapheme before the last, next(current) should give next start
      for i <- 0..(tuple_size(offsets) - 2) do
        current = elem(offsets, i)
        next = Unicode.next_grapheme_byte_offset(text, current)
        assert next == elem(offsets, i + 1)
      end
    end
  end
end
