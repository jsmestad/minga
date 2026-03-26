defmodule Minga.Editing.Motion.CharTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Editing.Motion

  defp buf(text), do: Document.new(text)

  describe "find_char_forward/3" do
    test "finds character on current line" do
      b = buf("hello world")
      assert Motion.find_char_forward(b, {0, 0}, "o") == {0, 4}
    end

    test "returns original position when char not found" do
      b = buf("hello")
      assert Motion.find_char_forward(b, {0, 0}, "z") == {0, 0}
    end
  end

  describe "find_char_backward/3" do
    test "finds character backward on current line" do
      b = buf("hello world")
      assert Motion.find_char_backward(b, {0, 7}, "o") == {0, 4}
    end

    test "returns original position when char not found" do
      b = buf("hello")
      assert Motion.find_char_backward(b, {0, 4}, "z") == {0, 4}
    end
  end

  describe "till_char_forward/3" do
    test "moves to one before the char" do
      b = buf("hello world")
      assert Motion.till_char_forward(b, {0, 0}, "o") == {0, 3}
    end

    test "returns original position when char not found" do
      b = buf("hello")
      assert Motion.till_char_forward(b, {0, 0}, "z") == {0, 0}
    end
  end

  describe "till_char_backward/3" do
    test "moves to one after the char" do
      b = buf("hello world")
      assert Motion.till_char_backward(b, {0, 7}, "o") == {0, 5}
    end

    test "returns original position when char not found" do
      b = buf("hello")
      assert Motion.till_char_backward(b, {0, 4}, "z") == {0, 4}
    end
  end

  describe "match_bracket/2" do
    test "jumps from ( to matching )" do
      b = buf("(hello)")
      assert Motion.match_bracket(b, {0, 0}) == {0, 6}
    end

    test "jumps from ) to matching (" do
      b = buf("(hello)")
      assert Motion.match_bracket(b, {0, 6}) == {0, 0}
    end

    test "handles nested brackets" do
      b = buf("(a (b) c)")
      assert Motion.match_bracket(b, {0, 0}) == {0, 8}
      assert Motion.match_bracket(b, {0, 3}) == {0, 5}
    end

    test "jumps from < to matching >" do
      b = buf("<div>")
      assert Motion.match_bracket(b, {0, 0}) == {0, 4}
    end

    test "jumps from > to matching <" do
      b = buf("<div>")
      assert Motion.match_bracket(b, {0, 4}) == {0, 0}
    end

    test "handles nested angle brackets" do
      b = buf("<a <b>>")
      assert Motion.match_bracket(b, {0, 0}) == {0, 6}
      assert Motion.match_bracket(b, {0, 3}) == {0, 5}
    end

    test "returns original position when no bracket found" do
      b = buf("hello world")
      assert Motion.match_bracket(b, {0, 0}) == {0, 0}
    end

    test "returns original position on unmatched bracket" do
      b = buf("(hello")
      assert Motion.match_bracket(b, {0, 0}) == {0, 0}
    end

    test "works across multiple lines" do
      b = buf("(\nhello\n)")
      assert Motion.match_bracket(b, {0, 0}) == {2, 0}
    end
  end
end
