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

    test "reports byte positions for a multi-line range on a document with pending line shifts" do
      doc =
        "one\ntwo\nthree"
        |> Document.new()
        |> Document.move_to({0, 3})
        |> Document.insert_text("!")

      assert {:pending, _starts, 0, 1} = doc.line_offsets
      assert {:edited, new_doc, delta} = Operation.replace_range(doc, {1, 1}, {2, 1}, "X")
      assert Document.content(new_doc) == "one!\ntXree"
      assert Document.cursor(new_doc) == {1, 2}
      assert delta.start_byte == 6
      assert delta.old_end_byte == 11
      assert delta.new_end_byte == 7
      assert delta.start_position == {1, 1}
      assert delta.old_end_position == {2, 2}
      assert delta.new_end_position == {1, 2}
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
    test "reports the removed bytes and old positions for a grapheme or CRLF at the gap" do
      cases = [
        {"xe\u0301y", "xy", 4, {0, 4}},
        {"a\r\nb", "ab", 3, {1, 0}}
      ]

      for {original, expected, old_end, old_end_position} <- cases do
        doc = original |> Document.new() |> Document.move_to({0, 1})

        assert {:edited, new_doc, delta} = Operation.delete_forward(doc)
        assert Document.content(new_doc) == expected
        assert Document.cursor(new_doc) == {0, 1}
        assert_deletion(original, new_doc, delta, {1, old_end}, {{0, 1}, old_end_position})
      end
    end

    test "joins lines when deleting a CRLF and keeps later positions on the joined index" do
      doc = "a\r\nb\nc" |> Document.new() |> Document.move_to({0, 1})

      assert {:edited, new_doc, delta} = Operation.delete_forward(doc)
      assert Document.content(new_doc) == "ab\nc"
      assert Document.line_count(new_doc) == 2
      assert Document.cursor(new_doc) == {0, 1}
      assert {delta.start_byte, delta.old_end_byte, delta.new_end_byte} == {1, 3, 1}
      assert {delta.start_position, delta.old_end_position} == {{0, 1}, {1, 0}}
      assert Document.offset_to_position(new_doc, 2) == {0, 2}
      assert Document.offset_to_position(new_doc, 3) == {1, 0}
      assert Document.line_at(new_doc, 1) == "c"
    end
  end

  describe "backspace/1" do
    test "joins lines when deleting a CRLF and keeps later positions on the joined index" do
      doc = "a\r\nb\nc" |> Document.new() |> Document.move_to({1, 0})

      assert {:edited, new_doc, delta} = Operation.backspace(doc)
      assert Document.content(new_doc) == "ab\nc"
      assert Document.line_count(new_doc) == 2
      assert Document.cursor(new_doc) == {0, 1}
      assert {delta.start_byte, delta.old_end_byte, delta.new_end_byte} == {1, 3, 1}
      assert {delta.start_position, delta.old_end_position} == {{0, 1}, {1, 0}}
      assert Document.offset_to_position(new_doc, 3) == {1, 0}
      assert Document.position_to_offset(new_doc, {1, 1}) == 4
      assert Document.line_at(new_doc, 1) == "c"
    end
  end

  describe "delete_lines/3" do
    test "reports the removed bytes and old positions independently of the resulting cursor" do
      cases = [
        {"same\nsame\nsame", {1, 2}, "same\nsame", {1, 0}, {5, 10}, {{1, 0}, {2, 0}}},
        {"alpha\nbeta", {1, 2}, "alpha", {0, 0}, {5, 10}, {{0, 5}, {1, 4}}},
        {"a\n", {1, 0}, "a", {0, 0}, {1, 2}, {{0, 1}, {1, 0}}},
        {"a\r\nb", {1, 0}, "a\r", {0, 0}, {2, 4}, {{0, 2}, {1, 1}}},
        {"élan", {0, 2}, "", {0, 0}, {0, 5}, {{0, 0}, {0, 5}}}
      ]

      for {original, {line, _col} = gap, expected, cursor, offsets, positions} <- cases do
        doc = original |> Document.new() |> Document.move_to(gap)

        assert {:edited, new_doc, delta} = Operation.delete_lines(doc, line, line)
        assert Document.content(new_doc) == expected
        assert Document.cursor(new_doc) == cursor
        assert_deletion(original, new_doc, delta, offsets, positions)
      end
    end

    test "deleting the only line of an already empty document is unchanged" do
      assert :unchanged = Operation.delete_lines(Document.new(""), 0, 0)
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

  defp assert_deletion(original, new_doc, delta, {start, stop}, {start_position, stop_position}) do
    assert {delta.start_byte, delta.old_end_byte, delta.new_end_byte} == {start, stop, start}

    assert {delta.start_position, delta.old_end_position, delta.new_end_position} ==
             {start_position, stop_position, start_position}

    assert delta.inserted_text == ""

    replayed =
      binary_part(original, 0, delta.start_byte) <>
        delta.inserted_text <>
        binary_part(original, delta.old_end_byte, byte_size(original) - delta.old_end_byte)

    assert replayed == Document.content(new_doc)
  end
end
