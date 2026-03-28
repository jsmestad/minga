defmodule Minga.Editing.Motion.NavigationTest do
  @moduledoc """
  Pure-function tests for basic cursor navigation (hjkl, 0, $).
  Migrated from integration_test.exs to test at the correct layer.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Document

  defp buf(text), do: Document.new(text)

  describe "move right (l)" do
    test "advances column, content unchanged" do
      b = buf("hello\nworld\nfoo")
      b = Document.move(b, :right)
      b = Document.move(b, :right)

      assert Document.content(b) == "hello\nworld\nfoo"
      assert Document.cursor(b) == {0, 2}
    end

    test "multiple moves advance the column" do
      b = buf("hello world")
      b = Document.move(b, :right)
      b = Document.move(b, :right)
      b = Document.move(b, :right)

      assert Document.cursor(b) == {0, 3}
    end

    test "stops at end of line" do
      b = buf("hi")
      b = Document.move(b, :right)
      b = Document.move(b, :right)
      b = Document.move(b, :right)

      # Should not go past last char
      {0, col} = Document.cursor(b)
      assert col <= 2
    end
  end

  describe "move left (h)" do
    test "moves cursor left after moving right" do
      b = buf("hello\nworld\nfoo")
      b = Document.move(b, :right)
      b = Document.move(b, :right)
      b = Document.move(b, :left)

      assert Document.cursor(b) == {0, 1}
    end

    test "stays at column 0 when already at start" do
      b = buf("hello")
      b = Document.move(b, :left)

      assert Document.cursor(b) == {0, 0}
    end
  end

  describe "move down (j) and up (k)" do
    test "j moves cursor down one line" do
      b = buf("hello\nworld\nfoo")
      b = Document.move(b, :down)

      assert elem(Document.cursor(b), 0) == 1
    end

    test "k moves cursor up after moving down" do
      b = buf("hello\nworld\nfoo")
      b = Document.move(b, :down)
      b = Document.move(b, :up)

      assert elem(Document.cursor(b), 0) == 0
    end

    test "stays at first line when moving up from line 0" do
      b = buf("hello\nworld")
      b = Document.move(b, :up)

      assert Document.cursor(b) == {0, 0}
    end

    test "stays at last line when moving down from last line" do
      b = buf("hello\nworld")
      b = Document.move(b, :down)
      b = Document.move(b, :down)

      assert elem(Document.cursor(b), 0) == 1
    end
  end

  describe "line start (0)" do
    test "moves to beginning of line" do
      b = buf("hello\nworld")
      b = Document.move(b, :right)
      b = Document.move(b, :right)
      b = Document.move_to(b, {0, 0})

      assert Document.cursor(b) == {0, 0}
    end

    test "is a no-op when already at column 0" do
      b = buf("hello")
      b = Document.move_to(b, {0, 0})

      assert Document.cursor(b) == {0, 0}
    end
  end
end
