defmodule Minga.Buffer.UndoPatchTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document
  alias Minga.Buffer.Operation
  alias Minga.Buffer.UndoPatch

  defp doc(text), do: Document.new(text)

  describe "from_delta/2" do
    test "captures insertion patches" do
      old_doc = doc("hello")
      {:edited, new_doc, delta} = Operation.insert_at_cursor(old_doc, "X")

      patch = UndoPatch.from_delta(delta, old_doc)

      assert patch.start_byte == 0
      assert patch.old_text == ""
      assert patch.new_text == "X"
      assert UndoPatch.apply(patch, new_doc) |> Document.content() == "hello"
    end

    test "captures deletion patches" do
      old_doc = doc("héllo") |> Document.move_to({0, 3})
      {:edited, new_doc, delta} = Operation.backspace(old_doc)

      patch = UndoPatch.from_delta(delta, old_doc)

      assert patch.old_text == "é"
      assert patch.new_text == ""
      assert UndoPatch.apply(patch, new_doc) |> Document.content() == "héllo"
    end

    test "captures replacement patches" do
      old_doc = doc("one two three")
      {:edited, new_doc, delta} = Operation.replace_range(old_doc, {0, 4}, {0, 6}, "TWO")

      patch = UndoPatch.from_delta(delta, old_doc)

      assert patch.old_text == "two"
      assert patch.new_text == "TWO"
      assert UndoPatch.apply(patch, new_doc) |> Document.content() == "one two three"
    end

    test "captures deleted text across the cursor gap" do
      old_doc = doc("abc def") |> Document.move_to({0, 4})
      {:edited, new_doc, delta} = Operation.replace_range(old_doc, {0, 2}, {0, 4}, "X")

      patch = UndoPatch.from_delta(delta, old_doc)

      assert patch.old_text == "c d"
      assert patch.new_text == "X"
      assert UndoPatch.apply(patch, new_doc) |> Document.content() == "abc def"
    end

    test "owns deleted slices instead of retaining the original large document binary" do
      prefix = String.duplicate("a", 1_000_000)
      old_doc = doc(prefix <> "TARGET")

      {:edited, _new_doc, delta} =
        Operation.replace_range(old_doc, {0, byte_size(prefix)}, {0, byte_size(prefix) + 5}, "x")

      patch = UndoPatch.from_delta(delta, old_doc)

      assert patch.old_text == "TARGET"
      assert :binary.referenced_byte_size(patch.old_text) == byte_size(patch.old_text)
    end
  end

  describe "invert/2" do
    test "inverted patch reapplies the original edit" do
      old_doc = doc("hello")
      {:edited, new_doc, delta} = Operation.insert_at_cursor(old_doc, "X")
      patch = UndoPatch.from_delta(delta, old_doc)
      inverse = UndoPatch.invert(patch, new_doc)

      restored = UndoPatch.apply(patch, new_doc)
      redone = UndoPatch.apply(inverse, restored)

      assert Document.content(redone) == "Xhello"
      assert Document.cursor(redone) == Document.cursor(new_doc)
    end
  end

  describe "from_documents/2" do
    test "stores only the changed byte range" do
      patch = UndoPatch.from_documents(doc("prefix old suffix"), doc("prefix new suffix"))

      assert patch.start_byte == byte_size("prefix ")
      assert patch.old_text == "old"
      assert patch.new_text == "new"
    end

    test "stores byte fragments for multi-byte replacements" do
      patch = UndoPatch.from_documents(doc("é"), doc("è"))

      assert patch.old_text == <<0xA9>>
      assert patch.new_text == <<0xA8>>
      refute String.valid?(patch.old_text)
      refute String.valid?(patch.new_text)
      assert Document.content(UndoPatch.apply(patch, doc("è"))) == "é"
    end

    test "large document patch size stays proportional to the changed slice" do
      prefix = String.duplicate("a", 100_000)
      suffix = String.duplicate("z", 100_000)

      patch =
        UndoPatch.from_documents(doc(prefix <> "old" <> suffix), doc(prefix <> "new" <> suffix))

      assert patch.start_byte == byte_size(prefix)
      assert patch.old_text == "old"
      assert patch.new_text == "new"
      assert byte_size(patch.old_text) + byte_size(patch.new_text) == 6
    end

    test "handles mid-buffer cursor gaps with unicode near the diff" do
      old_doc = doc("αβγδ") |> Document.move_to({0, 4})
      new_doc = doc("αβξδ") |> Document.move_to({0, 4})

      patch = UndoPatch.from_documents(old_doc, new_doc)

      assert patch.start_byte == 5
      assert byte_size(patch.old_text) == 1
      assert byte_size(patch.new_text) == 1
      refute String.valid?(patch.old_text)
      refute String.valid?(patch.new_text)
      assert Document.content(UndoPatch.apply(patch, new_doc)) == "αβγδ"
    end

    test "empty and identical documents produce empty patches at the document end" do
      empty = UndoPatch.from_documents(doc(""), doc(""))
      assert {empty.start_byte, empty.old_text, empty.new_text} == {0, "", ""}

      text = "abc\ndéf"
      old_doc = doc(text) |> Document.move_to({1, 1})
      new_doc = doc(text) |> Document.move_to({0, 2})
      identical = UndoPatch.from_documents(old_doc, new_doc)

      assert {identical.start_byte, identical.old_text, identical.new_text} ==
               {byte_size(text), "", ""}

      assert identical.cursor == {1, 1}
    end

    test "insertions into and deletions from empty documents capture the whole text" do
      inserted = UndoPatch.from_documents(doc(""), doc("héllo"))
      assert {inserted.start_byte, inserted.old_text, inserted.new_text} == {0, "", "héllo"}

      deleted = UndoPatch.from_documents(doc("héllo"), doc(""))
      assert {deleted.start_byte, deleted.old_text, deleted.new_text} == {0, "héllo", ""}
    end

    test "repeated bytes never let the suffix overlap the prefix" do
      grown = UndoPatch.from_documents(doc("aaa"), doc("aaaa"))
      assert {grown.start_byte, grown.old_text, grown.new_text} == {3, "", "a"}

      shrunk = UndoPatch.from_documents(doc("abab"), doc("ab"))
      assert {shrunk.start_byte, shrunk.old_text, shrunk.new_text} == {2, "ab", ""}
    end

    test "prefix-heavy and suffix-heavy edits keep only the changed bytes" do
      tail_edit = UndoPatch.from_documents(doc("common text X"), doc("common text YZ"))
      assert {tail_edit.start_byte, tail_edit.old_text, tail_edit.new_text} == {12, "X", "YZ"}

      head_edit = UndoPatch.from_documents(doc("X common text"), doc("YZ common text"))
      assert {head_edit.start_byte, head_edit.old_text, head_edit.new_text} == {0, "X", "YZ"}
    end

    test "cursor gaps on either side of the edit do not change the patch" do
      old_text = "first\nsecond\nthird"
      new_text = "first\nSECOND!\nthird"

      for old_cursor <- [{0, 2}, {2, 3}], new_cursor <- [{0, 1}, {2, 5}] do
        old_doc = doc(old_text) |> Document.move_to(old_cursor)
        new_doc = doc(new_text) |> Document.move_to(new_cursor)
        patch = UndoPatch.from_documents(old_doc, new_doc)

        assert {patch.start_byte, patch.old_text, patch.new_text} == {6, "second", "SECOND!"}
        assert patch.cursor == old_cursor
        assert Document.content(UndoPatch.apply(patch, new_doc)) == old_text
        assert Document.cursor(UndoPatch.apply(patch, new_doc)) == old_cursor
      end
    end

    test "owns changed fragments instead of retaining the large document binaries" do
      prefix = String.duplicate("a", 1_000_000)
      patch = UndoPatch.from_documents(doc(prefix <> "old!"), doc(prefix <> "new!"))

      for fragment <- [patch.old_text, patch.new_text] do
        assert :binary.referenced_byte_size(fragment) == byte_size(fragment)
      end
    end

    test "edits at chunk boundaries match with cursor gaps inside and across chunks" do
      filler = String.duplicate("a", 10_000)

      for edit_at <- [4095, 4096, 4097, 8192],
          old_gap <- [0, 4000, edit_at, 9000],
          new_gap <- [0, 4100, 9000] do
        rest = binary_part(filler, edit_at, byte_size(filler) - edit_at)
        old_doc = doc_with_gap_near(binary_part(filler, 0, edit_at) <> "X" <> rest, old_gap)
        new_doc = doc_with_gap_near(binary_part(filler, 0, edit_at) <> "YZ" <> rest, new_gap)
        patch = UndoPatch.from_documents(old_doc, new_doc)

        assert {patch.start_byte, patch.old_text, patch.new_text} == {edit_at, "X", "YZ"}
      end
    end

    property "matches a byte-list reference and round-trips through apply and invert" do
      check all(
              {old_text, new_text} <- document_pair(),
              old_offset <- integer(0..byte_size(old_text)),
              new_offset <- integer(0..byte_size(new_text))
            ) do
        assert_reference_patch(old_text, new_text, old_offset, new_offset)
      end
    end

    property "matches the reference when affixes span multiple comparison chunks" do
      check all(
              {old_text, new_text} <- chunk_scale_pair(),
              old_offset <- integer(0..byte_size(old_text)),
              new_offset <- integer(0..byte_size(new_text)),
              max_runs: 50
            ) do
        assert_reference_patch(old_text, new_text, old_offset, new_offset)
      end
    end
  end

  defp assert_reference_patch(old_text, new_text, old_offset, new_offset) do
    old_doc = doc_with_gap_near(old_text, old_offset)
    new_doc = doc_with_gap_near(new_text, new_offset)
    {prefix, suffix} = reference_affixes(old_text, new_text)

    patch = UndoPatch.from_documents(old_doc, new_doc)

    assert patch.start_byte == prefix
    assert patch.old_text == middle(old_text, prefix, suffix)
    assert patch.new_text == middle(new_text, prefix, suffix)
    assert patch.cursor == Document.cursor(old_doc)

    undone = UndoPatch.apply(patch, new_doc)
    assert Document.content(undone) == old_text
    assert Document.cursor(undone) == Document.cursor(old_doc)

    redone = UndoPatch.apply(UndoPatch.invert(patch, new_doc), undone)
    assert Document.content(redone) == new_text
    assert Document.cursor(redone) == Document.cursor(new_doc)
  end

  # Shares lead bytes (é/è, α/ξ) so affix boundaries regularly fall inside a codepoint.
  @alphabet ["a", "b", "\n", "é", "è", "α", "ξ", "😀"]

  defp text_gen, do: @alphabet |> member_of() |> list_of(max_length: 12) |> map(&Enum.join/1)

  defp document_pair do
    one_of([
      tuple({text_gen(), text_gen()}),
      map(tuple({text_gen(), text_gen(), text_gen(), text_gen()}), fn {head, old, new, tail} ->
        {head <> old <> tail, head <> new <> tail}
      end)
    ])
  end

  # Multi-byte fillers put chunk boundaries inside codepoints; sizes span several 4 KiB chunks.
  defp chunk_scale_pair do
    map(tuple({integer(0..2_100), text_gen(), text_gen(), integer(0..1_200)}), fn
      {head_count, old, new, tail_count} ->
        head = String.duplicate("aé\n", head_count)
        tail = String.duplicate("ξb😀", tail_count)
        {head <> old <> tail, head <> new <> tail}
    end)
  end

  defp doc_with_gap_near(text, offset) do
    document = doc(text)
    Document.move_to(document, Document.offset_to_position(document, offset))
  end

  defp reference_affixes(old_text, new_text) do
    prefix = common_length(:binary.bin_to_list(old_text), :binary.bin_to_list(new_text))

    suffix =
      common_length(
        old_text |> rest_after(prefix) |> :binary.bin_to_list() |> Enum.reverse(),
        new_text |> rest_after(prefix) |> :binary.bin_to_list() |> Enum.reverse()
      )

    {prefix, suffix}
  end

  defp common_length(left, right),
    do: left |> Enum.zip(right) |> Enum.take_while(fn {l, r} -> l == r end) |> length()

  defp rest_after(text, prefix), do: binary_part(text, prefix, byte_size(text) - prefix)

  defp middle(text, prefix, suffix),
    do: binary_part(text, prefix, byte_size(text) - prefix - suffix)
end
