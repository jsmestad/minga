defmodule Minga.Motion.DocumentTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.GapBuffer
  alias Minga.Motion

  defp buf(text), do: GapBuffer.new(text)

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

  describe "paragraph_forward/2" do
    test "moves to next blank line" do
      b = buf("hello\nworld\n\nfoo")
      assert Motion.paragraph_forward(b, {0, 0}) == {2, 0}
    end

    test "clamps to last line when no blank line found" do
      b = buf("hello\nworld")
      result = Motion.paragraph_forward(b, {0, 0})
      assert elem(result, 0) == 1
    end
  end

  describe "paragraph_backward/2" do
    test "moves to previous blank line" do
      b = buf("hello\nworld\n\nfoo")
      assert Motion.paragraph_backward(b, {3, 0}) == {2, 0}
    end

    test "clamps to {0, 0} when no blank line before" do
      b = buf("hello\nworld")
      assert Motion.paragraph_backward(b, {1, 0}) == {0, 0}
    end
  end
end
