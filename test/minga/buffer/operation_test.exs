defmodule Minga.Buffer.OperationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document
  alias Minga.Buffer.Operation
  alias Minga.Buffer.UndoPatch

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

  describe "shift_lines/4" do
    property "matches one edit per line, replays its deltas, and undoes in one patch" do
      check all(
              lines <- list_of(shift_line(), min_length: 1, max_length: 12),
              trailing_newline? <- boolean(),
              first <- integer(0..(length(lines) + 1)),
              span <- integer(0..(length(lines) + 1)),
              shift <- member_of([{:indent, "  "}, {:indent, "\t"}, {:dedent, 2}, {:dedent, 4}])
            ) do
        text = Enum.join(lines, "\n") <> if(trailing_newline?, do: "\n", else: "")
        doc = Document.new(text)
        last = first + span

        case Operation.shift_lines(doc, first, last, shift) do
          :unchanged ->
            assert reference_shift(text, first, last, shift) == text

          {:shifted, new_doc, deltas, patch} ->
            shifted = Document.content(new_doc)
            assert shifted == reference_shift(text, first, last, shift)
            assert replay(text, deltas) == shifted
            assert new_doc |> undo_with(patch) |> Document.content() == text
        end
      end
    end

    test "dedent removes one tab, or up to the width in spaces, and nothing else" do
      assert Operation.dedent_bytes("\t\tx", 4) == 1
      assert Operation.dedent_bytes("      x", 4) == 4
      assert Operation.dedent_bytes("  x", 4) == 2
      assert Operation.dedent_bytes(" \tx", 4) == 1
      assert Operation.dedent_bytes("x", 4) == 0
      assert Operation.dedent_bytes("", 4) == 0
    end
  end

  describe "replace_byte_range/4" do
    test "validates the prefix and removed bytes but leaves suffix validation to reconstruction" do
      invalid_prefix = Document.new(<<0xFF, "ab">>)

      assert {:error, :invalid_range} =
               Operation.replace_byte_range(invalid_prefix, {0, 1}, 1, "X")

      invalid_removed = Document.new(<<"a", 0xFF, "b">>)

      assert {:error, :invalid_range} =
               Operation.replace_byte_range(invalid_removed, {0, 1}, 1, "X")

      assert :unchanged = Operation.replace_byte_range(invalid_removed, {0, 1}, 0, "")

      assert_raise ArgumentError, "byte range replacement produced invalid UTF-8 content", fn ->
        Operation.replace_byte_range(invalid_removed, {0, 1}, 0, "X")
      end
    end

    test "replaces a valid span across the gap with byte-accurate positions" do
      doc = Document.new("aé\n日z") |> Document.move_to({1, 0})
      assert {:edited, updated, delta} = Operation.replace_byte_range(doc, {0, 1}, 6, "X")
      assert Document.content(updated) == "aXz"
      assert Document.cursor(updated) == {0, 2}
      assert delta.old_end_byte == 7
      assert delta.old_end_position == {1, 3}
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

  describe "replace_range/4 rejection" do
    test "rejects positions inside a code point, invalid replacements, and malformed edits" do
      for {text, from, to, replacement, reason} <- [
            {"aéb", {0, 2}, {0, 2}, "X", :invalid_utf8},
            {"a😀b", {0, 0}, {0, 3}, "", :invalid_utf8},
            {"x\n字", {1, 1}, {1, 1}, "", :invalid_utf8},
            {"abc", {0, 0}, {0, 0}, <<0xC3>>, :invalid_utf8},
            {"abc", {0, 0}, {0, 0}, nil, :malformed_edit},
            {"abc", {0, -1}, {0, 0}, "x", :malformed_edit},
            {"abc", {0, 0}, {0}, "x", :malformed_edit},
            {"abc", :start, {0, 0}, "x", :malformed_edit}
          ] do
        assert Operation.replace_range(Document.new(text), from, to, replacement) ==
                 {:error, reason}
      end
    end

    test "rejects every edit on a document that is already invalid UTF-8" do
      doc = Document.new("ok" <> <<0xFF>>)
      assert Operation.replace_range(doc, {0, 0}, {0, 0}, "x") == {:error, :invalid_utf8}
    end

    test "a column past a CRLF line end means the line end before the CR" do
      doc = Document.new("ab\r\ncd")

      assert {:edited, new_doc, delta} = Operation.replace_range(doc, {0, 9}, {0, 9}, "Z")
      assert Document.content(new_doc) == "abZcd"
      assert {delta.start_byte, delta.old_end_byte} == {2, 4}
    end

    property "an edit at any byte column either is rejected or leaves valid UTF-8 that its undo patch restores" do
      fragments = ["a", "é", "e\u0301", "字", "😀", "👩\u200D💻", "\n", "\r\n", "ᄀ", "ᅡ"]

      check all(
              text <- map(list_of(member_of(fragments), max_length: 12), &Enum.join/1),
              from <- tuple({integer(0..3), integer(0..16)}),
              to <- tuple({integer(0..3), integer(0..16)}),
              replacement <- one_of([constant(""), member_of(fragments)]),
              max_runs: 1_000
            ) do
        doc = Document.new(text)

        case Operation.replace_range(doc, from, to, replacement) do
          {:edited, new_doc, delta} ->
            edited = Document.content(new_doc)
            assert String.valid?(edited)
            refute edited =~ ~r/\r(?!\n)/u

            assert {:ok, restored} =
                     delta |> UndoPatch.from_delta(doc) |> UndoPatch.apply(new_doc)

            assert Document.content(restored) == text

          {:error, :invalid_utf8} ->
            {_line_starts, _text} = snapshot = Minga.Buffer.Lines.snapshot(doc)
            span = Minga.Buffer.Selection.clamped_characterwise_in(snapshot, from, to).span
            # Only a position inside a code point can make valid inputs invalid.
            refute code_point_boundary?(text, span.start) and
                     code_point_boundary?(text, span.stop)
        end
      end
    end
  end

  @spec code_point_boundary?(String.t(), non_neg_integer()) :: boolean()
  defp code_point_boundary?(text, point) when point >= byte_size(text), do: true

  defp code_point_boundary?(text, point),
    do: Bitwise.band(:binary.at(text, point), 0xC0) != 0x80

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

  describe "delete_range/3" do
    test "reports an empty deletion when moving the cursor to an empty selection" do
      doc = Document.new("abc") |> Document.move_to({0, 1})

      assert {:edited, new_doc, delta} = Operation.delete_range(doc, {0, 3}, {0, 3})
      assert Document.cursor(new_doc) == {0, 3}
      assert_deletion("abc", new_doc, delta, {3, 3}, {{0, 3}, {0, 3}})
      assert :unchanged = Operation.delete_range(new_doc, {0, 3}, {0, 3})
    end
  end

  describe "delete_lines/3" do
    test "reports the removed bytes and old positions independently of the resulting cursor" do
      cases = [
        {"same\nsame\nsame", {1, 2}, "same\nsame", {1, 0}, {5, 10}, {{1, 0}, {2, 0}}},
        {"alpha\nbeta", {1, 2}, "alpha", {0, 0}, {5, 10}, {{0, 5}, {1, 4}}},
        {"a\n", {1, 0}, "a", {0, 0}, {1, 2}, {{0, 1}, {1, 0}}},
        {"a\nb\n", {1, 0}, "a", {0, 0}, {1, 4}, {{0, 1}, {2, 0}}},
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

  defp shift_line do
    gen all(
          indent <- member_of(["", " ", "  ", "    ", "\t", "\t  ", "  \t"]),
          body <- member_of(["", "x", "é ✓", "世界 a", "  "])
        ) do
      indent <> body
    end
  end

  defp reference_shift(text, first, last, shift) do
    text
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.map_join("\n", fn
      {line, index} when index >= first and index <= last -> reference_line(line, shift)
      {line, _index} -> line
    end)
  end

  defp reference_line(line, {:indent, unit}), do: unit <> line

  defp reference_line(line, {:dedent, width}) do
    removed = Operation.dedent_bytes(line, width)
    binary_part(line, removed, byte_size(line) - removed)
  end

  defp replay(text, deltas) do
    Enum.reduce(deltas, text, fn delta, acc ->
      prefix = binary_part(acc, 0, delta.start_byte)
      suffix = binary_part(acc, delta.old_end_byte, byte_size(acc) - delta.old_end_byte)
      prefix <> delta.inserted_text <> suffix
    end)
  end

  defp undo_with(doc, patch) do
    {:ok, undone} = UndoPatch.apply(patch, doc)
    undone
  end
end
