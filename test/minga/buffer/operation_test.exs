defmodule Minga.Buffer.OperationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Buffer.Operation

  describe "insert_at_cursor/2" do
    test "returns byte-based delta positions for unicode insertions" do
      doc = Document.new("abc") |> Document.move_to({0, 1})

      assert {:edited, new_doc, delta} = Operation.insert_at_cursor(doc, "é")
      assert Document.content(new_doc) == "aébc"
      assert Document.cursor(new_doc) == {0, 3}
      assert delta.start_byte == 1
      assert delta.old_end_byte == 1
      assert delta.new_end_byte == 3
      assert delta.start_position == {0, 1}
      assert delta.old_end_position == {0, 1}
      assert delta.new_end_position == {0, 3}
    end
  end

  describe "replace_range/4" do
    test "returns exclusive old end byte and position for a multi-byte grapheme" do
      doc = Document.new("aébc")

      assert {:edited, new_doc, delta} = Operation.replace_range(doc, {0, 1}, {0, 1}, "X")
      assert Document.content(new_doc) == "aXbc"
      assert Document.cursor(new_doc) == {0, 2}
      assert delta.start_byte == 1
      assert delta.old_end_byte == 3
      assert delta.new_end_byte == 2
      assert delta.start_position == {0, 1}
      assert delta.old_end_position == {0, 3}
      assert delta.new_end_position == {0, 2}
      assert delta.inserted_text == "X"
    end
  end

  describe "replace_lines/4" do
    test "includes the selected line separator when the replacement already provides one" do
      doc = Document.new("zero\none\nthree")

      assert {:edited, new_doc, delta} = Operation.replace_lines(doc, 1, 1, "Z\n")
      assert Document.content(new_doc) == "zero\nZ\nthree"
      assert Document.cursor(new_doc) == {2, 0}
      assert delta.start_byte == 5
      assert delta.old_end_byte == 9
      assert delta.new_end_byte == 7
      assert delta.start_position == {1, 0}
      assert delta.old_end_position == {2, 0}
      assert delta.new_end_position == {2, 0}
      assert delta.inserted_text == "Z\n"
    end

    test "adds one separator when an unselected following line exists" do
      doc = Document.new("zero\none\nthree")

      assert {:edited, new_doc, delta} = Operation.replace_lines(doc, 1, 1, "é")
      assert Document.content(new_doc) == "zero\né\nthree"
      assert Document.cursor(new_doc) == {1, 2}
      assert delta.start_byte == 5
      assert delta.old_end_byte == 9
      assert delta.new_end_byte == 8
      assert delta.new_end_position == {2, 0}
      assert delta.inserted_text == "é\n"
    end

    test "preserves the trailing empty line when it follows the selection" do
      doc = Document.new("zero\none\n")

      assert {:edited, new_doc, delta} = Operation.replace_lines(doc, 1, 1, "Z")
      assert Document.content(new_doc) == "zero\nZ\n"
      assert delta.inserted_text == "Z\n"
    end

    test "normalizes a reversed multiline selection" do
      doc = Document.new("zero\none\ntwo\nthree")

      assert {:edited, new_doc, _delta} = Operation.replace_lines(doc, 2, 1, "Z")
      assert Document.content(new_doc) == "zero\nZ\nthree"
    end

    test "uses the replacement exactly when the selection reaches EOF" do
      doc = Document.new("zero\none")

      assert {:edited, no_newline_doc, no_newline_delta} =
               Operation.replace_lines(doc, 1, 1, "Z")

      assert Document.content(no_newline_doc) == "zero\nZ"
      assert no_newline_delta.inserted_text == "Z"

      assert {:edited, newline_doc, newline_delta} = Operation.replace_lines(doc, 1, 1, "Z\n")
      assert Document.content(newline_doc) == "zero\nZ\n"
      assert newline_delta.inserted_text == "Z\n"
    end
  end

  describe "delete_forward/1" do
    test "returns exclusive old end byte and position for a multi-byte grapheme" do
      doc = Document.new("aébc") |> Document.move_to({0, 1})

      assert {:edited, new_doc, delta} = Operation.delete_forward(doc)
      assert Document.content(new_doc) == "abc"
      assert Document.cursor(new_doc) == {0, 1}
      assert delta.start_byte == 1
      assert delta.old_end_byte == 3
      assert delta.new_end_byte == 1
      assert delta.start_position == {0, 1}
      assert delta.old_end_position == {0, 3}
      assert delta.new_end_position == {0, 1}
      assert delta.inserted_text == ""
    end
  end

  describe "delete_lines/3" do
    test "returns a delta for the actual bytes removed when deleting the final line" do
      doc = Document.new("alpha\nbeta")

      assert {:edited, new_doc, delta} = Operation.delete_lines(doc, 1, 1)
      assert Document.content(new_doc) == "alpha"
      assert delta.start_byte == 5
      assert delta.old_end_byte == 10
      assert delta.new_end_byte == 5
      assert delta.start_position == {0, 5}
      assert delta.old_end_position == {1, 4}
      assert delta.new_end_position == {0, 5}
      assert delta.inserted_text == ""
    end
  end

  describe "clear_line/2" do
    test "returns yanked text and a deletion delta for a non-empty line" do
      doc = Document.new("one\ntwø\nthree")

      assert {:edited, yanked, new_doc, delta} = Operation.clear_line(doc, 1)
      assert yanked == "twø"
      assert Document.content(new_doc) == "one\n\nthree"
      assert delta.start_byte == 4
      assert delta.old_end_byte == 8
      assert delta.new_end_byte == 4
      assert delta.start_position == {1, 0}
      assert delta.old_end_position == {1, 4}
      assert delta.new_end_position == {1, 0}
      assert delta.inserted_text == ""
    end
  end
end
