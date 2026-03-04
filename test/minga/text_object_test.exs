defmodule Minga.TextObjectTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.TextObject

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp buf(text), do: Document.new(text)

  # ── inner_word/2 ──────────────────────────────────────────────────────────────

  describe "inner_word/2 (iw)" do
    test "selects a word when cursor is at start of word" do
      b = buf("hello world")
      assert {{0, 0}, {0, 4}} = TextObject.inner_word(b, {0, 0})
    end

    test "selects a word when cursor is in the middle of a word" do
      b = buf("hello world")
      assert {{0, 0}, {0, 4}} = TextObject.inner_word(b, {0, 2})
    end

    test "selects a word when cursor is at the end of a word" do
      b = buf("hello world")
      assert {{0, 0}, {0, 4}} = TextObject.inner_word(b, {0, 4})
    end

    test "selects the second word when cursor is on it" do
      b = buf("hello world")
      assert {{0, 6}, {0, 10}} = TextObject.inner_word(b, {0, 6})
    end

    test "selects a whitespace run when cursor is on whitespace" do
      b = buf("hello   world")
      assert {{0, 5}, {0, 7}} = TextObject.inner_word(b, {0, 6})
    end

    test "selects a single character word" do
      b = buf("a b c")
      assert {{0, 0}, {0, 0}} = TextObject.inner_word(b, {0, 0})
    end

    test "works on the correct line in a multi-line buffer" do
      b = buf("foo\nhello world\nbar")
      assert {{1, 6}, {1, 10}} = TextObject.inner_word(b, {1, 8})
    end

    test "handles empty line" do
      b = buf("foo\n\nbar")
      assert {{1, 0}, {1, 0}} = TextObject.inner_word(b, {1, 0})
    end

    test "selects underscore-containing identifier" do
      b = buf("foo_bar baz")
      assert {{0, 0}, {0, 6}} = TextObject.inner_word(b, {0, 3})
    end
  end

  # ── a_word/2 ──────────────────────────────────────────────────────────────────

  describe "a_word/2 (aw)" do
    test "selects a word plus trailing space" do
      b = buf("hello world")
      assert {{0, 0}, {0, 5}} = TextObject.a_word(b, {0, 2})
    end

    test "selects a word plus leading space when at end of line" do
      b = buf("hello world")
      # 'world' has no trailing space; should consume leading space
      assert {{0, 5}, {0, 10}} = TextObject.a_word(b, {0, 8})
    end

    test "selects word alone when no surrounding whitespace" do
      b = buf("hello")
      assert {{0, 0}, {0, 4}} = TextObject.a_word(b, {0, 2})
    end

    test "selects all trailing spaces when word is followed by multiple spaces" do
      b = buf("hi   there")
      assert {{0, 0}, {0, 4}} = TextObject.a_word(b, {0, 1})
    end
  end

  # ── inner_quotes/3 ────────────────────────────────────────────────────────────

  describe "inner_quotes/3 (i\")" do
    test "selects content between double quotes" do
      b = buf(~s(say "hello world" now))
      # cursor inside the quotes
      assert {{0, 5}, {0, 15}} = TextObject.inner_quotes(b, {0, 8}, "\"")
    end

    test "selects content between single quotes" do
      b = buf("say 'hello' now")
      assert {{0, 5}, {0, 9}} = TextObject.inner_quotes(b, {0, 7}, "'")
    end

    test "returns nil when cursor is outside any quote pair" do
      b = buf(~s(no "quotes" here))
      # cursor before the first quote
      assert nil == TextObject.inner_quotes(b, {0, 0}, "\"")
    end

    test "handles cursor on the opening quote" do
      b = buf(~s("hello"))
      assert {{0, 1}, {0, 5}} = TextObject.inner_quotes(b, {0, 0}, "\"")
    end

    test "handles cursor on the closing quote" do
      b = buf(~s("hello"))
      assert {{0, 1}, {0, 5}} = TextObject.inner_quotes(b, {0, 6}, "\"")
    end

    test "handles empty quoted string" do
      b = buf(~s(""))
      result = TextObject.inner_quotes(b, {0, 1}, "\"")
      # Empty content — start > end (zero-width range)
      assert {{0, 1}, {0, 0}} = result
    end

    test "selects innermost pair with multiple quote pairs on line" do
      b = buf(~s("outer" and "inner"))
      # cursor on 'i' in "inner" — the second quote pair is at positions 12..18
      # so inner content is positions 13..17
      assert {{0, 13}, {0, 17}} = TextObject.inner_quotes(b, {0, 13}, "\"")
    end
  end

  # ── a_quotes/3 ────────────────────────────────────────────────────────────────

  describe "a_quotes/3 (a\")" do
    test "selects content including double quotes" do
      b = buf(~s(say "hello" now))
      assert {{0, 4}, {0, 10}} = TextObject.a_quotes(b, {0, 7}, "\"")
    end

    test "selects content including single quotes" do
      b = buf("say 'hi' now")
      assert {{0, 4}, {0, 7}} = TextObject.a_quotes(b, {0, 6}, "'")
    end

    test "returns nil when not inside quotes" do
      b = buf("no quotes here")
      assert nil == TextObject.a_quotes(b, {0, 0}, "\"")
    end
  end

  # ── inner_parens/4 ────────────────────────────────────────────────────────────

  describe "inner_parens/4 (i()" do
    test "selects content inside parentheses" do
      b = buf("foo(bar baz)qux")
      # cursor on 'b' in 'bar'
      assert {{0, 4}, {0, 10}} = TextObject.inner_parens(b, {0, 5}, "(", ")")
    end

    test "selects content inside curly braces" do
      b = buf("fn { body }")
      assert {{0, 4}, {0, 9}} = TextObject.inner_parens(b, {0, 6}, "{", "}")
    end

    test "selects content inside square brackets" do
      b = buf("[1, 2, 3]")
      assert {{0, 1}, {0, 7}} = TextObject.inner_parens(b, {0, 3}, "[", "]")
    end

    test "handles nested parens — selects from outermost enclosing pair" do
      b = buf("(a (b) c)")
      # cursor on 'b' inside inner parens
      # inner_parens should return the inner pair: (b)
      result = TextObject.inner_parens(b, {0, 4}, "(", ")")
      # The innermost pair around 'b' is at positions 3..5
      assert {{0, 4}, {0, 4}} = result
    end

    test "handles deeply nested parens" do
      b = buf("((hello))")
      # cursor on 'h'
      result = TextObject.inner_parens(b, {0, 2}, "(", ")")
      # innermost pair is positions 1..7, inner content is 2..6
      assert {{0, 2}, {0, 6}} = result
    end

    test "returns nil when not inside parens" do
      b = buf("no parens here")
      assert nil == TextObject.inner_parens(b, {0, 5}, "(", ")")
    end

    test "handles empty parens" do
      b = buf("()")
      result = TextObject.inner_parens(b, {0, 0}, "(", ")")
      # inner content is empty — start is after open, end is before close
      assert nil == result
    end

    test "works across multiple lines" do
      b = buf("foo(\n  bar\n)")
      # Line 0: "foo(" — `(` is at {0,3}
      # Line 1: "  bar" — 5 chars (indices 0-4)
      # Line 2: ")"     — `)` is at {2,0}
      # inner start: advance from {0,3} → {1,0} (start of next line)
      # inner end: retreat from {2,0} → {1,4} (last char of "  bar")
      result = TextObject.inner_parens(b, {1, 2}, "(", ")")
      assert {{1, 0}, {1, 4}} = result
    end
  end

  # ── a_parens/4 ───────────────────────────────────────────────────────────────

  describe "a_parens/4 (a()" do
    test "selects content including parentheses" do
      b = buf("foo(bar)qux")
      assert {{0, 3}, {0, 7}} = TextObject.a_parens(b, {0, 5}, "(", ")")
    end

    test "selects content including curly braces" do
      b = buf("fn { body } end")
      assert {{0, 3}, {0, 10}} = TextObject.a_parens(b, {0, 6}, "{", "}")
    end

    test "returns nil when not inside delimiters" do
      b = buf("no brackets here")
      assert nil == TextObject.a_parens(b, {0, 0}, "[", "]")
    end

    test "handles nested parens — a_parens selects the innermost pair" do
      b = buf("(a (b) c)")
      # cursor on 'b'
      result = TextObject.a_parens(b, {0, 4}, "(", ")")
      # The innermost enclosing pair for 'b' is (b) at positions 3..5
      assert {{0, 3}, {0, 5}} = result
    end
  end
end
