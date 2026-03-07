defmodule Minga.Motion.VisualLineTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Motion.VisualLine

  describe "visual_down/3" do
    test "moves to next visual row within a wrapped line" do
      # "hello world foo bar" at width 12 wraps to 2 visual rows
      doc = Document.new("hello world foo bar")
      # Cursor at start of first visual row
      new_pos = VisualLine.visual_down(doc, {0, 0}, 12)
      # Should move to the second visual row of the same logical line
      assert {0, col} = new_pos
      assert col > 0
    end

    test "moves to next logical line when on last visual row" do
      doc = Document.new("short\nanother line")
      new_pos = VisualLine.visual_down(doc, {0, 0}, 40)
      assert new_pos == {1, 0}
    end

    test "stays at last line when at end of document" do
      doc = Document.new("only line")
      pos = VisualLine.visual_down(doc, {0, 0}, 40)
      assert {0, _col} = pos
    end

    test "moves within a long wrapped line" do
      # Create a line that wraps to 3+ visual rows
      long = String.duplicate("word ", 20) |> String.trim()
      doc = Document.new(long)
      pos1 = VisualLine.visual_down(doc, {0, 0}, 15)
      # Should still be on line 0 but at a later position
      assert {0, col1} = pos1
      assert col1 > 0
      # Move down again
      pos2 = VisualLine.visual_down(doc, pos1, 15)
      assert {0, col2} = pos2
      assert col2 > col1
    end
  end

  describe "visual_up/3" do
    test "moves to previous visual row within a wrapped line" do
      # "hello world foo bar" at width 12 wraps to 2 visual rows
      doc = Document.new("hello world foo bar")
      # First go down to the second visual row
      down_pos = VisualLine.visual_down(doc, {0, 0}, 12)
      # Then go back up
      up_pos = VisualLine.visual_up(doc, down_pos, 12)
      assert {0, _col} = up_pos
    end

    test "moves to last visual row of previous logical line" do
      doc = Document.new("short\nanother")
      new_pos = VisualLine.visual_up(doc, {1, 0}, 40)
      assert {0, _col} = new_pos
    end

    test "stays at first line when at start of document" do
      doc = Document.new("only line")
      pos = VisualLine.visual_up(doc, {0, 0}, 40)
      assert {0, _col} = pos
    end

    test "moves to last visual row of previous wrapped line" do
      long = String.duplicate("word ", 20) |> String.trim()
      doc = Document.new(long <> "\nshort")
      # Start on line 1
      pos = VisualLine.visual_up(doc, {1, 0}, 15)
      # Should be on line 0, at the last visual row
      assert {0, col} = pos
      assert col > 0
    end
  end

  describe "visual_line_start/3" do
    test "returns start of current visual row in a wrapped line" do
      doc = Document.new("hello world foo bar baz")
      # Move to second visual row first
      down_pos = VisualLine.visual_down(doc, {0, 0}, 12)
      start_pos = VisualLine.visual_line_start(doc, down_pos, 12)
      assert {0, byte_off} = start_pos
      # Should be at the byte offset of the second visual row
      assert byte_off > 0
      # Start should be <= down position
      assert byte_off <= elem(down_pos, 1)
    end

    test "returns column 0 for first visual row" do
      doc = Document.new("hello world")
      pos = VisualLine.visual_line_start(doc, {0, 5}, 40)
      assert pos == {0, 0}
    end
  end

  describe "visual_line_end/3" do
    test "returns end of current visual row in a wrapped line" do
      doc = Document.new("hello world foo bar baz")
      end_pos = VisualLine.visual_line_end(doc, {0, 0}, 12)
      assert {0, byte_off} = end_pos
      # Should be within the first visual row
      assert byte_off < byte_size("hello world foo bar baz")
    end

    test "returns end of line for unwrapped line" do
      doc = Document.new("short")
      pos = VisualLine.visual_line_end(doc, {0, 0}, 40)
      assert {0, byte_off} = pos
      assert byte_off == byte_size("short") - 1
    end
  end

  describe "round-trip consistency" do
    test "down then up returns to same logical line" do
      doc = Document.new("hello world foo bar baz\nsecond line")
      start = {0, 0}
      down = VisualLine.visual_down(doc, start, 12)
      up = VisualLine.visual_up(doc, down, 12)
      assert {0, _col} = up
    end
  end
end
