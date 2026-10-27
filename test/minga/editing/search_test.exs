defmodule Minga.Editing.SearchTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document
  alias Minga.Editing.Search
  alias Minga.Editing.Search.Match

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
      # "café" is 5 bytes (é = 2), so second café starts at byte 6
      assert {0, 6} = Search.find_next("café café", "café", {0, 0}, :forward)
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

  describe "match_at/4" do
    test "returns the exact match and its byte length" do
      assert %Match{line: 0, col: 4, length: 5} =
               Search.match_at("one café", "café", {0, 4})
    end

    test "does not substitute a nearby match" do
      assert nil == Search.match_at("foo foo", "foo", {0, 1})
    end

    test "accepts an overlapping match selected by ordinary navigation" do
      assert %Match{line: 0, col: 1, length: 2} = Search.match_at("aaa", "aa", {0, 1})
    end

    test "preserves whole-word context before the selected column" do
      assert nil == Search.match_at("afoo foo", "foo", {0, 1}, whole_word: true)

      assert %Match{col: 5, length: 3} =
               Search.match_at("afoo foo", "foo", {0, 5}, whole_word: true)
    end

    test "returns zero-width regular expression matches without looping" do
      assert %Match{line: 0, col: 0, length: 0} =
               Search.match_at("foo", "(?=foo)", {0, 0}, regex: true)
    end
  end

  # ── find_all_in_range/3 ────────────────────────────────────────────────

  describe "find_all_in_range/3" do
    test "finds all occurrences across lines" do
      lines = ["foo bar foo", "baz foo"]

      assert [
               %Match{line: 0, col: 0, length: 3},
               %Match{line: 0, col: 8, length: 3},
               %Match{line: 1, col: 4, length: 3}
             ] = Search.find_all_in_range(lines, "foo", 0)
    end

    test "respects first_line offset" do
      lines = ["foo bar"]

      assert [%Match{line: 5, col: 0, length: 3}] =
               Search.find_all_in_range(lines, "foo", 5)
    end

    test "returns empty list for empty pattern" do
      assert [] = Search.find_all_in_range(["hello"], "", 0)
    end

    test "returns empty list for no matches" do
      assert [] = Search.find_all_in_range(["hello world"], "xyz", 0)
    end

    test "finds overlapping start positions" do
      # "aa" in "aaa" should find at col 0 and col 1
      assert [
               %Match{line: 0, col: 0, length: 2},
               %Match{line: 0, col: 1, length: 2}
             ] = Search.find_all_in_range(["aaa"], "aa", 0)
    end
  end

  # ── word_at_cursor/2 ──────────────────────────────────────────────────

  describe "word_at_cursor/2" do
    test "returns word under cursor" do
      buf = Document.new("hello world")
      assert "hello" = Search.word_at_cursor(buf, {0, 0})
    end

    test "returns word when cursor is mid-word" do
      buf = Document.new("hello world")
      assert "hello" = Search.word_at_cursor(buf, {0, 2})
    end

    test "returns nil when cursor is on space" do
      buf = Document.new("hello world")
      assert nil == Search.word_at_cursor(buf, {0, 5})
    end

    test "returns nil for empty buffer" do
      buf = Document.new("")
      assert nil == Search.word_at_cursor(buf, {0, 0})
    end

    test "returns word with underscores" do
      buf = Document.new("hello_world test")
      assert "hello_world" = Search.word_at_cursor(buf, {0, 3})
    end

    test "returns word with numbers" do
      buf = Document.new("var123 = 5")
      assert "var123" = Search.word_at_cursor(buf, {0, 0})
    end

    test "works on second line" do
      buf = Document.new("first\nsecond")
      assert "second" = Search.word_at_cursor(buf, {1, 0})
    end

    test "returns nil when cursor is on punctuation" do
      buf = Document.new("hello, world")
      assert nil == Search.word_at_cursor(buf, {0, 5})
    end
  end

  # ── substitute/4 ──────────────────────────────────────────────────────────

  describe "substitute/4 global" do
    test "replaces all occurrences across lines" do
      assert {"baz bar baz\nbaz", 3} =
               Search.substitute("foo bar foo\nfoo", "foo", "baz", true)
    end

    test "returns 0 count when pattern not found" do
      assert {"hello world", 0} = Search.substitute("hello world", "xyz", "abc", true)
    end

    test "handles empty replacement (deletion)" do
      assert {" bar ", 2} = Search.substitute("foo bar foo", "foo", "", true)
    end

    test "handles replacement longer than pattern" do
      assert {"hello hello", 1} = Search.substitute("hi hello", "hi", "hello", true)
    end

    test "handles multi-line content" do
      content = "line one\nline two\nline three"
      assert {"row one\nrow two\nrow three", 3} = Search.substitute(content, "line", "row", true)
    end

    test "handles unicode content" do
      assert {"world café", 1} = Search.substitute("hello café", "hello", "world", true)
    end
  end

  describe "substitute/4 non-global (first per line)" do
    test "replaces only first occurrence per line" do
      assert {"baz bar foo\nbaz", 2} =
               Search.substitute("foo bar foo\nfoo", "foo", "baz", false)
    end

    test "replaces first on each line independently" do
      content = "aa bb aa\naa cc aa"
      assert {"xx bb aa\nxx cc aa", 2} = Search.substitute(content, "aa", "xx", false)
    end
  end

  # ── Regex patterns without metacharacters ─────────────────────────────

  # Atoms cover multibyte UTF-8, a raw non-UTF-8 byte, spaces, control bytes,
  # and punctuation that PCRE treats literally. The small alphabet makes
  # overlapping matches common.
  @literal_atoms [
    "a",
    "b",
    "é",
    "日",
    "👍",
    <<0xFF>>,
    " ",
    "\t",
    "\r",
    "\0",
    <<1>>,
    "#",
    "-",
    "/",
    "&",
    "'",
    "~",
    "_",
    ","
  ]

  @replacements ["", "x", "é", "\\0", "\\1", "$1", "&", "aa"]

  defp atom_list(min, max) do
    StreamData.list_of(StreamData.member_of(@literal_atoms), min_length: min, max_length: max)
  end

  defp pattern_from(line_atoms) do
    sliced =
      StreamData.bind(StreamData.member_of(line_atoms), fn atoms ->
        StreamData.bind(StreamData.integer(0..length(atoms)), fn start ->
          StreamData.map(StreamData.integer(1..3), &Enum.slice(atoms, start, &1))
        end)
      end)

    [atom_list(1, 3), sliced]
    |> StreamData.one_of()
    |> StreamData.map(fn
      [] -> "a"
      atoms -> Enum.join(atoms)
    end)
  end

  defp literal_case do
    gen all(
          line_atoms <- StreamData.list_of(atom_list(0, 16), min_length: 1, max_length: 4),
          pattern <- pattern_from(line_atoms),
          replacement <- StreamData.member_of(@replacements),
          cursor_line <- StreamData.integer(0..(length(line_atoms) - 1)),
          cursor_col <- StreamData.integer(0..40)
        ) do
      {Enum.map(line_atoms, &Enum.join/1), pattern, replacement, {cursor_line, cursor_col}}
    end
  end

  # Every observable search and substitution result for one query.
  defp observe(lines, pattern, replacement, cursor, opts) do
    content = Enum.join(lines, "\n")

    match_at =
      for {line, line_num} <- Enum.with_index(lines), col <- 0..byte_size(line) do
        Search.match_at(content, pattern, {line_num, col}, opts)
      end

    %{
      all: Search.find_all_in_range(lines, pattern, 3, opts),
      match_at: match_at,
      forward: Search.find_next(content, pattern, cursor, :forward, opts),
      backward: Search.find_next(content, pattern, cursor, :backward, opts),
      substitute_all: Search.substitute(content, pattern, replacement, true, opts),
      substitute_first: Search.substitute(content, pattern, replacement, false, opts),
      spans_all:
        Enum.map(lines, &Search.substitute_line_with_spans(&1, pattern, replacement, true, opts)),
      spans_first:
        Enum.map(lines, &Search.substitute_line_with_spans(&1, pattern, replacement, false, opts))
    }
  end

  describe "regex patterns without metacharacters" do
    property "match literal mode and the equivalent grouped regex" do
      check all({lines, pattern, replacement, cursor} <- literal_case(), max_runs: 300) do
        regex_mode = observe(lines, pattern, replacement, cursor, regex: true)

        assert regex_mode == observe(lines, pattern, replacement, cursor, [])

        # A non-capturing group keeps the identical source on the PCRE path.
        assert regex_mode ==
                 observe(lines, "(?:" <> pattern <> ")", replacement, cursor, regex: true)
      end
    end

    test "keep overlapping starts for repeated literals" do
      assert [%Match{col: 0, length: 2}, %Match{col: 1, length: 2}] =
               Search.find_all_in_range(["aaa"], "aa", 0, regex: true)

      assert %Match{col: 1, length: 2} = Search.match_at("aaa", "aa", {0, 1}, regex: true)
      assert {"xa", 1} = Search.substitute("aaa", "aa", "x", true, regex: true)
    end

    test "match multibyte, space, and control bytes exactly" do
      assert [%Match{col: 2, length: 10}] =
               Search.find_all_in_range(["ab café\t日"], " café\t日", 0, regex: true)

      assert [%Match{col: 1, length: 3}] =
               Search.find_all_in_range(["xa\0b"], "a\0b", 0, regex: true)
    end

    test "insert replacement text literally" do
      assert {"f\\0$1&\\0$1&", 2} = Search.substitute("foo", "o", "\\0$1&", true, regex: true)
    end
  end

  describe "regex patterns with metacharacters" do
    test "treat metacharacters as regex syntax" do
      assert [%Match{col: 0, length: 3}] =
               Search.find_all_in_range(["abc"], "a.c", 0, regex: true)

      assert [%Match{col: 0, length: 3}, %Match{col: 1, length: 2}, %Match{col: 2, length: 1}] =
               Search.find_all_in_range(["aaa"], "a+", 0, regex: true)

      assert [%Match{col: 0, length: 1}, %Match{col: 2, length: 1}] =
               Search.find_all_in_range(["a|b"], "a|b", 0, regex: true)
    end

    test "honor escapes" do
      assert [%Match{col: 1, length: 1}] =
               Search.find_all_in_range(["a.b"], "\\.", 0, regex: true)

      assert [%Match{col: 1, length: 1}, %Match{col: 3, length: 1}] =
               Search.find_all_in_range(["a1b2"], "\\d", 0, regex: true)
    end

    test "honor embedded flags" do
      assert [%Match{col: 0, length: 3}] =
               Search.find_all_in_range(["FOO"], "(?i)foo", 0, regex: true)
    end

    test "fall back to the escaped literal when the regex is invalid" do
      assert [%Match{col: 0, length: 4}, %Match{col: 7, length: 4}] =
               Search.find_all_in_range(["foo( x foo("], "foo(", 0, regex: true)

      assert [%Match{col: 1, length: 1}] = Search.find_all_in_range(["a[b"], "[", 0, regex: true)
      assert {"a]b", 1} = Search.substitute("a[b", "[", "]", true, regex: true)
    end

    test "match zero-length and empty regexes without looping" do
      assert [%Match{col: 0, length: 0}] =
               Search.find_all_in_range(["ab"], "(?=a)", 0, regex: true)

      assert [] = Search.find_all_in_range(["ab"], "", 0, regex: true)
      assert {"-a-b-", 3} = Search.substitute("ab", "", "-", true, regex: true)
      assert {"-ab", 1} = Search.substitute("ab", "", "-", false, regex: true)
    end
  end

  describe "regex patterns with query flags" do
    test "fold case when case-insensitive" do
      assert [%Match{col: 0, length: 3}, %Match{col: 4, length: 3}] =
               Search.find_all_in_range(["FOO foo"], "foo", 0, regex: true, case_sensitive: false)
    end

    test "require word boundaries when whole-word" do
      assert [%Match{col: 5, length: 3}] =
               Search.find_all_in_range(["afoo foo"], "foo", 0, regex: true, whole_word: true)
    end
  end
end
