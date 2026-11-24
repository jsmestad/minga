defmodule Minga.Buffer.UndoPatchTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document
  alias Minga.Buffer.Lines
  alias Minga.Buffer.Operation
  alias Minga.Buffer.UndoPatch

  defp doc(text), do: Document.new(text)

  defp apply!(patch, document) do
    {:ok, applied} = UndoPatch.apply(patch, document)
    applied
  end

  describe "changes/2" do
    test "three separated changed regions become three whole-line patches, nearest the start first" do
      old = Document.move_to(doc("a\nkeep 1\nb\nkeep 2\nc\n"), {1, 2})
      new = doc("A\nkeep 1\nB1\nB2\nkeep 2\n")

      patches = UndoPatch.changes(old, new)

      assert [{0, "a\n", "A\n"}, {9, "b\n", "B1\nB2\n"}, {18, "c\n", ""}] ==
               Enum.map(patches, &{&1.start_byte, &1.old_text, &1.new_text})

      {:ok, undone, redo} = UndoPatch.apply_all(patches, new)
      assert Document.content(undone) == Document.content(old)
      assert Document.cursor(undone) == {1, 2}

      {:ok, redone, _undo} = UndoPatch.apply_all(redo, undone)
      assert Document.content(redone) == Document.content(new)
    end

    test "equal contents produce no patches" do
      assert UndoPatch.changes(doc("same\ntext"), doc("same\ntext")) == []
      assert UndoPatch.changes(doc(""), doc("")) == []
    end

    test "covers insertions, deletions and changes at either end of the document" do
      for {old_text, new_text, expected} <- [
            {"", "new", [{0, "", "new"}]},
            {"gone", "", [{0, "gone", ""}]},
            {"a\nb", "a\nb\n", [{2, "b", "b\n"}]},
            {"a\nb\n", "a\nb", [{2, "b\n", "b"}]},
            {"a\nc\n", "a\nb\nc\n", [{2, "", "b\n"}]},
            {"x\na\n", "a\n", [{0, "x\n", ""}]}
          ] do
        patches = UndoPatch.changes(doc(old_text), doc(new_text))

        assert Enum.map(patches, &{&1.start_byte, &1.old_text, &1.new_text}) == expected,
               inspect({old_text, new_text})
      end
    end

    test "a large file keeps distant edits as separate regions" do
      lines = for n <- 1..20_000, do: "line #{n}\n"
      old = doc(Enum.join(lines))

      new =
        lines
        |> List.replace_at(9, "changed 10\n")
        |> List.replace_at(19_000, "changed 19001\n")
        |> Enum.join()
        |> doc()

      assert [%{old_text: "line 10\n"}, %{old_text: "line 19001\n"}] =
               UndoPatch.changes(old, new)
    end

    test "rewriting every line of a large file records the rewritten span as one region" do
      lines = for n <- 1..3_000, do: "line #{n}\n"
      old = doc("header\n" <> Enum.join(lines) <> "footer\n")
      new = doc("header\n" <> Enum.map_join(lines, &("  " <> &1)) <> "footer\n")

      assert [patch] = UndoPatch.changes(old, new)
      assert patch.start_byte == byte_size("header\n")
      assert patch.old_text == Enum.join(lines)

      {:ok, undone, _redo} = UndoPatch.apply_all([patch], new)
      assert Document.content(undone) == Document.content(old)
    end

    # The per-change patches record the same edit as the whole-document patch: undoing either
    # from the new content restores the old content and cursor, and redoing restores the new.
    property "rebuild the new content exactly and undo to the same document as one whole patch" do
      check all(
              old_lines <- list_of(line_gen(), max_length: 12),
              new_lines <- edited_lines_gen(old_lines),
              trailing_old <- boolean(),
              trailing_new <- boolean(),
              cursor_pick <- integer(0..60),
              max_runs: 500
            ) do
        old_text = join_lines(old_lines, trailing_old)
        new_text = join_lines(new_lines, trailing_new)
        old = Document.move_to(doc(old_text), {div(cursor_pick, 5), rem(cursor_pick, 5)})
        new = Document.move_to(doc(new_text), Document.cursor(old))

        case UndoPatch.changes(old, new) do
          [] ->
            assert old_text == new_text

          patches ->
            whole = [UndoPatch.from_documents(old, new)]
            {:ok, undone, redo} = UndoPatch.apply_all(patches, new)
            {:ok, whole_undone, _redo} = UndoPatch.apply_all(whole, new)

            assert Document.content(undone) == old_text
            assert Document.content(undone) == Document.content(whole_undone)
            assert Document.cursor(undone) == Document.cursor(whole_undone)

            {:ok, redone, _undo} = UndoPatch.apply_all(redo, undone)
            assert Document.content(redone) == new_text

            starts = Enum.map(patches, & &1.start_byte)
            assert starts == Enum.sort(starts)
        end
      end
    end
  end

  defp line_gen, do: member_of(["", "a", "b", "é", "keep", "λx", "  end"])

  # Keeps most old lines so the diff finds separated regions, and edits the rest.
  defp edited_lines_gen(old_lines) do
    old_lines
    |> Enum.map(fn line ->
      frequency([
        {6, constant([line])},
        {1, constant([])},
        {1, map(line_gen(), &[&1])},
        {1, map(line_gen(), &[line, &1])}
      ])
    end)
    |> fixed_list()
    |> map(&List.flatten/1)
  end

  defp join_lines([], _trailing?), do: ""
  defp join_lines(lines, true), do: Enum.join(lines, "\n") <> "\n"
  defp join_lines(lines, false), do: Enum.join(lines, "\n")

  describe "apply/2" do
    test "refuses a patch whose replaced bytes the document does not hold" do
      # The patch says "Z" sits at byte 5, but byte 5 of "abZ\ncd" is "d".
      patch = UndoPatch.replacement(5, "", "Z", {0, 0})

      assert UndoPatch.apply(patch, doc("abZ\ncd")) == {:error, :patch_mismatch}
    end

    test "refuses a patch whose range runs past the document" do
      patch = UndoPatch.replacement(2, "", "xyz", {0, 0})

      assert UndoPatch.apply(patch, doc("abc")) == {:error, :patch_mismatch}
    end

    test "refuses a patch whose result would not be valid UTF-8" do
      # Replacing the "é" lead byte with an ASCII byte leaves a lone continuation byte.
      patch = UndoPatch.replacement(0, "e", <<0xC3>>, {0, 0})

      assert UndoPatch.apply(patch, doc("é")) == {:error, :invalid_utf8}
    end
  end

  describe "from_delta/2" do
    test "captures insertion patches" do
      old_doc = doc("hello")
      {:edited, new_doc, delta} = Operation.insert_at_cursor(old_doc, "X")

      patch = UndoPatch.from_delta(delta, old_doc)

      assert patch.start_byte == 0
      assert patch.old_text == ""
      assert patch.new_text == "X"
      assert apply!(patch, new_doc) |> Document.content() == "hello"
    end

    test "captures deletion patches" do
      old_doc = doc("héllo") |> Document.move_to({0, 3})
      {:edited, new_doc, delta} = Operation.backspace(old_doc)

      patch = UndoPatch.from_delta(delta, old_doc)

      assert patch.old_text == "é"
      assert patch.new_text == ""
      assert apply!(patch, new_doc) |> Document.content() == "héllo"
    end

    test "captures replacement patches" do
      old_doc = doc("one two three")
      {:edited, new_doc, delta} = Operation.replace_range(old_doc, {0, 4}, {0, 6}, "TWO")

      patch = UndoPatch.from_delta(delta, old_doc)

      assert patch.old_text == "two"
      assert patch.new_text == "TWO"
      assert apply!(patch, new_doc) |> Document.content() == "one two three"
    end

    test "captures deleted text across the cursor gap" do
      old_doc = doc("abc def") |> Document.move_to({0, 4})
      {:edited, new_doc, delta} = Operation.replace_range(old_doc, {0, 2}, {0, 4}, "X")

      patch = UndoPatch.from_delta(delta, old_doc)

      assert patch.old_text == "c d"
      assert patch.new_text == "X"
      assert apply!(patch, new_doc) |> Document.content() == "abc def"
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

  describe "apply_all/2" do
    test "undoes and redoes a separated batch, matching one apply/2 per patch" do
      original =
        doc(Enum.map_join(0..199, "\r\n", &"line #{&1} déf 字")) |> Document.move_to({3, 2})

      edits = for line <- 0..199//2, do: {{line, 5}, {line, 9}, "ü\nX"}
      {:ok, edited, patches} = Operation.replace_ranges_with_patches(original, edits)

      {undone, redo_patches} = assert_same_as_sequential(patches, edited)
      assert Document.content(undone) == Document.content(original)
      assert Document.cursor(undone) == Document.cursor(original)

      {redone, _undo_patches} = assert_same_as_sequential(redo_patches, undone)
      assert Document.content(redone) == Document.content(edited)
    end

    test "builds the document once for a whole batch, where apply/2 builds it once per patch" do
      original = doc(Enum.map_join(0..999, "\n", &"  def function_#{&1}(conn), do: :ok"))
      edits = for line <- 0..999, do: {{line, 6}, {line, 13}, "renamed"}
      {:ok, edited, patches} = Operation.replace_ranges_with_patches(original, edits)

      {{:ok, undone, redo_patches}, undo_builds} =
        count_document_builds(fn -> UndoPatch.apply_all(patches, edited) end)

      {{:ok, _redone, _undo_patches}, redo_builds} =
        count_document_builds(fn -> UndoPatch.apply_all(redo_patches, undone) end)

      {_control, control_builds} =
        count_document_builds(fn -> sequential(patches, edited) end)

      assert {undo_builds, redo_builds, control_builds} == {1, 1, 1_000}
    end

    test "applies coalesced typing and backspacing as one run each" do
      {typed, typing_patches} =
        Enum.reduce(["a", "b", "c"], {doc(""), []}, fn char, {document, patches} ->
          next = Document.insert_text(document, char)
          {next, [UndoPatch.from_documents(document, next) | patches]}
        end)

      assert {_result, 1} =
               count_document_builds(fn -> UndoPatch.apply_all(typing_patches, typed) end)

      {undone, redo_patches} = assert_same_as_sequential(typing_patches, typed)

      assert Document.content(undone) == ""

      assert {_result, 1} =
               count_document_builds(fn -> UndoPatch.apply_all(redo_patches, undone) end)

      {redone, _undo_patches} = assert_same_as_sequential(redo_patches, undone)

      assert Document.content(redone) == "abc"

      {empty, deletion_patches} =
        Enum.reduce(1..3, {Document.move_to(doc("xyz"), {0, 3}), []}, fn _, {document, patches} ->
          next = Document.delete_before(document)
          {next, [UndoPatch.from_documents(document, next) | patches]}
        end)

      assert {_result, 1} =
               count_document_builds(fn -> UndoPatch.apply_all(deletion_patches, empty) end)

      {restored, _redo_patches} = assert_same_as_sequential(deletion_patches, empty)
      assert Document.content(restored) == "xyz"
    end

    test "stops at the first patch that does not apply, with its error" do
      original = doc("one two three four")
      edits = [{{0, 0}, {0, 2}, "ONE"}, {{0, 8}, {0, 12}, "THREE"}, {{0, 14}, {0, 17}, "FOUR"}]

      {:ok, edited, [newest, middle, oldest]} =
        Operation.replace_ranges_with_patches(original, edits)

      stale = UndoPatch.replacement(8, "x", "three", {0, 0})
      lone_lead_byte = UndoPatch.replacement(14, <<0xC3>>, "FOUR", {0, 0})

      for {patches, reason} <- [
            {[newest, middle, oldest, oldest], :patch_mismatch},
            {[newest, stale, oldest], :patch_mismatch},
            {[newest, middle, lone_lead_byte], :invalid_utf8}
          ] do
        assert UndoPatch.apply_all(patches, edited) == {:error, reason}
        assert sequential(patches, edited) == {:error, reason}
      end
    end

    test "applies a run one patch at a time to a document that is not valid UTF-8" do
      invalid = doc(<<"Ab", 0xFF, "cd">>)

      patches = [
        UndoPatch.replacement(2, "x", <<0xFF>>, {0, 0}),
        UndoPatch.replacement(0, "a", "A", {0, 0})
      ]

      assert {{:ok, repaired, _inverses}, 2} =
               count_document_builds(fn -> UndoPatch.apply_all(patches, invalid) end)

      assert Document.content(repaired) == "abxcd"
      assert_same_as_sequential(patches, invalid)
    end

    test "refuses a run whose intermediate document would not be valid UTF-8" do
      restore_b = UndoPatch.replacement(3, "B", "b", {0, 0})

      for {text, patches} <- [
            # The document itself is not valid UTF-8.
            {<<"Ab", 0xFF, "cd">>,
             [
               UndoPatch.replacement(4, "D", "d", {0, 0}),
               UndoPatch.replacement(0, "a", "A", {0, 0})
             ]},
            # The second patch ends inside "é".
            {"aéb", [restore_b, UndoPatch.replacement(0, "x", <<"a", 0xC3>>, {0, 0})]},
            # The second patch starts inside "é".
            {"aéb", [restore_b, UndoPatch.replacement(2, "x", <<0xA9>>, {0, 0})]}
          ] do
        assert UndoPatch.apply_all(patches, doc(text)) == {:error, :invalid_utf8}
        assert sequential(patches, doc(text)) == {:error, :invalid_utf8}
      end
    end

    # Histories built from real edits over Unicode and CRLF text: batches, single edits, and
    # whole-document diffs whose fragments can split a code point. Undo, redo, and undo again
    # must equal one `apply/2` per patch. Dropping a patch corrupts the history, and the error
    # must then equal the sequential one.
    property "equals one apply/2 per patch for histories over Unicode and CRLF" do
      check all(
              text <- history_text_gen(),
              cursor_pick <- integer(0..200),
              actions <- list_of(action_gen(), min_length: 1, max_length: 6),
              drop <- one_of([constant(nil), integer(0..40)]),
              max_runs: 1_500
            ) do
        original = Document.move_to(doc(text), {div(cursor_pick, 7), rem(cursor_pick, 7)})

        case record(original, actions) do
          {_edited, []} ->
            :ok

          {edited, patches} when drop == nil ->
            {undone, redo_patches} = assert_same_as_sequential(patches, edited)
            assert Document.content(undone) == text
            assert Document.cursor(undone) == Document.cursor(original)

            {redone, undo_patches} = assert_same_as_sequential(redo_patches, undone)
            assert Document.content(redone) == Document.content(edited)
            # A batch can leave its cursor inside a grapheme; applying a patch places it.
            assert Document.cursor(redone) ==
                     edited |> Document.move_to(Document.cursor(edited)) |> Document.cursor()

            {again, _} = assert_same_as_sequential(undo_patches, redone)
            assert Document.content(again) == text
            assert Document.cursor(again) == Document.cursor(original)

          {edited, patches} ->
            corrupted = List.delete_at(patches, rem(drop, length(patches)))

            if corrupted != [] do
              assert_same_as_sequential_or_error(corrupted, edited)
            end
        end
      end
    end
  end

  describe "invert/2" do
    test "inverted patch reapplies the original edit" do
      old_doc = doc("hello")
      {:edited, new_doc, delta} = Operation.insert_at_cursor(old_doc, "X")
      patch = UndoPatch.from_delta(delta, old_doc)
      inverse = UndoPatch.invert(patch, new_doc)

      restored = apply!(patch, new_doc)
      redone = apply!(inverse, restored)

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
      assert Document.content(apply!(patch, doc("è"))) == "é"
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
      assert Document.content(apply!(patch, new_doc)) == "αβγδ"
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
        assert Document.content(apply!(patch, new_doc)) == old_text
        assert Document.cursor(apply!(patch, new_doc)) == old_cursor
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

    undone = apply!(patch, new_doc)
    assert Document.content(undone) == old_text
    assert Document.cursor(undone) == Document.cursor(old_doc)

    redone = apply!(UndoPatch.invert(patch, new_doc), undone)
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

  # ── apply_all/2 helpers ──

  # The control: one `apply/2` per patch, inverting each against the document it applied to.
  defp sequential(patches, document) do
    Enum.reduce_while(patches, {:ok, document, []}, fn patch, {:ok, current, inverses} ->
      case UndoPatch.apply(patch, current) do
        {:ok, next} -> {:cont, {:ok, next, [UndoPatch.invert(patch, current) | inverses]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Content, cursor, and line index must be equal. Inverse ranges and texts must be equal; an
  # inverse cursor is only placed when that inverse is applied, which the callers check.
  defp assert_same_as_sequential(patches, document) do
    assert {:ok, result, inverses} = UndoPatch.apply_all(patches, document)
    assert {:ok, expected, expected_inverses} = sequential(patches, document)
    assert Document.content(result) == Document.content(expected)
    assert Document.cursor(result) == Document.cursor(expected)
    assert Lines.snapshot(result) == Lines.snapshot(expected)
    assert Enum.map(inverses, &ranges/1) == Enum.map(expected_inverses, &ranges/1)
    {result, inverses}
  end

  defp assert_same_as_sequential_or_error(patches, document) do
    case sequential(patches, document) do
      {:ok, _expected, _inverses} -> assert_same_as_sequential(patches, document)
      error -> assert UndoPatch.apply_all(patches, document) == error
    end
  end

  defp ranges(patch), do: {patch.start_byte, patch.old_text, patch.new_text}

  # Counts `Document.new/1` calls by this process. An isolated trace session sends each call to
  # a counting process, so concurrent tests neither see nor disturb the count.
  defp count_document_builds(fun) do
    counter = spawn_link(fn -> count_calls(0) end)
    session = :trace.session_create(:undo_patch_test, counter, [])

    try do
      1 = :trace.function(session, {Document, :new, 1}, true, [:local])
      1 = :trace.process(session, self(), true, [:call])
      result = fun.()
      1 = :trace.process(session, self(), false, [:call])
      ref = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _pid, ^ref}
      send(counter, {:count, self()})
      assert_receive {:document_builds, count}
      {result, count}
    after
      :trace.session_destroy(session)
    end
  end

  defp count_calls(count) do
    receive do
      {:trace, _pid, :call, {Document, :new, _args}} -> count_calls(count + 1)
      {:count, from} -> send(from, {:document_builds, count})
    end
  end

  @history_fragments [
    "a",
    "b",
    " ",
    "é",
    "é",
    "́",
    "\n",
    "\r\n",
    "\r",
    "😀",
    "🇺🇸",
    "👩‍💻",
    "ᄀ",
    "ᅡ",
    "字"
  ]

  defp history_text_gen,
    do: @history_fragments |> member_of() |> list_of(max_length: 30) |> map(&Enum.join/1)

  defp pick_gen, do: tuple({integer(0..200), integer(0..3), history_text_gen()})

  defp action_gen do
    one_of([
      map(list_of(pick_gen(), min_length: 1, max_length: 12), &{:batch, &1}),
      map(list_of(pick_gen(), min_length: 1, max_length: 4), &{:singles, &1}),
      map(tuple({pick_gen(), integer(0..200)}), &{:rewrite, &1})
    ])
  end

  # Applies the actions in order and returns the edited document with its patches newest first,
  # as one coalesced undo entry holds them.
  defp record(document, actions) do
    Enum.reduce(actions, {document, []}, fn action, {current, patches} ->
      {next, new_patches} = perform(action, current)
      {next, new_patches ++ patches}
    end)
  end

  defp perform({:batch, picks}, document) do
    case Operation.replace_ranges_with_patches(
           document,
           Enum.map(picks, &range_edit(document, &1))
         ) do
      {:ok, next, patches} -> {next, patches}
      {:error, _reason} -> {document, []}
    end
  end

  defp perform({:singles, picks}, document) do
    Enum.reduce(picks, {document, []}, fn pick, {current, patches} ->
      {next, new_patches} = perform({:batch, [pick]}, current)
      {next, new_patches ++ patches}
    end)
  end

  defp perform({:rewrite, {{pick, width, replacement}, cursor_pick}}, document) do
    text = Document.content(document)
    {start, stop} = code_point_span(text, pick, width)

    new_text =
      binary_part(text, 0, start) <>
        replacement <> binary_part(text, stop, byte_size(text) - stop)

    next = Document.move_to(doc(new_text), {div(cursor_pick, 7), rem(cursor_pick, 7)})
    {next, [UndoPatch.from_documents(document, next)]}
  end

  defp range_edit(document, {pick, width, replacement}) do
    {start, stop} = code_point_span(Document.content(document), pick, width)

    {Document.offset_to_position(document, start), Document.offset_to_position(document, stop),
     replacement}
  end

  defp code_point_span(text, pick, width) do
    stops = [0 | text |> String.codepoints() |> Enum.scan(0, &(byte_size(&1) + &2))]
    index = rem(pick, length(stops))
    {Enum.at(stops, index), Enum.at(stops, min(index + width, length(stops) - 1))}
  end
end
