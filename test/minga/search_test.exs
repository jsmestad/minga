defmodule Minga.SearchTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.GapBuffer
  alias Minga.Search

  # ── find_next/4 ────────────────────────────────────────────────────────

  describe "find_next/4 forward" do
    test "finds match after cursor on same line" do
      assert {0, 6} = Search.find_next("hello hello", "hello", {0, 0}, :forward)
    end

    test "finds match on next line" do
      assert {1, 0} = Search.find_next("foo\nbar", "bar", {0, 0}, :forward)
    end

    test "wraps around to beginning when no match after cursor" do
      assert {0, 0} = Search.find_next("hello\nworld", "hello", {1, 0}, :forward)
    end

    test "returns nil when pattern not found" do
      assert nil == Search.find_next("hello world", "xyz", {0, 0}, :forward)
    end

    test "returns nil for empty pattern" do
      assert nil == Search.find_next("hello", "", {0, 0}, :forward)
    end

    test "finds match at start of buffer" do
      assert {0, 0} = Search.find_next("hello world", "hello", {0, 4}, :forward)
    end

    test "handles single-character pattern" do
      assert {0, 1} = Search.find_next("abc", "b", {0, 0}, :forward)
    end

    test "handles unicode patterns" do
      assert {0, 5} = Search.find_next("café café", "café", {0, 0}, :forward)
    end

    test "finds second occurrence when cursor is at first" do
      assert {0, 4} = Search.find_next("foo foo foo", "foo", {0, 0}, :forward)
    end
  end

  describe "find_next/4 backward" do
    test "finds match before cursor on same line" do
      assert {0, 0} = Search.find_next("hello hello", "hello", {0, 6}, :backward)
    end

    test "finds match on previous line" do
      assert {0, 0} = Search.find_next("foo\nbar", "foo", {1, 0}, :backward)
    end

    test "wraps around to end when no match before cursor" do
      assert {1, 0} = Search.find_next("foo\nbar", "bar", {0, 0}, :backward)
    end

    test "returns nil when pattern not found" do
      assert nil == Search.find_next("hello world", "xyz", {0, 5}, :backward)
    end
  end

  # ── find_all_in_range/3 ────────────────────────────────────────────────

  describe "find_all_in_range/3" do
    test "finds all occurrences across lines" do
      lines = ["foo bar foo", "baz foo"]
      assert [{0, 0, 3}, {0, 8, 3}, {1, 4, 3}] = Search.find_all_in_range(lines, "foo", 0)
    end

    test "respects first_line offset" do
      lines = ["foo bar"]
      assert [{5, 0, 3}] = Search.find_all_in_range(lines, "foo", 5)
    end

    test "returns empty list for empty pattern" do
      assert [] = Search.find_all_in_range(["hello"], "", 0)
    end

    test "returns empty list for no matches" do
      assert [] = Search.find_all_in_range(["hello world"], "xyz", 0)
    end

    test "finds overlapping start positions" do
      # "aa" in "aaa" should find at col 0 and col 1
      assert [{0, 0, 2}, {0, 1, 2}] = Search.find_all_in_range(["aaa"], "aa", 0)
    end
  end

  # ── word_at_cursor/2 ──────────────────────────────────────────────────

  describe "word_at_cursor/2" do
    test "returns word under cursor" do
      buf = GapBuffer.new("hello world")
      assert "hello" = Search.word_at_cursor(buf, {0, 0})
    end

    test "returns word when cursor is mid-word" do
      buf = GapBuffer.new("hello world")
      assert "hello" = Search.word_at_cursor(buf, {0, 2})
    end

    test "returns nil when cursor is on space" do
      buf = GapBuffer.new("hello world")
      assert nil == Search.word_at_cursor(buf, {0, 5})
    end

    test "returns nil for empty buffer" do
      buf = GapBuffer.new("")
      assert nil == Search.word_at_cursor(buf, {0, 0})
    end

    test "returns word with underscores" do
      buf = GapBuffer.new("hello_world test")
      assert "hello_world" = Search.word_at_cursor(buf, {0, 3})
    end

    test "returns word with numbers" do
      buf = GapBuffer.new("var123 = 5")
      assert "var123" = Search.word_at_cursor(buf, {0, 0})
    end

    test "works on second line" do
      buf = GapBuffer.new("first\nsecond")
      assert "second" = Search.word_at_cursor(buf, {1, 0})
    end

    test "returns nil when cursor is on punctuation" do
      buf = GapBuffer.new("hello, world")
      assert nil == Search.word_at_cursor(buf, {0, 5})
    end
  end
end
