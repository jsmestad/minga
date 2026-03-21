defmodule Minga.Motion.WordTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Motion

  defp buf(text), do: Document.new(text)

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
