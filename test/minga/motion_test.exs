defmodule Minga.MotionTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.GapBuffer
  alias Minga.Motion

  # Shorthand: build a buffer and move the cursor to `pos` so the content is right,
  # then call the motion with that pos (we pass pos explicitly anyway).
  defp buf(text), do: GapBuffer.new(text)

  # ── word_forward/2 ─────────────────────────────────────────────────────────

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
      # no next word — stays at max
      assert result == {0, 3}
    end

    test "works on an empty buffer" do
      b = buf("")
      assert Motion.word_forward(b, {0, 0}) == {0, 0}
    end

    test "handles punctuation as a separate token" do
      b = buf("foo.bar")
      # moves past 'foo' word chars to '.', which is different token type
      assert Motion.word_forward(b, {0, 0}) == {0, 3}
    end

    test "moves across multiple lines to find next word" do
      b = buf("a\n\nbc")
      assert Motion.word_forward(b, {0, 0}) == {2, 0}
    end
  end

  # ── word_backward/2 ────────────────────────────────────────────────────────

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

  # ── word_end/2 ─────────────────────────────────────────────────────────────

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
  end

  # ── line_start/2 ───────────────────────────────────────────────────────────

  describe "line_start/2" do
    test "returns col 0 on the same line" do
      b = buf("hello world")
      assert Motion.line_start(b, {0, 5}) == {0, 0}
    end

    test "returns col 0 when already at col 0" do
      b = buf("hello")
      assert Motion.line_start(b, {0, 0}) == {0, 0}
    end

    test "works on second line" do
      b = buf("hello\nworld")
      assert Motion.line_start(b, {1, 4}) == {1, 0}
    end
  end

  # ── line_end/2 ─────────────────────────────────────────────────────────────

  describe "line_end/2" do
    test "returns position of last character on line" do
      b = buf("hello")
      assert Motion.line_end(b, {0, 0}) == {0, 4}
    end

    test "returns {line, 0} for empty line" do
      b = buf("hello\n\nworld")
      assert Motion.line_end(b, {1, 0}) == {1, 0}
    end

    test "works on second line" do
      b = buf("hello\nworld")
      assert Motion.line_end(b, {1, 0}) == {1, 4}
    end

    test "already at line end stays there" do
      b = buf("hello")
      assert Motion.line_end(b, {0, 4}) == {0, 4}
    end
  end

  # ── first_non_blank/2 ──────────────────────────────────────────────────────

  describe "first_non_blank/2" do
    test "returns col of first non-whitespace character" do
      b = buf("  hello")
      assert Motion.first_non_blank(b, {0, 5}) == {0, 2}
    end

    test "returns col 0 when first char is non-blank" do
      b = buf("hello")
      assert Motion.first_non_blank(b, {0, 3}) == {0, 0}
    end

    test "returns col 0 for fully blank line" do
      b = buf("   ")
      assert Motion.first_non_blank(b, {0, 2}) == {0, 0}
    end

    test "handles tabs as whitespace" do
      b = buf("\t\thello")
      assert Motion.first_non_blank(b, {0, 0}) == {0, 2}
    end
  end

  # ── document_start/1 ───────────────────────────────────────────────────────

  describe "document_start/1" do
    test "always returns {0, 0}" do
      b = buf("hello\nworld")
      assert Motion.document_start(b) == {0, 0}
    end

    test "returns {0, 0} on empty buffer" do
      b = buf("")
      assert Motion.document_start(b) == {0, 0}
    end
  end

  # ── document_end/1 ─────────────────────────────────────────────────────────

  describe "document_end/1" do
    test "returns last char of last line" do
      b = buf("hello\nworld")
      assert Motion.document_end(b) == {1, 4}
    end

    test "returns {0, 0} for empty buffer" do
      b = buf("")
      assert Motion.document_end(b) == {0, 0}
    end

    test "returns {0, N} for single-line buffer" do
      b = buf("hello")
      assert Motion.document_end(b) == {0, 4}
    end

    test "handles multiple lines" do
      b = buf("a\nb\nc")
      assert Motion.document_end(b) == {2, 0}
    end
  end

  # ── Edge cases ─────────────────────────────────────────────────────────────

  describe "edge cases" do
    test "word_forward on a single newline" do
      b = buf("\n")
      result = Motion.word_forward(b, {0, 0})
      # newline is the only content; can't advance past max
      assert is_tuple(result)
    end

    test "word_end on single character" do
      b = buf("x")
      assert Motion.word_end(b, {0, 0}) == {0, 0}
    end

    test "line_end on buffer with trailing newline" do
      b = buf("hello\n")
      # Second line is empty
      assert Motion.line_end(b, {1, 0}) == {1, 0}
    end
  end
end
