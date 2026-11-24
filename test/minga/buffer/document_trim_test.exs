defmodule Minga.Buffer.DocumentTrimTest do
  @moduledoc "Tests for `Document.trim_leading_lines/2`."

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document

  describe "trim_leading_lines/2" do
    test "trimming zero lines returns the document unchanged" do
      doc = Document.new("alpha\nbeta\ngamma")
      assert Document.trim_leading_lines(doc, 0) == doc
    end

    test "trimming all lines returns an empty document" do
      doc = Document.new("alpha\nbeta\ngamma")
      result = Document.trim_leading_lines(doc, 3)
      assert Document.content(result) == ""
      assert Document.line_count(result) == 1
      assert Document.cursor(result) == {0, 0}
    end

    test "trimming more than line_count returns an empty document" do
      doc = Document.new("alpha\nbeta")
      result = Document.trim_leading_lines(doc, 100)
      assert Document.content(result) == ""
    end

    test "trims the first line from a multi-line document" do
      doc = Document.new("first\nsecond\nthird")
      result = Document.trim_leading_lines(doc, 1)
      assert Document.content(result) == "second\nthird"
      assert Document.line_count(result) == 2
    end

    test "trims multiple lines from the front" do
      doc = Document.new("a\nb\nc\nd\ne")
      result = Document.trim_leading_lines(doc, 3)
      assert Document.content(result) == "d\ne"
      assert Document.line_count(result) == 2
    end

    test "preserves the cursor position when it is after the trim range" do
      doc = Document.new("first\nsecond\nthird")
      # Place cursor at end (line 2)
      doc = Document.move_to(doc, {2, 5})
      result = Document.trim_leading_lines(doc, 1)
      assert Document.cursor(result) == {1, 5}
    end

    test "cursor lands at {0, 0} when it was within the trimmed prefix" do
      doc = Document.new("first\nsecond\nthird")
      # Cursor starts at {0, 0} which is in the first line
      result = Document.trim_leading_lines(doc, 2)
      assert Document.cursor(result) == {0, 0}
      assert Document.content(result) == "third"
    end

    test "line_offsets are correct after trim" do
      doc = Document.new("aaaa\nbb\nccccc\ndd")
      result = Document.trim_leading_lines(doc, 2)
      assert Document.content(result) == "ccccc\ndd"
      assert Document.line_count(result) == 2
      # Verify we can still do operations using the line index
      assert Document.line_at(result, 0) == "ccccc"
      assert Document.line_at(result, 1) == "dd"
    end

    test "handles trailing newline (empty last line)" do
      doc = Document.new("first\nsecond\n")
      result = Document.trim_leading_lines(doc, 1)
      assert Document.content(result) == "second\n"
      assert Document.line_count(result) == 2
    end

    test "insert_text works correctly after trim" do
      doc = Document.new("aaa\nbbb\nccc\n")
      # Cursor at {0, 0}, move to end
      doc = Document.move_to(doc, {3, 0})
      doc = Document.insert_text(doc, "new entry\n")
      assert Document.line_count(doc) == 5

      result = Document.trim_leading_lines(doc, 2)
      assert Document.content(result) == "ccc\nnew entry\n"
      assert Document.line_count(result) == 3

      # Can still insert after trim
      result = Document.insert_text(result, "another\n")
      assert Document.content(result) == "ccc\nnew entry\nanother\n"
    end

    test "handles pending line_offsets from prior insert_text" do
      # insert_text leaves offsets in a pending state; trim must resolve them
      doc = Document.new("alpha\nbeta\n")
      doc = Document.move_to(doc, {2, 0})
      doc = Document.insert_text(doc, "gamma\n")
      # offsets are pending after insert
      result = Document.trim_leading_lines(doc, 1)
      assert Document.content(result) == "beta\ngamma\n"
      assert Document.line_count(result) == 3
      assert Document.line_at(result, 0) == "beta"
      assert Document.line_at(result, 1) == "gamma"
    end

    test "handles single-line document" do
      doc = Document.new("only line")
      # Trimming 1 from a 1-line doc clears it
      result = Document.trim_leading_lines(doc, 1)
      assert Document.content(result) == ""
    end

    test "content_byte_size is correct after trim" do
      doc = Document.new("abcde\nfghij\nklmno")
      result = Document.trim_leading_lines(doc, 1)
      assert Document.content_byte_size(result) == byte_size("fghij\nklmno")
    end

    property "trim then content equals dropping lines from the original" do
      check all(
              lines <-
                list_of(string(:alphanumeric, min_length: 1), min_length: 2, max_length: 20),
              trim_count <- integer(0..length(lines))
            ) do
        content = Enum.join(lines, "\n")
        doc = Document.new(content)
        result = Document.trim_leading_lines(doc, trim_count)

        expected =
          lines
          |> Enum.drop(trim_count)
          |> Enum.join("\n")

        assert Document.content(result) == expected
        assert Document.line_count(result) == max(1, length(lines) - trim_count)
      end
    end
  end
end
