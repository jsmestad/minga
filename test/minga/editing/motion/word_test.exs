defmodule Minga.Editing.Motion.WordTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Editing.Motion

  defp buf(text), do: Document.new(text)

  describe "forward word starts" do
    test "uses the whole grapheme when the byte column falls inside it" do
      b = buf("ae\u0301!b c")

      for col <- [2, 3] do
        assert Motion.word_forward(b, {0, col}) == {0, 4}
        assert Motion.word_forward_big(b, {0, col}) == {0, 7}
      end
    end

    test "keeps byte columns aligned after a malformed byte before the cursor" do
      b = buf(<<0xFF, "a b">>)

      assert Motion.word_forward(b, {0, 1}) == {0, 3}
      assert Motion.word_forward_big(b, {0, 1}) == {0, 3}
    end

    test "finds the first boundary before a long suffix on either line" do
      suffix = String.duplicate("👩‍💻", 10_000)
      same_line = buf("a b " <> suffix)
      next_line = buf("a\n  b " <> suffix)

      for forward <- [&Motion.word_forward/2, &Motion.word_forward_big/2] do
        assert forward.(same_line, {0, 0}) == {0, 2}
        assert forward.(next_line, {0, 0}) == {1, 2}
      end
    end

    test "stops at a punctuation run for w but skips it within a WORD for W" do
      b = buf("foo::bar baz")

      assert Motion.word_forward(b, {0, 0}) == {0, 3}
      assert Motion.word_forward(b, {0, 3}) == {0, 5}
      assert Motion.word_forward_big(b, {0, 0}) == {0, 9}
      assert Motion.word_forward_big(b, {0, 3}) == {0, 9}
    end

    test "clamps a column past the end of a line to its last grapheme" do
      b = buf("ae\u0301\n\n  next")

      for forward <- [&Motion.word_forward/2, &Motion.word_forward_big/2] do
        assert forward.(b, {0, 40}) == {2, 2}
        assert forward.(b, {3, 40}) == {3, 40}
      end
    end

    test "keeps an empty start but falls back to the last grapheme from a nonempty start" do
      b = buf("word\n\n\t \u0301\n\n")

      for forward <- [&Motion.word_forward/2, &Motion.word_forward_big/2] do
        assert forward.(b, {1, 0}) == {1, 0}
        assert forward.(b, {0, 0}) == {2, 1}
        assert forward.(b, {2, 0}) == {2, 1}
      end
    end
  end

  describe "word_forward/2" do
    test "moves from start of word to start of next word" do
      b = buf("hello world")
      assert Motion.word_forward(b, {0, 0}) == {0, 6}
    end

    test "moves from middle of word to start of next word" do
      b = buf("hello world")
      assert Motion.word_forward(b, {0, 2}) == {0, 6}
    end

    test "skips multiple spaces between words" do
      b = buf("foo   bar")
      assert Motion.word_forward(b, {0, 0}) == {0, 6}
    end

    test "moves from whitespace to start of next word" do
      b = buf("hello world")
      assert Motion.word_forward(b, {0, 5}) == {0, 6}
    end

    test "moves across lines" do
      b = buf("hello\nworld")
      assert Motion.word_forward(b, {0, 0}) == {1, 0}
    end

    test "stays at last position when already at end of buffer" do
      b = buf("hello")
      result = Motion.word_forward(b, {0, 4})
      assert result == {0, 4}
    end

    test "works on a single-word buffer" do
      b = buf("word")
      result = Motion.word_forward(b, {0, 0})
      assert result == {0, 3}
    end

    test "works on an empty buffer" do
      b = buf("")
      assert Motion.word_forward(b, {0, 0}) == {0, 0}
    end

    test "handles punctuation as a separate token" do
      b = buf("foo.bar")
      assert Motion.word_forward(b, {0, 0}) == {0, 3}
    end

    test "treats Unicode letters as word characters" do
      b = buf("éclair café")
      assert Motion.word_forward(b, {0, 0}) == {0, 8}
    end

    test "moves across multiple lines to find next word" do
      b = buf("a\n\nbc")
      assert Motion.word_forward(b, {0, 0}) == {2, 0}
    end

    test "word_forward on a single newline" do
      b = buf("\n")
      result = Motion.word_forward(b, {0, 0})
      assert is_tuple(result)
    end
  end

  describe "word_backward/2" do
    test "moves from end of word to start of same word" do
      b = buf("hello world")
      assert Motion.word_backward(b, {0, 10}) == {0, 6}
    end

    test "moves from start of second word to start of first word" do
      b = buf("hello world")
      assert Motion.word_backward(b, {0, 6}) == {0, 0}
    end

    test "stays at {0,0} when already at start of buffer" do
      b = buf("hello")
      assert Motion.word_backward(b, {0, 0}) == {0, 0}
    end

    test "moves across a newline boundary" do
      b = buf("hello\nworld")
      assert Motion.word_backward(b, {1, 0}) == {0, 0}
    end

    test "works on an empty buffer" do
      b = buf("")
      assert Motion.word_backward(b, {0, 0}) == {0, 0}
    end

    test "skips whitespace when moving backward" do
      b = buf("foo   bar")
      assert Motion.word_backward(b, {0, 8}) == {0, 6}
    end

    test "moves backward to Unicode word starts" do
      b = buf("éclair café")
      assert Motion.word_backward(b, {0, 11}) == {0, 8}
    end
  end

  describe "word_end/2" do
    test "moves to end of current word" do
      b = buf("hello world")
      assert Motion.word_end(b, {0, 0}) == {0, 4}
    end

    test "moves to end of next word when at end of current" do
      b = buf("hello world")
      assert Motion.word_end(b, {0, 4}) == {0, 10}
    end

    test "skips whitespace to reach next word end" do
      b = buf("foo   bar")
      assert Motion.word_end(b, {0, 2}) == {0, 8}
    end

    test "stays at last position when at end of buffer" do
      b = buf("hello")
      assert Motion.word_end(b, {0, 4}) == {0, 4}
    end

    test "works on empty buffer" do
      b = buf("")
      assert Motion.word_end(b, {0, 0}) == {0, 0}
    end

    test "works across lines" do
      b = buf("hi\nworld")
      assert Motion.word_end(b, {0, 1}) == {1, 4}
    end

    test "moves to the end of Unicode words" do
      b = buf("éclair café")
      assert Motion.word_end(b, {0, 0}) == {0, 6}
    end

    test "word_end on single character" do
      b = buf("x")
      assert Motion.word_end(b, {0, 0}) == {0, 0}
    end
  end

  describe "word_forward_big/2" do
    test "moves past punctuation without stopping" do
      b = buf("foo.bar baz")
      assert Motion.word_forward_big(b, {0, 0}) == {0, 8}
    end

    test "moves across lines" do
      b = buf("foo.bar\nbaz")
      assert Motion.word_forward_big(b, {0, 0}) == {1, 0}
    end

    test "skips multiple spaces" do
      b = buf("abc   def")
      assert Motion.word_forward_big(b, {0, 0}) == {0, 6}
    end

    test "stays at end of buffer when no next WORD" do
      b = buf("hello")
      assert Motion.word_forward_big(b, {0, 4}) == {0, 4}
    end

    test "works on empty buffer" do
      b = buf("")
      assert Motion.word_forward_big(b, {0, 0}) == {0, 0}
    end

    test "moves from whitespace to start of next WORD" do
      b = buf("foo bar")
      assert Motion.word_forward_big(b, {0, 3}) == {0, 4}
    end

    test "moves across blank lines" do
      b = buf("abc\n\ndef")
      assert Motion.word_forward_big(b, {0, 0}) == {2, 0}
    end
  end

  describe "word_backward_big/2" do
    test "moves past punctuation to start of WORD" do
      b = buf("foo.bar baz")
      assert Motion.word_backward_big(b, {0, 8}) == {0, 0}
    end

    test "moves across lines" do
      b = buf("hello\nworld")
      assert Motion.word_backward_big(b, {1, 0}) == {0, 0}
    end

    test "stays at {0,0} when already at start" do
      b = buf("hello")
      assert Motion.word_backward_big(b, {0, 0}) == {0, 0}
    end

    test "works on empty buffer" do
      b = buf("")
      assert Motion.word_backward_big(b, {0, 0}) == {0, 0}
    end

    test "skips whitespace backward to find WORD start" do
      b = buf("foo   bar")
      assert Motion.word_backward_big(b, {0, 8}) == {0, 6}
    end

    test "treats punctuation as part of WORD" do
      b = buf("foo.bar baz.qux")
      assert Motion.word_backward_big(b, {0, 10}) == {0, 8}
    end
  end

  describe "word_end_big/2" do
    test "moves to end of WORD including punctuation" do
      b = buf("foo.bar baz")
      assert Motion.word_end_big(b, {0, 0}) == {0, 6}
    end

    test "moves across lines" do
      b = buf("hi\nfoo.bar")
      assert Motion.word_end_big(b, {0, 1}) == {1, 6}
    end

    test "stays at end of buffer" do
      b = buf("hello")
      assert Motion.word_end_big(b, {0, 4}) == {0, 4}
    end

    test "works on empty buffer" do
      b = buf("")
      assert Motion.word_end_big(b, {0, 0}) == {0, 0}
    end

    test "skips whitespace to reach next WORD end" do
      b = buf("abc   def.ghi")
      assert Motion.word_end_big(b, {0, 2}) == {0, 12}
    end

    test "single character" do
      b = buf("x")
      assert Motion.word_end_big(b, {0, 0}) == {0, 0}
    end
  end
end
