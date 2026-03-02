defmodule Minga.Buffer.GapBufferTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.GapBuffer

  # ── Construction ──

  describe "new/1" do
    test "creates an empty buffer" do
      buf = GapBuffer.new()
      assert GapBuffer.content(buf) == ""
      assert GapBuffer.cursor(buf) == {0, 0}
    end

    test "creates a buffer from a string" do
      buf = GapBuffer.new("hello")
      assert GapBuffer.content(buf) == "hello"
      assert GapBuffer.cursor(buf) == {0, 0}
    end

    test "creates a buffer from a multi-line string" do
      buf = GapBuffer.new("hello\nworld\n!")
      assert GapBuffer.content(buf) == "hello\nworld\n!"
      assert GapBuffer.cursor(buf) == {0, 0}
    end
  end

  # ── Queries ──

  describe "empty?/1" do
    test "returns true for empty buffer" do
      assert GapBuffer.empty?(GapBuffer.new())
    end

    test "returns false for non-empty buffer" do
      refute GapBuffer.empty?(GapBuffer.new("x"))
    end
  end

  describe "line_count/1" do
    test "empty buffer has 1 line" do
      assert GapBuffer.line_count(GapBuffer.new()) == 1
    end

    test "single line without newline" do
      assert GapBuffer.line_count(GapBuffer.new("hello")) == 1
    end

    test "counts lines separated by newlines" do
      assert GapBuffer.line_count(GapBuffer.new("a\nb\nc")) == 3
    end

    test "trailing newline adds an empty line" do
      assert GapBuffer.line_count(GapBuffer.new("a\nb\n")) == 3
    end
  end

  describe "line_at/2" do
    test "returns the first line" do
      buf = GapBuffer.new("hello\nworld")
      assert GapBuffer.line_at(buf, 0) == "hello"
    end

    test "returns the second line" do
      buf = GapBuffer.new("hello\nworld")
      assert GapBuffer.line_at(buf, 1) == "world"
    end

    test "returns nil for out-of-range line" do
      buf = GapBuffer.new("hello")
      assert GapBuffer.line_at(buf, 5) == nil
    end

    test "returns empty string for empty line" do
      buf = GapBuffer.new("hello\n\nworld")
      assert GapBuffer.line_at(buf, 1) == ""
    end
  end

  describe "lines/3" do
    test "returns a range of lines" do
      buf = GapBuffer.new("a\nb\nc\nd\ne")
      assert GapBuffer.lines(buf, 1, 3) == ["b", "c", "d"]
    end

    test "returns empty list when start is past end" do
      buf = GapBuffer.new("a\nb")
      assert GapBuffer.lines(buf, 10, 5) == []
    end

    test "returns fewer lines when count exceeds available" do
      buf = GapBuffer.new("a\nb\nc")
      assert GapBuffer.lines(buf, 1, 10) == ["b", "c"]
    end
  end

  describe "cursor/1" do
    test "starts at {0, 0} for new buffer" do
      assert GapBuffer.cursor(GapBuffer.new("hello")) == {0, 0}
    end

    test "reflects position after moving right (ASCII)" do
      buf = GapBuffer.new("hello") |> GapBuffer.move(:right) |> GapBuffer.move(:right)
      assert GapBuffer.cursor(buf) == {0, 2}
    end

    test "reflects position on second line" do
      buf = GapBuffer.new("ab\ncd") |> GapBuffer.move_to({1, 1})
      assert GapBuffer.cursor(buf) == {1, 1}
    end
  end

  # ── Insertion ──

  describe "insert_char/2" do
    test "inserts at the beginning of a buffer" do
      buf = GapBuffer.new("hello") |> GapBuffer.insert_char("X")
      assert GapBuffer.content(buf) == "Xhello"
      assert GapBuffer.cursor(buf) == {0, 1}
    end

    test "inserts in the middle after moving" do
      buf =
        GapBuffer.new("hello")
        |> GapBuffer.move(:right)
        |> GapBuffer.move(:right)
        |> GapBuffer.insert_char("X")

      assert GapBuffer.content(buf) == "heXllo"
      assert GapBuffer.cursor(buf) == {0, 3}
    end

    test "inserts at the end" do
      buf = GapBuffer.new("hi") |> GapBuffer.move_to({0, 2}) |> GapBuffer.insert_char("!")
      assert GapBuffer.content(buf) == "hi!"
    end

    test "inserts a newline" do
      buf = GapBuffer.new("ab") |> GapBuffer.move(:right) |> GapBuffer.insert_char("\n")
      assert GapBuffer.content(buf) == "a\nb"
      assert GapBuffer.cursor(buf) == {1, 0}
    end

    test "inserts unicode emoji — byte_col reflects byte size" do
      buf = GapBuffer.new("hi") |> GapBuffer.insert_char("🥨")
      assert GapBuffer.content(buf) == "🥨hi"
      # 🥨 is 4 bytes
      assert GapBuffer.cursor(buf) == {0, 4}
    end

    test "inserts multi-byte CJK character" do
      buf = GapBuffer.new("hi") |> GapBuffer.insert_char("日")
      assert GapBuffer.content(buf) == "日hi"
      # 日 is 3 bytes
      assert GapBuffer.cursor(buf) == {0, 3}
    end

    test "inserts into empty buffer" do
      buf = GapBuffer.new() |> GapBuffer.insert_char("a")
      assert GapBuffer.content(buf) == "a"
      assert GapBuffer.cursor(buf) == {0, 1}
    end
  end

  # ── Deletion ──

  describe "delete_before/1" do
    test "deletes the character before the cursor" do
      buf =
        GapBuffer.new("hello")
        |> GapBuffer.move(:right)
        |> GapBuffer.move(:right)
        |> GapBuffer.delete_before()

      assert GapBuffer.content(buf) == "hllo"
      assert GapBuffer.cursor(buf) == {0, 1}
    end

    test "does nothing at the start of the buffer" do
      buf = GapBuffer.new("hello") |> GapBuffer.delete_before()
      assert GapBuffer.content(buf) == "hello"
      assert GapBuffer.cursor(buf) == {0, 0}
    end

    test "deleting newline joins lines" do
      buf = GapBuffer.new("ab\ncd") |> GapBuffer.move_to({1, 0}) |> GapBuffer.delete_before()
      assert GapBuffer.content(buf) == "abcd"
      assert GapBuffer.cursor(buf) == {0, 2}
    end

    test "deletes unicode character" do
      buf =
        GapBuffer.new("🥨hi")
        |> GapBuffer.move(:right)
        |> GapBuffer.delete_before()

      assert GapBuffer.content(buf) == "hi"
    end

    test "does nothing on empty buffer" do
      buf = GapBuffer.new() |> GapBuffer.delete_before()
      assert GapBuffer.content(buf) == ""
      assert GapBuffer.empty?(buf)
    end
  end

  describe "delete_at/1" do
    test "deletes the character at the cursor" do
      buf = GapBuffer.new("hello") |> GapBuffer.delete_at()
      assert GapBuffer.content(buf) == "ello"
      assert GapBuffer.cursor(buf) == {0, 0}
    end

    test "does nothing at the end of the buffer" do
      buf = GapBuffer.new("hi") |> GapBuffer.move_to({0, 2}) |> GapBuffer.delete_at()
      assert GapBuffer.content(buf) == "hi"
    end

    test "deletes newline at cursor joins lines" do
      buf = GapBuffer.new("ab\ncd") |> GapBuffer.move_to({0, 2}) |> GapBuffer.delete_at()
      assert GapBuffer.content(buf) == "abcd"
      assert GapBuffer.cursor(buf) == {0, 2}
    end

    test "deletes unicode character at cursor" do
      buf = GapBuffer.new("🥨hi") |> GapBuffer.delete_at()
      assert GapBuffer.content(buf) == "hi"
    end
  end

  # ── Movement ──

  describe "move/2 :left" do
    test "moves cursor left" do
      buf = GapBuffer.new("hello") |> GapBuffer.move_to({0, 3}) |> GapBuffer.move(:left)
      assert GapBuffer.cursor(buf) == {0, 2}
    end

    test "stays at start when already at {0, 0}" do
      buf = GapBuffer.new("hello") |> GapBuffer.move(:left)
      assert GapBuffer.cursor(buf) == {0, 0}
    end

    test "wraps to end of previous line" do
      buf = GapBuffer.new("ab\ncd") |> GapBuffer.move_to({1, 0}) |> GapBuffer.move(:left)
      assert GapBuffer.cursor(buf) == {0, 2}
    end
  end

  describe "move/2 :right" do
    test "moves cursor right" do
      buf = GapBuffer.new("hello") |> GapBuffer.move(:right)
      assert GapBuffer.cursor(buf) == {0, 1}
    end

    test "stays at end when already at the end" do
      buf = GapBuffer.new("hi") |> GapBuffer.move_to({0, 2}) |> GapBuffer.move(:right)
      assert GapBuffer.cursor(buf) == {0, 2}
    end

    test "wraps to start of next line" do
      buf = GapBuffer.new("ab\ncd") |> GapBuffer.move_to({0, 2}) |> GapBuffer.move(:right)
      assert GapBuffer.cursor(buf) == {1, 0}
    end

    test "moves by byte size for multi-byte characters" do
      buf = GapBuffer.new("🥨ab") |> GapBuffer.move(:right)
      # 🥨 is 4 bytes
      assert GapBuffer.cursor(buf) == {0, 4}
    end
  end

  describe "move/2 :up" do
    test "moves cursor to the same column on previous line" do
      buf = GapBuffer.new("hello\nworld") |> GapBuffer.move_to({1, 3}) |> GapBuffer.move(:up)
      assert GapBuffer.cursor(buf) == {0, 3}
    end

    test "clamps column when previous line is shorter" do
      buf = GapBuffer.new("hi\nworld") |> GapBuffer.move_to({1, 4}) |> GapBuffer.move(:up)
      assert GapBuffer.cursor(buf) == {0, 2}
    end

    test "stays on first line when already on line 0" do
      buf = GapBuffer.new("hello\nworld") |> GapBuffer.move(:up)
      assert GapBuffer.cursor(buf) == {0, 0}
    end
  end

  describe "move/2 :down" do
    test "moves cursor to the same column on next line" do
      buf = GapBuffer.new("hello\nworld") |> GapBuffer.move_to({0, 3}) |> GapBuffer.move(:down)
      assert GapBuffer.cursor(buf) == {1, 3}
    end

    test "clamps column when next line is shorter" do
      buf = GapBuffer.new("hello\nhi") |> GapBuffer.move_to({0, 4}) |> GapBuffer.move(:down)
      assert GapBuffer.cursor(buf) == {1, 2}
    end

    test "stays on last line when already on the last line" do
      buf = GapBuffer.new("hello\nworld") |> GapBuffer.move_to({1, 0}) |> GapBuffer.move(:down)
      assert GapBuffer.cursor(buf) == {1, 0}
    end
  end

  describe "move_to/2" do
    test "moves to exact position" do
      buf = GapBuffer.new("abc\ndef\nghi") |> GapBuffer.move_to({2, 1})
      assert GapBuffer.cursor(buf) == {2, 1}
    end

    test "clamps line to last line" do
      buf = GapBuffer.new("abc\ndef") |> GapBuffer.move_to({99, 0})
      assert GapBuffer.cursor(buf) == {1, 0}
    end

    test "clamps column to end of line (byte size)" do
      buf = GapBuffer.new("abc\ndef") |> GapBuffer.move_to({0, 99})
      assert GapBuffer.cursor(buf) == {0, 3}
    end

    test "preserves buffer content after move" do
      text = "hello\nworld"
      buf = GapBuffer.new(text) |> GapBuffer.move_to({1, 3})
      assert GapBuffer.content(buf) == text
    end

    test "clamps to grapheme boundary for multi-byte chars" do
      # "café" — é is 2 bytes (0xC3 0xA9), byte_size is 5
      buf = GapBuffer.new("café") |> GapBuffer.move_to({0, 4})
      # byte 4 is in the middle of é (which starts at byte 3)
      # Should clamp to byte 3 (start of é)
      assert GapBuffer.cursor(buf) == {0, 3}
    end
  end

  # ── Grapheme/byte conversion ──

  describe "grapheme_col/2" do
    test "ASCII: byte col equals grapheme col" do
      buf = GapBuffer.new("hello")
      assert GapBuffer.grapheme_col(buf, {0, 3}) == 3
    end

    test "multi-byte: byte col larger than grapheme col" do
      # "café" — é is 2 bytes
      buf = GapBuffer.new("café")
      # byte_col 3 = start of é = grapheme col 3
      assert GapBuffer.grapheme_col(buf, {0, 3}) == 3
      # byte_col 5 (end) = 4 graphemes
      assert GapBuffer.grapheme_col(buf, {0, 5}) == 4
    end

    test "emoji: 4-byte char" do
      buf = GapBuffer.new("🥨ab")
      # byte 0 = grapheme 0
      assert GapBuffer.grapheme_col(buf, {0, 0}) == 0
      # byte 4 = past emoji = grapheme 1
      assert GapBuffer.grapheme_col(buf, {0, 4}) == 1
      # byte 5 = grapheme 2
      assert GapBuffer.grapheme_col(buf, {0, 5}) == 2
    end
  end

  describe "byte_col_for_grapheme/2" do
    test "ASCII: grapheme index equals byte offset" do
      assert GapBuffer.byte_col_for_grapheme("hello", 3) == 3
    end

    test "multi-byte: grapheme 4 of café is byte 5" do
      assert GapBuffer.byte_col_for_grapheme("café", 4) == 5
    end

    test "emoji: grapheme 1 of 🥨ab is byte 4" do
      assert GapBuffer.byte_col_for_grapheme("🥨ab", 1) == 4
    end
  end

  describe "last_grapheme_byte_offset/1" do
    test "empty string returns 0" do
      assert GapBuffer.last_grapheme_byte_offset("") == 0
    end

    test "ASCII string" do
      assert GapBuffer.last_grapheme_byte_offset("hello") == 4
    end

    test "multi-byte last char" do
      # "café" — é starts at byte 3
      assert GapBuffer.last_grapheme_byte_offset("café") == 3
    end

    test "emoji last char" do
      # "hi🥨" — 🥨 starts at byte 2
      assert GapBuffer.last_grapheme_byte_offset("hi🥨") == 2
    end
  end

  # ── Round-trip integrity ──

  describe "content integrity" do
    test "insert then delete_before restores original" do
      buf = GapBuffer.new("hello")
      original = GapBuffer.content(buf)

      buf =
        buf |> GapBuffer.move(:right) |> GapBuffer.insert_char("X") |> GapBuffer.delete_before()

      assert GapBuffer.content(buf) == original
    end

    test "moving around does not change content" do
      text = "hello\nworld\nfoo"
      buf = GapBuffer.new(text)

      buf =
        buf
        |> GapBuffer.move(:right)
        |> GapBuffer.move(:down)
        |> GapBuffer.move(:left)
        |> GapBuffer.move(:up)
        |> GapBuffer.move_to({2, 1})
        |> GapBuffer.move_to({0, 0})

      assert GapBuffer.content(buf) == text
    end

    test "multiple insertions and deletions" do
      buf =
        GapBuffer.new()
        |> GapBuffer.insert_char("a")
        |> GapBuffer.insert_char("b")
        |> GapBuffer.insert_char("c")
        |> GapBuffer.delete_before()
        |> GapBuffer.insert_char("C")

      assert GapBuffer.content(buf) == "abC"
    end
  end

  # ── Unicode edge cases ──

  describe "unicode handling" do
    test "handles combining characters" do
      # é as e + combining acute accent
      text = "cafe\u0301"
      buf = GapBuffer.new(text)
      assert GapBuffer.line_count(buf) == 1
      assert GapBuffer.content(buf) == text
    end

    test "handles emoji sequences" do
      buf = GapBuffer.new("🇩🇪") |> GapBuffer.insert_char("!")
      assert GapBuffer.content(buf) == "!🇩🇪"
    end

    test "cursor position uses byte offsets" do
      buf = GapBuffer.new("🥨ab") |> GapBuffer.move(:right)
      # 🥨 is 4 bytes, so cursor_col = 4
      assert GapBuffer.cursor(buf) == {0, 4}
      # But grapheme_col is 1
      assert GapBuffer.grapheme_col(buf, GapBuffer.cursor(buf)) == 1
    end
  end

  # ── Property-based tests ──

  describe "property: insert/delete round-trip" do
    property "inserting then deleting before restores the buffer" do
      check all(
              text <- string(:ascii, min_length: 0, max_length: 100),
              char <- string(:ascii, length: 1),
              pos <- integer(0..max(byte_size("") + 100, 1))
            ) do
        buf = GapBuffer.new(text)
        clamped_pos = min(pos, byte_size(text))
        line_col = byte_offset_to_position(text, clamped_pos)

        buf =
          buf
          |> GapBuffer.move_to(line_col)
          |> GapBuffer.insert_char(char)
          |> GapBuffer.delete_before()

        assert GapBuffer.content(buf) == text
      end
    end

    property "moving does not alter content" do
      check all(
              text <- string(:printable, min_length: 1, max_length: 200),
              moves <-
                list_of(member_of([:left, :right, :up, :down]), min_length: 1, max_length: 20)
            ) do
        buf = GapBuffer.new(text)

        result =
          Enum.reduce(moves, buf, fn dir, acc ->
            GapBuffer.move(acc, dir)
          end)

        assert GapBuffer.content(result) == text
      end
    end

    property "cursor is always within valid bounds" do
      check all(
              text <- string(:printable, min_length: 0, max_length: 200),
              moves <-
                list_of(member_of([:left, :right, :up, :down]), min_length: 0, max_length: 30)
            ) do
        buf = GapBuffer.new(text)

        buf =
          Enum.reduce(moves, buf, fn dir, acc ->
            GapBuffer.move(acc, dir)
          end)

        {line, byte_col} = GapBuffer.cursor(buf)
        max_line = GapBuffer.line_count(buf) - 1
        assert line >= 0 and line <= max_line

        current_line = GapBuffer.line_at(buf, line)
        max_col = byte_size(current_line)
        assert byte_col >= 0 and byte_col <= max_col
      end
    end
  end

  # ── Cache validity tests ──

  describe "cache: cursor and line_count accuracy" do
    test "insert at start of line updates col" do
      buf = GapBuffer.new("hello") |> GapBuffer.insert_char("X")
      assert_cache_valid(buf)
      assert GapBuffer.cursor(buf) == {0, 1}
    end

    test "insert in middle of line updates col" do
      buf =
        GapBuffer.new("hello")
        |> GapBuffer.move_to({0, 2})
        |> GapBuffer.insert_char("X")

      assert_cache_valid(buf)
      assert GapBuffer.cursor(buf) == {0, 3}
    end

    test "insert at end of line updates col" do
      buf =
        GapBuffer.new("hello")
        |> GapBuffer.move_to({0, 5})
        |> GapBuffer.insert_char("X")

      assert_cache_valid(buf)
      assert GapBuffer.cursor(buf) == {0, 6}
    end

    test "inserting a newline increments line and resets col" do
      buf = GapBuffer.new("ab") |> GapBuffer.move(:right) |> GapBuffer.insert_char("\n")
      assert_cache_valid(buf)
      assert GapBuffer.cursor(buf) == {1, 0}
      assert GapBuffer.line_count(buf) == 2
    end

    test "inserting multi-line string updates cursor and line_count" do
      buf =
        GapBuffer.new("start") |> GapBuffer.move_to({0, 5}) |> GapBuffer.insert_char("a\nb\nc")

      assert_cache_valid(buf)
      assert GapBuffer.cursor(buf) == {2, 1}
      assert GapBuffer.line_count(buf) == 3
    end

    test "delete_before at start of line joins lines, updates cursor and line_count" do
      buf = GapBuffer.new("ab\ncd") |> GapBuffer.move_to({1, 0}) |> GapBuffer.delete_before()
      assert_cache_valid(buf)
      assert GapBuffer.cursor(buf) == {0, 2}
      assert GapBuffer.line_count(buf) == 1
    end

    test "delete_before in middle of line decrements col" do
      buf = GapBuffer.new("hello") |> GapBuffer.move_to({0, 3}) |> GapBuffer.delete_before()
      assert_cache_valid(buf)
      assert GapBuffer.cursor(buf) == {0, 2}
    end

    test "delete_at on newline decrements line_count, cursor unchanged" do
      buf = GapBuffer.new("ab\ncd") |> GapBuffer.move_to({0, 2}) |> GapBuffer.delete_at()
      assert_cache_valid(buf)
      assert GapBuffer.cursor(buf) == {0, 2}
      assert GapBuffer.line_count(buf) == 1
    end

    test "delete_at on regular char, cursor and line_count unchanged" do
      buf = GapBuffer.new("hello") |> GapBuffer.delete_at()
      assert_cache_valid(buf)
      assert GapBuffer.cursor(buf) == {0, 0}
      assert GapBuffer.line_count(buf) == 1
    end

    test "move_to arbitrary position updates cache" do
      buf = GapBuffer.new("abc\ndef\nghi") |> GapBuffer.move_to({2, 1})
      assert_cache_valid(buf)
      assert GapBuffer.cursor(buf) == {2, 1}
    end

    test "move_left across newline updates line and col" do
      buf = GapBuffer.new("ab\ncd") |> GapBuffer.move_to({1, 0}) |> GapBuffer.move(:left)
      assert_cache_valid(buf)
      assert GapBuffer.cursor(buf) == {0, 2}
    end

    test "move_right across newline updates line and resets col" do
      buf = GapBuffer.new("ab\ncd") |> GapBuffer.move_to({0, 2}) |> GapBuffer.move(:right)
      assert_cache_valid(buf)
      assert GapBuffer.cursor(buf) == {1, 0}
    end

    test "delete_range spanning multiple lines rebuilds cache correctly" do
      buf = GapBuffer.new("abc\ndef\nghi") |> GapBuffer.delete_range({0, 1}, {1, 1})
      assert_cache_valid(buf)
    end

    test "delete_lines rebuilds cache correctly" do
      buf = GapBuffer.new("a\nb\nc\nd") |> GapBuffer.delete_lines(1, 2)
      assert_cache_valid(buf)
      assert GapBuffer.line_count(buf) == 2
    end
  end

  # ── Property: cache always matches recomputed values ──

  describe "property: cache consistency" do
    property "cached cursor and line_count match recomputed values after any operations" do
      check all(
              text <- string(:ascii, min_length: 0, max_length: 80),
              ops <-
                list_of(
                  one_of([
                    member_of([:left, :right, :up, :down, :delete_before, :delete_at]),
                    {:insert, string(:ascii, length: 1)},
                    {:move_to, integer(0..5), integer(0..20)}
                  ]),
                  min_length: 0,
                  max_length: 20
                )
            ) do
        buf = GapBuffer.new(text)

        result =
          Enum.reduce(ops, buf, fn
            {:insert, char}, acc -> GapBuffer.insert_char(acc, char)
            {:move_to, l, c}, acc -> GapBuffer.move_to(acc, {l, c})
            :delete_before, acc -> GapBuffer.delete_before(acc)
            :delete_at, acc -> GapBuffer.delete_at(acc)
            dir, acc -> GapBuffer.move(acc, dir)
          end)

        assert_cache_valid(result)
      end
    end
  end

  # ── Test helpers ──

  # Verifies that the cached cursor_line, cursor_col, and line_count fields
  # match values recomputed from the raw buffer content.
  # cursor_col is now a byte offset within the current line.
  @spec assert_cache_valid(GapBuffer.t()) :: :ok
  defp assert_cache_valid(%GapBuffer{
         before: before,
         after: after_,
         cursor_line: cl,
         cursor_col: cc,
         line_count: lc
       }) do
    # Recompute cursor from `before`
    lines_before = :binary.split(before, "\n", [:global])
    expected_line = length(lines_before) - 1
    expected_col = lines_before |> List.last() |> byte_size()

    # Recompute line_count from full content
    text = before <> after_

    expected_lc =
      case text do
        "" -> 1
        _ -> length(:binary.matches(text, "\n")) + 1
      end

    assert cl == expected_line,
           "cursor_line: got #{cl}, expected #{expected_line} (before=#{inspect(before)})"

    assert cc == expected_col,
           "cursor_col: got #{cc}, expected #{expected_col} (before=#{inspect(before)})"

    assert lc == expected_lc,
           "line_count: got #{lc}, expected #{expected_lc} (content=#{inspect(text)})"

    :ok
  end

  # Convert a byte offset in text to a {line, byte_col} position.
  @spec byte_offset_to_position(String.t(), non_neg_integer()) :: GapBuffer.position()
  defp byte_offset_to_position(text, byte_offset) do
    before_cursor = binary_part(text, 0, min(byte_offset, byte_size(text)))
    lines = :binary.split(before_cursor, "\n", [:global])
    line = length(lines) - 1
    col = lines |> List.last() |> byte_size()
    {line, col}
  end
end
