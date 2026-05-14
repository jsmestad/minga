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
    test "returns original position when no parser match is available" do
      b = buf("(hello)")
      assert Motion.match_bracket(b, {0, 0}) == {0, 0}
    end
  end
end
