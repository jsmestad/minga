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
end
