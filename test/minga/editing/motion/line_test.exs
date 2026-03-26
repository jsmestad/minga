defmodule Minga.Editing.Motion.LineTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Editing.Motion

  defp buf(text), do: Document.new(text)

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

    test "line_end on buffer with trailing newline" do
      b = buf("hello\n")
      assert Motion.line_end(b, {1, 0}) == {1, 0}
    end
  end

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
end
