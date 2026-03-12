defmodule Minga.NavigableContentTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.NavigableContent
  alias Minga.NavigableContent.BufferSnapshot
  alias Minga.Scroll
  alias Minga.Text.Readable

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp snapshot(text, cursor_pos \\ {0, 0}) do
    doc = Document.new(text) |> Document.move_to(cursor_pos)
    BufferSnapshot.new(doc)
  end

  defp snapshot_with_scroll(text, cursor_pos, scroll) do
    doc = Document.new(text) |> Document.move_to(cursor_pos)
    BufferSnapshot.new(doc, scroll)
  end

  # ── Cursor ───────────────────────────────────────────────────────────────────

  describe "cursor/1 and set_cursor/2" do
    test "returns the current cursor position" do
      s = snapshot("hello\nworld", {1, 2})
      assert NavigableContent.cursor(s) == {1, 2}
    end

    test "set_cursor moves to the given position" do
      s = snapshot("hello\nworld")
      s = NavigableContent.set_cursor(s, {1, 3})
      assert NavigableContent.cursor(s) == {1, 3}
    end

    test "set_cursor clamps to content bounds" do
      s = snapshot("hi")
      s = NavigableContent.set_cursor(s, {99, 99})
      {line, col} = NavigableContent.cursor(s)
      # Should clamp: line 0, col clamped to length of "hi" (2)
      assert line == 0
      assert col <= 2
    end

    test "cursor round-trip preserves position" do
      s = snapshot("line one\nline two\nline three", {1, 4})
      pos = NavigableContent.cursor(s)
      s2 = NavigableContent.set_cursor(s, pos)
      assert NavigableContent.cursor(s2) == pos
    end
  end

  # ── Editable ─────────────────────────────────────────────────────────────────

  describe "editable?/1" do
    test "BufferSnapshot is editable" do
      s = snapshot("hello")
      assert NavigableContent.editable?(s) == true
    end
  end

  # ── Replace Range ────────────────────────────────────────────────────────────

  describe "replace_range/4" do
    test "insert text at a position (equal start and end)" do
      s = snapshot("hello world")
      s = NavigableContent.replace_range(s, {0, 5}, {0, 5}, " beautiful")
      assert Readable.content(s) == "hello beautiful world"
    end

    test "delete a range (empty replacement)" do
      s = snapshot("hello beautiful world")
      s = NavigableContent.replace_range(s, {0, 5}, {0, 14}, "")
      assert Readable.content(s) == "hello world"
    end

    test "replace a range with different text" do
      s = snapshot("hello world")
      s = NavigableContent.replace_range(s, {0, 0}, {0, 4}, "goodbye")
      assert Readable.content(s) == "goodbye world"
    end

    test "multi-line replace" do
      s = snapshot("line one\nline two\nline three")
      s = NavigableContent.replace_range(s, {0, 5}, {1, 3}, "1\nline")
      assert Readable.content(s) == "line 1\nline two\nline three"
    end

    test "insert at empty position preserves content" do
      s = snapshot("abc")
      s = NavigableContent.replace_range(s, {0, 1}, {0, 1}, "")
      assert Readable.content(s) == "abc"
    end
  end

  # ── Scroll ───────────────────────────────────────────────────────────────────

  describe "scroll/1 and set_scroll/2" do
    test "returns default scroll state" do
      s = snapshot("hello")
      scroll = NavigableContent.scroll(s)
      assert %Scroll{} = scroll
      assert scroll.offset == 0
      assert scroll.pinned == true
    end

    test "set_scroll updates the scroll state" do
      s = snapshot("hello")
      new_scroll = Scroll.new(10)
      s = NavigableContent.set_scroll(s, new_scroll)
      scroll = NavigableContent.scroll(s)
      assert scroll.offset == 10
      assert scroll.pinned == false
    end

    test "scroll round-trip preserves state" do
      scroll = %Scroll{offset: 42, pinned: false}
      s = snapshot_with_scroll("content", {0, 0}, scroll)
      assert NavigableContent.scroll(s) == scroll
    end
  end

  # ── Search Forward ──────────────────────────────────────────────────────────

  describe "search_forward/3" do
    test "finds pattern on the same line after cursor" do
      s = snapshot("hello world hello")
      # Skips current position (0), finds "hello" at position 12
      result = NavigableContent.search_forward(s, "hello", {0, 0})
      assert result == {0, 12}
    end

    test "finds first match when searching from before it" do
      s = snapshot("hello world hello")
      # Search from position 5 (space), finds "world" at 6
      result = NavigableContent.search_forward(s, "world", {0, 0})
      assert result == {0, 6}
    end

    test "finds pattern on a subsequent line" do
      s = snapshot("first line\nsecond hello\nthird line")
      result = NavigableContent.search_forward(s, "hello", {0, 0})
      assert result == {1, 7}
    end

    test "wraps around to the beginning" do
      s = snapshot("hello world\nsecond line")
      result = NavigableContent.search_forward(s, "hello", {1, 0})
      assert result == {0, 0}
    end

    test "returns nil for empty pattern" do
      s = snapshot("hello")
      assert NavigableContent.search_forward(s, "", {0, 0}) == nil
    end

    test "returns nil when pattern not found" do
      s = snapshot("hello world")
      assert NavigableContent.search_forward(s, "xyz", {0, 0}) == nil
    end

    test "skips the current position" do
      s = snapshot("aaa")
      # cursor at 0, pattern starts at 0, should find next occurrence
      result = NavigableContent.search_forward(s, "a", {0, 0})
      assert result == {0, 1}
    end

    test "finds pattern at start of line" do
      s = snapshot("abc\ndef\nghi")
      result = NavigableContent.search_forward(s, "def", {0, 0})
      assert result == {1, 0}
    end
  end

  # ── Search Backward ─────────────────────────────────────────────────────────

  describe "search_backward/3" do
    test "finds pattern on the same line before cursor" do
      s = snapshot("hello world hello")
      result = NavigableContent.search_backward(s, "hello", {0, 12})
      assert result == {0, 0}
    end

    test "finds pattern on a previous line" do
      s = snapshot("first hello\nsecond line\nthird line")
      result = NavigableContent.search_backward(s, "hello", {2, 0})
      assert result == {0, 6}
    end

    test "wraps around to the end" do
      s = snapshot("first line\nsecond hello")
      result = NavigableContent.search_backward(s, "hello", {0, 5})
      assert result == {1, 7}
    end

    test "returns nil for empty pattern" do
      s = snapshot("hello")
      assert NavigableContent.search_backward(s, "", {0, 5}) == nil
    end

    test "returns nil when pattern not found" do
      s = snapshot("hello world")
      assert NavigableContent.search_backward(s, "xyz", {0, 5}) == nil
    end
  end

  # ── Readable delegation ─────────────────────────────────────────────────────

  describe "Readable protocol delegation" do
    test "content/1 returns full text" do
      s = snapshot("hello\nworld")
      assert Readable.content(s) == "hello\nworld"
    end

    test "line_at/2 returns the correct line" do
      s = snapshot("alpha\nbeta\ngamma")
      assert Readable.line_at(s, 0) == "alpha"
      assert Readable.line_at(s, 1) == "beta"
      assert Readable.line_at(s, 2) == "gamma"
    end

    test "line_count/1 returns the number of lines" do
      s = snapshot("one\ntwo\nthree")
      assert Readable.line_count(s) == 3
    end

    test "line_at/2 returns nil for out-of-range" do
      s = snapshot("hello")
      assert Readable.line_at(s, 99) == nil
    end

    test "offset_to_position/2 converts byte offset to position" do
      s = snapshot("hello\nworld")
      # "hello\n" is 6 bytes, "w" is at offset 6 = {1, 0}
      assert Readable.offset_to_position(s, 6) == {1, 0}
    end
  end

  # ── Motion integration ─────────────────────────────────────────────────────

  describe "Motion functions work through Readable delegation" do
    test "word_forward works on BufferSnapshot" do
      s = snapshot("hello world foo", {0, 0})
      pos = Minga.Motion.word_forward(s, NavigableContent.cursor(s))
      assert pos == {0, 6}
    end

    test "word_backward works on BufferSnapshot" do
      s = snapshot("hello world foo", {0, 12})
      pos = Minga.Motion.word_backward(s, {0, 12})
      assert pos == {0, 6}
    end

    test "line_end works on BufferSnapshot" do
      s = snapshot("hello world", {0, 0})
      pos = Minga.Motion.line_end(s, {0, 0})
      assert pos == {0, 10}
    end

    test "paragraph_forward works across lines" do
      s = snapshot("line one\nline two\n\nline four", {0, 0})
      pos = Minga.Motion.paragraph_forward(s, {0, 0})
      # Should move to the blank line
      assert elem(pos, 0) == 2
    end

    test "compose motion + replace_range for a delete-word operation" do
      # Simulate dw: delete from cursor to word_forward
      s = snapshot("hello world foo", {0, 0})
      cursor = NavigableContent.cursor(s)
      word_end = Minga.Motion.word_forward(s, cursor)

      # Delete from cursor to one before word_end (exclusive end for dw)
      s =
        NavigableContent.replace_range(s, cursor, {elem(word_end, 0), elem(word_end, 1) - 1}, "")

      content = Readable.content(s)
      assert content == "world foo"
    end
  end

  # ── BufferSnapshot constructor ─────────────────────────────────────────────

  describe "BufferSnapshot.new/1 and new/2" do
    test "new/1 uses default scroll" do
      doc = Document.new("test")
      s = BufferSnapshot.new(doc)
      assert s.scroll == %Scroll{}
    end

    test "new/2 uses provided scroll" do
      doc = Document.new("test")
      scroll = %Scroll{offset: 5, pinned: false}
      s = BufferSnapshot.new(doc, scroll)
      assert s.scroll == scroll
    end
  end

  # ── Edge cases ─────────────────────────────────────────────────────────────

  describe "edge cases" do
    test "empty content" do
      s = snapshot("")
      assert NavigableContent.cursor(s) == {0, 0}
      assert Readable.line_count(s) == 1
      assert Readable.content(s) == ""
      assert NavigableContent.editable?(s) == true
    end

    test "single character content" do
      s = snapshot("x")
      assert NavigableContent.cursor(s) == {0, 0}
      s = NavigableContent.set_cursor(s, {0, 1})
      assert NavigableContent.cursor(s) == {0, 1}
    end

    test "unicode content" do
      s = snapshot("héllo wörld")
      # byte offset for 'w' after "héllo " (h=1, é=2, l=1, l=1, o=1, space=1 = 7 bytes)
      assert Readable.line_at(s, 0) == "héllo wörld"
    end

    test "search with unicode pattern" do
      s = snapshot("hello wörld, wörld again")
      result = NavigableContent.search_forward(s, "wörld", {0, 0})
      # "hello " is 6 bytes, "wörld" starts at byte 6
      assert result == {0, 6}
    end

    test "replace_range preserves other lines" do
      s = snapshot("line1\nline2\nline3")
      s = NavigableContent.replace_range(s, {1, 0}, {1, 4}, "LINE2")
      assert Readable.line_at(s, 0) == "line1"
      assert Readable.line_at(s, 1) == "LINE2"
      assert Readable.line_at(s, 2) == "line3"
    end
  end
end
