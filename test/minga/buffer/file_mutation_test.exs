defmodule Minga.Buffer.FileMutationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.FileMutation
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tool.Output.Revision

  @identity {:buffer, "/project/source.ex"}

  test "a complete read revision authorizes one sequential batch" do
    content = "one\ntwo\nthree\n"
    {:ok, scope} = Range.new(:full, :bytes, 0, byte_size(content), byte_size(content))

    {:ok, revision} =
      Revision.new(
        source_kind: :buffer,
        source_id: elem(@identity, 1),
        scope: scope,
        generation: 3,
        sha256: Reference.digest(content)
      )

    expected = Revision.token(revision)

    assert expected == FileMutation.revision(content, 3, @identity)

    assert {:ok, "longer\nTWO\nthree\n", [{7, "two", "TWO"}, {0, "one", "longer"}]} =
             FileMutation.prepare(
               {:ok, content},
               3,
               @identity,
               expected,
               {:edit, [{"one", "longer"}, {"two", "TWO"}]}
             )
  end

  test "every rejection identifies the failed edit and returns no prepared content" do
    for {content, edits, reason} <- [
          {"one two", [{"one", "ONE"}, {"missing", "new"}], {:edit_failed, 2, :not_found}},
          {"one one", [{"one", "ONE"}], {:edit_failed, 1, :ambiguous_match}},
          {"aaa", [{"aa", "b"}], {:edit_failed, 1, :ambiguous_match}},
          {"one two", [{"one", "ONE"}, {"ONE", "new"}], {:edit_failed, 2, :overlapping_edit}},
          {"one", [{"", ""}], {:edit_failed, 1, :empty_edit}},
          {"one", [{"", <<255>>}], {:edit_failed, 1, :invalid_text}},
          {"one", [{"", "two"}, {"one\ntwo", "x"}], {:edit_failed, 2, :overlapping_edit}},
          {"one", [{"one", <<255>>}], {:edit_failed, 1, :invalid_text}},
          {"", [{"one", "new"}], {:edit_failed, 1, :not_found}}
        ] do
      assert {:error, ^reason} =
               FileMutation.prepare(
                 {:ok, content},
                 0,
                 @identity,
                 FileMutation.revision(content, 0, @identity),
                 {:edit, edits}
               )
    end
  end

  test "an empty old text appends on a new line without doubling an existing newline" do
    for {content, new, expected} <- [
          {"one", "two", "one\ntwo"},
          {"one\n", "two", "one\ntwo"},
          {"one", "\ntwo", "one\ntwo"},
          {"one\r\n", "two\r\n", "one\r\ntwo\r\n"},
          {"", "two", "two"}
        ] do
      offset = byte_size(content)
      appended = binary_part(expected, offset, byte_size(expected) - offset)

      assert {:ok, ^expected, [{^offset, "", ^appended}]} =
               FileMutation.prepare(
                 {:ok, content},
                 0,
                 @identity,
                 FileMutation.revision(content, 0, @identity),
                 {:edit, [{"", new}]}
               )
    end
  end

  test "full revision identity and generation reject stale bytes and ranged reads" do
    content = "αβ\n日本語\n"
    expected = FileMutation.revision(content, 0, @identity)

    assert {:ok, "αβ\n漢字\n", [{5, "日本語", "漢字"}]} =
             FileMutation.prepare(
               {:ok, content},
               0,
               @identity,
               expected,
               {:edit, [{"日本語", "漢字"}]}
             )

    assert {:error, :stale_revision} =
             FileMutation.prepare({:ok, content}, 1, @identity, expected, {:replace, "new"})

    assert {:error, :stale_revision} =
             FileMutation.prepare({:ok, "human"}, 0, @identity, expected, :delete)

    assert {:error, :stale_revision} =
             FileMutation.prepare({:ok, content}, 0, {:buffer, "/different"}, expected, :delete)

    {:ok, scope} = Range.new(:requested, :lines, 0, 2, 2)

    {:ok, revision} =
      Revision.new(
        source_kind: :buffer,
        source_id: elem(@identity, 1),
        scope: scope,
        generation: 0,
        sha256: Reference.digest(content)
      )

    assert {:error, :stale_revision} =
             FileMutation.prepare({:ok, content}, 0, @identity, Revision.token(revision), :delete)
  end

  test "creation requires absence and replacement and deletion require a revision even for empty files" do
    assert {:ok, "", :whole} =
             FileMutation.prepare({:error, :enoent}, 0, @identity, :absent, {:create, ""})

    assert {:error, :already_exists} =
             FileMutation.prepare({:ok, ""}, 0, @identity, :absent, {:create, "new"})

    assert {:error, :revision_required} =
             FileMutation.prepare({:ok, ""}, 0, @identity, nil, {:replace, "new"})

    assert {:error, :revision_required} =
             FileMutation.prepare({:ok, ""}, 0, @identity, :absent, :delete)

    expected = FileMutation.revision("", 0, @identity)

    assert {:ok, "new", :whole} =
             FileMutation.prepare({:ok, ""}, 0, @identity, expected, {:replace, "new"})

    assert {:ok, :deleted, :whole} =
             FileMutation.prepare({:ok, ""}, 0, @identity, expected, :delete)
  end

  property "a batch changes only uniquely named original regions regardless of replacement sizes" do
    check all(count <- integer(1..100), size <- integer(0..40)) do
      content = Enum.map_join(1..count, "\n", &"<old:#{&1}>")
      edits = Enum.map(1..count, &{"<old:#{&1}>", "<new:#{&1}>" <> String.duplicate("x", size)})
      result = Enum.map_join(1..count, "\n", &("<new:#{&1}>" <> String.duplicate("x", size)))

      assert {:ok, ^result, splices} =
               FileMutation.prepare(
                 {:ok, content},
                 0,
                 @identity,
                 FileMutation.revision(content, 0, @identity),
                 {:edit, edits}
               )

      restored =
        Enum.reduce(splices, result, fn {start, removed, inserted}, bytes ->
          suffix = start + byte_size(inserted)
          assert binary_part(bytes, start, byte_size(inserted)) == inserted

          binary_part(bytes, 0, start) <>
            removed <> binary_part(bytes, suffix, byte_size(bytes) - suffix)
        end)

      assert restored == content
    end
  end
end
