defmodule Minga.Buffer.DocumentTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document

  # ── Construction ──

  describe "new/1" do
    test "creates an empty buffer" do
      buf = Document.new()
      assert Document.content(buf) == ""
      assert Document.cursor(buf) == {0, 0}
    end

    test "creates a buffer from a string" do
      buf = Document.new("hello")
      assert Document.content(buf) == "hello"
      assert Document.cursor(buf) == {0, 0}
    end

    test "creates a buffer from a multi-line string" do
      buf = Document.new("hello\nworld\n!")
      assert Document.content(buf) == "hello\nworld\n!"
      assert Document.cursor(buf) == {0, 0}
    end
  end

  # ── Queries ──

  describe "empty?/1" do
    test "returns true for empty buffer" do
      assert Document.empty?(Document.new())
    end

    test "returns false for non-empty buffer" do
      refute Document.empty?(Document.new("x"))
    end
  end

  describe "line_count/1" do
    test "empty buffer has 1 line" do
      assert Document.line_count(Document.new()) == 1
    end

    test "single line without newline" do
      assert Document.line_count(Document.new("hello")) == 1
    end

    test "counts lines separated by newlines" do
      assert Document.line_count(Document.new("a\nb\nc")) == 3
    end

    test "trailing newline adds an empty line" do
      assert Document.line_count(Document.new("a\nb\n")) == 3
    end
  end

  describe "line_at/2" do
    test "returns the first line" do
      buf = Document.new("hello\nworld")
      assert Document.line_at(buf, 0) == "hello"
    end

    test "returns the second line" do
      buf = Document.new("hello\nworld")
      assert Document.line_at(buf, 1) == "world"
    end

    test "returns nil for out-of-range line" do
      buf = Document.new("hello")
      assert Document.line_at(buf, 5) == nil
    end

    test "returns empty string for empty line" do
      buf = Document.new("hello\n\nworld")
      assert Document.line_at(buf, 1) == ""
    end
  end

  describe "lines/3" do
    test "returns a range of lines" do
      buf = Document.new("a\nb\nc\nd\ne")
      assert Document.lines(buf, 1, 3) == ["b", "c", "d"]
    end

    test "returns empty list when start is past end" do
      buf = Document.new("a\nb")
      assert Document.lines(buf, 10, 5) == []
    end

    test "returns fewer lines when count exceeds available" do
      buf = Document.new("a\nb\nc")
      assert Document.lines(buf, 1, 10) == ["b", "c"]
    end
  end

  describe "cursor/1" do
    test "starts at {0, 0} for new buffer" do
      assert Document.cursor(Document.new("hello")) == {0, 0}
    end

    test "reflects position after moving right (ASCII)" do
      buf = Document.new("hello") |> Document.move(:right) |> Document.move(:right)
      assert Document.cursor(buf) == {0, 2}
    end

    test "reflects position on second line" do
      buf = Document.new("ab\ncd") |> Document.move_to({1, 1})
      assert Document.cursor(buf) == {1, 1}
    end
  end

  # ── Insertion ──

  describe "insert_char/2" do
    test "inserts at the beginning of a buffer" do
      buf = Document.new("hello") |> Document.insert_char("X")
      assert Document.content(buf) == "Xhello"
      assert Document.cursor(buf) == {0, 1}
    end

    test "inserts in the middle after moving" do
      buf =
        Document.new("hello")
        |> Document.move(:right)
        |> Document.move(:right)
        |> Document.insert_char("X")

      assert Document.content(buf) == "heXllo"
      assert Document.cursor(buf) == {0, 3}
    end

    test "inserts at the end" do
      buf = Document.new("hi") |> Document.move_to({0, 2}) |> Document.insert_char("!")
      assert Document.content(buf) == "hi!"
    end

    test "inserts a newline" do
      buf = Document.new("ab") |> Document.move(:right) |> Document.insert_char("\n")
      assert Document.content(buf) == "a\nb"
      assert Document.cursor(buf) == {1, 0}
    end

    test "inserts unicode emoji — byte_col reflects byte size" do
      buf = Document.new("hi") |> Document.insert_char("🥨")
      assert Document.content(buf) == "🥨hi"
      # 🥨 is 4 bytes
      assert Document.cursor(buf) == {0, 4}
    end

    test "inserts multi-byte CJK character" do
      buf = Document.new("hi") |> Document.insert_char("日")
      assert Document.content(buf) == "日hi"
      # 日 is 3 bytes
      assert Document.cursor(buf) == {0, 3}
    end

    test "inserts into empty buffer" do
      buf = Document.new() |> Document.insert_char("a")
      assert Document.content(buf) == "a"
      assert Document.cursor(buf) == {0, 1}
    end
  end

  # ── Bulk Insert ──

  describe "insert_text/2" do
    test "inserts a multi-character string in one operation" do
      buf = Document.new("world") |> Document.insert_text("hello ")
      assert Document.content(buf) == "hello world"
      assert Document.cursor(buf) == {0, 6}
    end

    test "inserts text containing newlines" do
      buf = Document.new("end") |> Document.insert_text("line1\nline2\n")
      assert Document.content(buf) == "line1\nline2\nend"
      assert Document.cursor(buf) == {2, 0}
      assert Document.line_count(buf) == 3
    end

    test "empty string is a no-op" do
      buf = Document.new("hello")
      assert Document.insert_text(buf, "") == buf
    end

    test "inserts at cursor position after move" do
      buf =
        Document.new("hello world")
        |> Document.move_to({0, 5})
        |> Document.insert_text(" beautiful")

      assert Document.content(buf) == "hello beautiful world"
      assert Document.cursor(buf) == {0, 15}
    end

    test "inserts unicode text in bulk" do
      buf = Document.new("end") |> Document.insert_text("🎉🎊")
      assert Document.content(buf) == "🎉🎊end"
      # Each emoji is 4 bytes
      assert Document.cursor(buf) == {0, 8}
    end

    test "produces identical result to sequential insert_char calls" do
      text = "hello\nworld\n!"
      bulk = Document.new("base") |> Document.insert_text(text)

      sequential =
        text
        |> String.graphemes()
        |> Enum.reduce(Document.new("base"), fn char, doc ->
          Document.insert_char(doc, char)
        end)

      assert Document.content(bulk) == Document.content(sequential)
      assert Document.cursor(bulk) == Document.cursor(sequential)
      assert Document.line_count(bulk) == Document.line_count(sequential)
    end

    test "inserts multi-line text in the middle of existing content" do
      buf =
        Document.new("startend")
        |> Document.move_to({0, 5})
        |> Document.insert_text("A\nB\nC")

      assert Document.content(buf) == "startA\nB\nCend"
      assert Document.cursor(buf) == {2, 1}
      assert Document.line_count(buf) == 3
    end
  end

  # ── Deletion ──

  describe "delete_before/1" do
    test "deletes the character before the cursor" do
      buf =
        Document.new("hello")
        |> Document.move(:right)
        |> Document.move(:right)
        |> Document.delete_before()

      assert Document.content(buf) == "hllo"
      assert Document.cursor(buf) == {0, 1}
    end

    test "does nothing at the start of the buffer" do
      buf = Document.new("hello") |> Document.delete_before()
      assert Document.content(buf) == "hello"
      assert Document.cursor(buf) == {0, 0}
    end

    test "deleting newline joins lines" do
      buf = Document.new("ab\ncd") |> Document.move_to({1, 0}) |> Document.delete_before()
      assert Document.content(buf) == "abcd"
      assert Document.cursor(buf) == {0, 2}
    end

    test "deletes unicode character" do
      buf =
        Document.new("🥨hi")
        |> Document.move(:right)
        |> Document.delete_before()

      assert Document.content(buf) == "hi"
    end

    test "does nothing on empty buffer" do
      buf = Document.new() |> Document.delete_before()
      assert Document.content(buf) == ""
      assert Document.empty?(buf)
    end
  end

  describe "delete_at/1" do
    test "deletes the character at the cursor" do
      buf = Document.new("hello") |> Document.delete_at()
      assert Document.content(buf) == "ello"
      assert Document.cursor(buf) == {0, 0}
    end

    test "does nothing at the end of the buffer" do
      buf = Document.new("hi") |> Document.move_to({0, 2}) |> Document.delete_at()
      assert Document.content(buf) == "hi"
    end

    test "deletes newline at cursor joins lines" do
      buf = Document.new("ab\ncd") |> Document.move_to({0, 2}) |> Document.delete_at()
      assert Document.content(buf) == "abcd"
      assert Document.cursor(buf) == {0, 2}
    end

    test "deletes unicode character at cursor" do
      buf = Document.new("🥨hi") |> Document.delete_at()
      assert Document.content(buf) == "hi"
    end
  end

  # ── Movement ──

  describe "move/2 :left" do
    test "moves cursor left" do
      buf = Document.new("hello") |> Document.move_to({0, 3}) |> Document.move(:left)
      assert Document.cursor(buf) == {0, 2}
    end

    test "stays at start when already at {0, 0}" do
      buf = Document.new("hello") |> Document.move(:left)
      assert Document.cursor(buf) == {0, 0}
    end

    test "wraps to end of previous line" do
      buf = Document.new("ab\ncd") |> Document.move_to({1, 0}) |> Document.move(:left)
      assert Document.cursor(buf) == {0, 2}
    end
  end

  describe "move/2 :right" do
    test "moves cursor right" do
      buf = Document.new("hello") |> Document.move(:right)
      assert Document.cursor(buf) == {0, 1}
    end

    test "stays at end when already at the end" do
      buf = Document.new("hi") |> Document.move_to({0, 2}) |> Document.move(:right)
      assert Document.cursor(buf) == {0, 2}
    end

    test "wraps to start of next line" do
      buf = Document.new("ab\ncd") |> Document.move_to({0, 2}) |> Document.move(:right)
      assert Document.cursor(buf) == {1, 0}
    end

    test "moves by byte size for multi-byte characters" do
      buf = Document.new("🥨ab") |> Document.move(:right)
      # 🥨 is 4 bytes
      assert Document.cursor(buf) == {0, 4}
    end
  end

  describe "move/2 :up" do
    test "moves cursor to the same column on previous line" do
      buf = Document.new("hello\nworld") |> Document.move_to({1, 3}) |> Document.move(:up)
      assert Document.cursor(buf) == {0, 3}
    end

    test "clamps column when previous line is shorter" do
      buf = Document.new("hi\nworld") |> Document.move_to({1, 4}) |> Document.move(:up)
      assert Document.cursor(buf) == {0, 2}
    end

    test "stays on first line when already on line 0" do
      buf = Document.new("hello\nworld") |> Document.move(:up)
      assert Document.cursor(buf) == {0, 0}
    end
  end

  describe "move/2 :down" do
    test "moves cursor to the same column on next line" do
      buf = Document.new("hello\nworld") |> Document.move_to({0, 3}) |> Document.move(:down)
      assert Document.cursor(buf) == {1, 3}
    end

    test "clamps column when next line is shorter" do
      buf = Document.new("hello\nhi") |> Document.move_to({0, 4}) |> Document.move(:down)
      assert Document.cursor(buf) == {1, 2}
    end

    test "stays on last line when already on the last line" do
      buf = Document.new("hello\nworld") |> Document.move_to({1, 0}) |> Document.move(:down)
      assert Document.cursor(buf) == {1, 0}
    end
  end

  describe "move_to/2" do
    test "moves to exact position" do
      buf = Document.new("abc\ndef\nghi") |> Document.move_to({2, 1})
      assert Document.cursor(buf) == {2, 1}
    end

    test "clamps line to last line" do
      buf = Document.new("abc\ndef") |> Document.move_to({99, 0})
      assert Document.cursor(buf) == {1, 0}
    end

    test "clamps column to end of line (byte size)" do
      buf = Document.new("abc\ndef") |> Document.move_to({0, 99})
      assert Document.cursor(buf) == {0, 3}
    end

    test "preserves buffer content after move" do
      text = "hello\nworld"
      buf = Document.new(text) |> Document.move_to({1, 3})
      assert Document.content(buf) == text
    end

    test "clamps to grapheme boundary for multi-byte chars" do
      # "café" — é is 2 bytes (0xC3 0xA9), byte_size is 5
      buf = Document.new("café") |> Document.move_to({0, 4})
      # byte 4 is in the middle of é (which starts at byte 3)
      # Should clamp to byte 3 (start of é)
      assert Document.cursor(buf) == {0, 3}
    end
  end

  # ── Grapheme/byte conversion ──

  describe "grapheme_col/2" do
    test "ASCII: byte col equals grapheme col" do
      buf = Document.new("hello")
      assert Document.grapheme_col(buf, {0, 3}) == 3
    end

    test "multi-byte: byte col larger than grapheme col" do
      # "café" — é is 2 bytes
      buf = Document.new("café")
      # byte_col 3 = start of é = grapheme col 3
      assert Document.grapheme_col(buf, {0, 3}) == 3
      # byte_col 5 (end) = 4 graphemes
      assert Document.grapheme_col(buf, {0, 5}) == 4
    end

    test "emoji: 4-byte char" do
      buf = Document.new("🥨ab")
      # byte 0 = grapheme 0
      assert Document.grapheme_col(buf, {0, 0}) == 0
      # byte 4 = past emoji = grapheme 1
      assert Document.grapheme_col(buf, {0, 4}) == 1
      # byte 5 = grapheme 2
      assert Document.grapheme_col(buf, {0, 5}) == 2
    end
  end

  describe "byte_col_for_grapheme/2" do
    test "ASCII: grapheme index equals byte offset" do
      assert Document.byte_col_for_grapheme("hello", 3) == 3
    end

    test "multi-byte: grapheme 4 of café is byte 5" do
      assert Document.byte_col_for_grapheme("café", 4) == 5
    end

    test "emoji: grapheme 1 of 🥨ab is byte 4" do
      assert Document.byte_col_for_grapheme("🥨ab", 1) == 4
    end
  end

  describe "last_grapheme_byte_offset/1" do
    test "empty string returns 0" do
      assert Document.last_grapheme_byte_offset("") == 0
    end

    test "ASCII string" do
      assert Document.last_grapheme_byte_offset("hello") == 4
    end

    test "multi-byte last char" do
      # "café" — é starts at byte 3
      assert Document.last_grapheme_byte_offset("café") == 3
    end

    test "emoji last char" do
      # "hi🥨" — 🥨 starts at byte 2
      assert Document.last_grapheme_byte_offset("hi🥨") == 2
    end
  end

  # ── Round-trip integrity ──

  describe "content integrity" do
    test "insert then delete_before restores original" do
      buf = Document.new("hello")
      original = Document.content(buf)

      buf =
        buf |> Document.move(:right) |> Document.insert_char("X") |> Document.delete_before()

      assert Document.content(buf) == original
    end

    test "moving around does not change content" do
      text = "hello\nworld\nfoo"
      buf = Document.new(text)

      buf =
        buf
        |> Document.move(:right)
        |> Document.move(:down)
        |> Document.move(:left)
        |> Document.move(:up)
        |> Document.move_to({2, 1})
        |> Document.move_to({0, 0})

      assert Document.content(buf) == text
    end

    test "multiple insertions and deletions" do
      buf =
        Document.new()
        |> Document.insert_char("a")
        |> Document.insert_char("b")
        |> Document.insert_char("c")
        |> Document.delete_before()
        |> Document.insert_char("C")

      assert Document.content(buf) == "abC"
    end
  end

  # ── Unicode edge cases ──

  describe "unicode handling" do
    test "handles combining characters" do
      # é as e + combining acute accent
      text = "cafe\u0301"
      buf = Document.new(text)
      assert Document.line_count(buf) == 1
      assert Document.content(buf) == text
    end

    test "handles emoji sequences" do
      buf = Document.new("🇩🇪") |> Document.insert_char("!")
      assert Document.content(buf) == "!🇩🇪"
    end

    test "cursor position uses byte offsets" do
      buf = Document.new("🥨ab") |> Document.move(:right)
      # 🥨 is 4 bytes, so cursor_col = 4
      assert Document.cursor(buf) == {0, 4}
      # But grapheme_col is 1
      assert Document.grapheme_col(buf, Document.cursor(buf)) == 1
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
        buf = Document.new(text)
        clamped_pos = min(pos, byte_size(text))
        line_col = byte_offset_to_position(text, clamped_pos)

        buf =
          buf
          |> Document.move_to(line_col)
          |> Document.insert_char(char)
          |> Document.delete_before()

        assert Document.content(buf) == text
      end
    end

    property "moving does not alter content" do
      check all(
              text <- string(:printable, min_length: 1, max_length: 200),
              moves <-
                list_of(member_of([:left, :right, :up, :down]), min_length: 1, max_length: 20)
            ) do
        buf = Document.new(text)

        result =
          Enum.reduce(moves, buf, fn dir, acc ->
            Document.move(acc, dir)
          end)

        assert Document.content(result) == text
      end
    end

    property "cursor is always within valid bounds" do
      check all(
              text <- string(:printable, min_length: 0, max_length: 200),
              moves <-
                list_of(member_of([:left, :right, :up, :down]), min_length: 0, max_length: 30)
            ) do
        buf = Document.new(text)

        buf =
          Enum.reduce(moves, buf, fn dir, acc ->
            Document.move(acc, dir)
          end)

        {line, byte_col} = Document.cursor(buf)
        max_line = Document.line_count(buf) - 1
        assert line >= 0 and line <= max_line

        current_line = Document.line_at(buf, line)
        max_col = byte_size(current_line)
        assert byte_col >= 0 and byte_col <= max_col
      end
    end
  end

  # ── Cache validity tests ──

  describe "cache: cursor and line_count accuracy" do
    test "insert at start of line updates col" do
      buf = Document.new("hello") |> Document.insert_char("X")
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 1}
    end

    test "insert in middle of line updates col" do
      buf =
        Document.new("hello")
        |> Document.move_to({0, 2})
        |> Document.insert_char("X")

      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 3}
    end

    test "insert at end of line updates col" do
      buf =
        Document.new("hello")
        |> Document.move_to({0, 5})
        |> Document.insert_char("X")

      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 6}
    end

    test "inserting a newline increments line and resets col" do
      buf = Document.new("ab") |> Document.move(:right) |> Document.insert_char("\n")
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {1, 0}
      assert Document.line_count(buf) == 2
    end

    test "inserting multi-line string updates cursor and line_count" do
      buf =
        Document.new("start") |> Document.move_to({0, 5}) |> Document.insert_char("a\nb\nc")

      assert_cache_valid(buf)
      assert Document.cursor(buf) == {2, 1}
      assert Document.line_count(buf) == 3
    end

    test "delete_before at start of line joins lines, updates cursor and line_count" do
      buf = Document.new("ab\ncd") |> Document.move_to({1, 0}) |> Document.delete_before()
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 2}
      assert Document.line_count(buf) == 1
    end

    test "delete_before in middle of line decrements col" do
      buf = Document.new("hello") |> Document.move_to({0, 3}) |> Document.delete_before()
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 2}
    end

    test "delete_at on newline decrements line_count, cursor unchanged" do
      buf = Document.new("ab\ncd") |> Document.move_to({0, 2}) |> Document.delete_at()
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 2}
      assert Document.line_count(buf) == 1
    end

    test "delete_at on regular char, cursor and line_count unchanged" do
      buf = Document.new("hello") |> Document.delete_at()
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 0}
      assert Document.line_count(buf) == 1
    end

    test "move_to arbitrary position updates cache" do
      buf = Document.new("abc\ndef\nghi") |> Document.move_to({2, 1})
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {2, 1}
    end

    test "move_left across newline updates line and col" do
      buf = Document.new("ab\ncd") |> Document.move_to({1, 0}) |> Document.move(:left)
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {0, 2}
    end

    test "move_right across newline updates line and resets col" do
      buf = Document.new("ab\ncd") |> Document.move_to({0, 2}) |> Document.move(:right)
      assert_cache_valid(buf)
      assert Document.cursor(buf) == {1, 0}
    end

    test "delete_range spanning multiple lines rebuilds cache correctly" do
      buf = Document.new("abc\ndef\nghi") |> Document.delete_range({0, 1}, {1, 1})
      assert_cache_valid(buf)
    end

    test "delete_lines rebuilds cache correctly" do
      buf = Document.new("a\nb\nc\nd") |> Document.delete_lines(1, 2)
      assert_cache_valid(buf)
      assert Document.line_count(buf) == 2
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
        buf = Document.new(text)

        result =
          Enum.reduce(ops, buf, fn
            {:insert, char}, acc -> Document.insert_char(acc, char)
            {:move_to, l, c}, acc -> Document.move_to(acc, {l, c})
            :delete_before, acc -> Document.delete_before(acc)
            :delete_at, acc -> Document.delete_at(acc)
            dir, acc -> Document.move(acc, dir)
          end)

        assert_cache_valid(result)
      end
    end
  end

  # ── Test helpers ──

  # Verifies that the cached cursor_line, cursor_col, and line_count fields
  # match values recomputed from the raw buffer content.
  # cursor_col is now a byte offset within the current line.
  @spec assert_cache_valid(Document.t()) :: :ok
  defp assert_cache_valid(%Document{
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

  # ── Line index cache tests ──

  describe "line index cache" do
    property "line_at matches naive String.split for random content" do
      check all(
              text <- string(:printable, min_length: 0, max_length: 500),
              line_num <- integer(0..20)
            ) do
        buf = Document.new(text)
        naive = text |> String.split("\n") |> Enum.at(line_num)
        indexed = Document.line_at(buf, line_num)
        assert indexed == naive
      end
    end

    property "lines matches naive String.split |> Enum.slice for random content" do
      check all(
              text <- string(:printable, min_length: 0, max_length: 500),
              start <- integer(0..15),
              count <- integer(1..10)
            ) do
        buf = Document.new(text)
        naive = text |> String.split("\n") |> Enum.slice(start, count)
        indexed = Document.lines(buf, start, count)
        assert indexed == naive
      end
    end

    test "line_at works after mutations invalidate the cache" do
      buf = Document.new("aaa\nbbb\nccc")
      assert Document.line_at(buf, 1) == "bbb"

      # Insert invalidates cache
      buf = Document.insert_char(buf, "X")
      assert Document.line_at(buf, 0) == "Xaaa"

      # Move invalidates cache
      buf = Document.move_to(buf, {1, 0})
      assert Document.line_at(buf, 1) == "bbb"

      # Delete invalidates cache
      buf = Document.delete_at(buf)
      assert Document.line_at(buf, 1) == "bb"
    end

    test "lines returns correct viewport after insert_text" do
      buf = Document.new("line1\nline2\nline3\nline4\nline5")
      buf = Document.move_to(buf, {2, 0})
      buf = Document.insert_text(buf, "NEW\n")

      assert Document.lines(buf, 2, 2) == ["NEW", "line3"]
      assert Document.line_count(buf) == 6
    end

    test "position_to_offset uses index for O(1) lookup" do
      buf = Document.new("hello\nworld\nfoo")
      # "hello\n" = 6 bytes, "world\n" = 6 bytes, "foo" starts at 12
      assert Document.position_to_offset(buf, {0, 0}) == 0
      assert Document.position_to_offset(buf, {1, 0}) == 6
      assert Document.position_to_offset(buf, {2, 0}) == 12
      assert Document.position_to_offset(buf, {2, 2}) == 14
    end
  end

  # Convert a byte offset in text to a {line, byte_col} position.
  @spec byte_offset_to_position(String.t(), non_neg_integer()) :: Document.position()
  defp byte_offset_to_position(text, byte_offset) do
    before_cursor = binary_part(text, 0, min(byte_offset, byte_size(text)))
    lines = :binary.split(before_cursor, "\n", [:global])
    line = length(lines) - 1
    col = lines |> List.last() |> byte_size()
    {line, col}
  end
end
