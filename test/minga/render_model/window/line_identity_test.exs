defmodule Minga.RenderModel.Window.LineIdentityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.EditDelta
  alias Minga.RenderModel.Window.LineIdentity

  describe "durable edit transitions" do
    test "whole-line insert and delete at the top preserve every surviving identity" do
      initial = LineIdentity.new(3, 7)
      original = LineIdentity.source_ids(initial)

      insert = EditDelta.insertion(0, {0, 0}, "new\n", {1, 0})
      assert {:ok, inserted} = LineIdentity.apply_edit(initial, insert)
      assert [_new | ^original] = LineIdentity.source_ids(inserted)

      delete = EditDelta.deletion(0, 4, {0, 0}, {1, 0})
      assert {:ok, restored} = LineIdentity.apply_edit(inserted, delete)
      assert LineIdentity.source_ids(restored) == original
      assert restored.next_source_id == inserted.next_source_id
    end

    test "multi-line paste allocates fresh monotonic identities without moving the leading source" do
      initial = LineIdentity.new(3)
      [first, second, third] = LineIdentity.source_ids(initial)
      delta = EditDelta.insertion(2, {1, 2}, "a\nb\n", {3, 0})

      assert {:ok, updated} = LineIdentity.apply_edit(initial, delta)
      assert [^first, ^second, new_a, new_b, ^third] = LineIdentity.source_ids(updated)
      assert new_a >= initial.next_source_id
      assert new_b == new_a + 1
    end

    test "editing a line, splitting it, and joining it preserve the leading source" do
      initial = LineIdentity.new(2)
      [leading, trailing] = LineIdentity.source_ids(initial)

      inline = EditDelta.replacement(1, 2, {0, 1}, {0, 2}, "x", {0, 2})
      assert {:ok, same} = LineIdentity.apply_edit(initial, inline)
      assert LineIdentity.source_ids(same) == [leading, trailing]

      split = EditDelta.insertion(2, {0, 2}, "\n", {1, 0})
      assert {:ok, split_state} = LineIdentity.apply_edit(same, split)
      assert [^leading, created, ^trailing] = LineIdentity.source_ids(split_state)

      join = EditDelta.deletion(2, 3, {0, 2}, {1, 0})
      assert {:ok, joined} = LineIdentity.apply_edit(split_state, join)
      assert LineIdentity.source_ids(joined) == [leading, trailing]
      refute created in LineIdentity.source_ids(joined)
    end

    test "multi-line deletion preserves the leading survivor and unaffected suffix" do
      initial = LineIdentity.new(5)
      [a, b, _c, _d, e] = LineIdentity.source_ids(initial)
      delta = EditDelta.deletion(4, 12, {1, 2}, {3, 1})

      assert {:ok, updated} = LineIdentity.apply_edit(initial, delta)
      assert LineIdentity.source_ids(updated) == [a, b, e]
    end

    test "duplicate text lines still own distinct identities" do
      identity = LineIdentity.new(4)
      assert Enum.uniq(LineIdentity.source_ids(identity)) == LineIdentity.source_ids(identity)
    end

    test "boundary splices coalesce adjacent surviving source runs" do
      initial = LineIdentity.new(10)
      insert = EditDelta.insertion(0, {5, 0}, "new\n", {6, 0})
      assert {:ok, inserted} = LineIdentity.apply_edit(initial, insert)
      assert LineIdentity.run_count(inserted) == 3

      delete = EditDelta.deletion(0, 4, {5, 0}, {6, 0})
      assert {:ok, restored} = LineIdentity.apply_edit(inserted, delete)
      assert LineIdentity.source_ids(restored) == LineIdentity.source_ids(initial)
      assert LineIdentity.run_count(restored) == 1
      assert LineIdentity.height(restored) == 1
    end

    test "unreconcilable history requests an explicit reset and reset changes epoch" do
      identity = LineIdentity.new(2, 9)
      bad = EditDelta.deletion(0, 0, {4, 0}, {4, 0})

      assert :reset_required = LineIdentity.apply_edit(identity, bad)
      reset = LineIdentity.reset(identity, 2, 10)
      assert reset.content_epoch == 10
      assert LineIdentity.source_ids(reset) == [0, 1]
    end
  end

  property "valid edit sequences keep source ids unique and allocation monotonic" do
    check all(
            initial_count <- integer(1..40),
            edits <- list_of(tuple({integer(0..8), integer(0..4), integer(0..4)}), max_length: 80)
          ) do
      initial = LineIdentity.new(initial_count)

      final =
        Enum.reduce(edits, initial, fn {raw_line, removed, inserted}, identity ->
          line_count = LineIdentity.line_count(identity)
          start_line = rem(raw_line, line_count)
          removable = min(removed, line_count - start_line - 1)
          old_end_line = start_line + removable
          new_end_line = start_line + inserted

          delta =
            EditDelta.replacement(
              0,
              0,
              {start_line, 1},
              {old_end_line, 1},
              String.duplicate("x\n", inserted),
              {new_end_line, 1}
            )

          assert {:ok, next} = LineIdentity.apply_edit(identity, delta)
          assert Enum.uniq(LineIdentity.source_ids(next)) == LineIdentity.source_ids(next)
          assert next.next_source_id >= identity.next_source_id
          next
        end)

      assert Enum.uniq(LineIdentity.source_ids(final)) == LineIdentity.source_ids(final)
    end
  end

  property "AVL height remains logarithmic in source runs under normal inline splices" do
    check all(positions <- list_of(integer(0..200), min_length: 1, max_length: 200)) do
      identity =
        Enum.reduce(positions, LineIdentity.new(201), fn raw_position, current ->
          position = rem(raw_position, LineIdentity.line_count(current))
          delta = EditDelta.insertion(0, {position, 1}, "x\n", {position + 1, 0})
          assert {:ok, next} = LineIdentity.apply_edit(current, delta)
          next
        end)

      runs = LineIdentity.run_count(identity)
      logarithmic_bound = 2 * ceil(:math.log2(runs + 1)) + 1
      assert LineIdentity.height(identity) <= logarithmic_bound

      Enum.with_index(LineIdentity.source_ids(identity), fn source_id, rank ->
        assert LineIdentity.source_id(identity, rank) == {:ok, source_id}
      end)
    end
  end

  property "whole-line structural splices preserve prefix and suffix identities" do
    check all(
            line_count <- integer(1..30),
            raw_start <- integer(0..29),
            raw_removed <- integer(0..10),
            inserted <- integer(0..10)
          ) do
      identity = LineIdentity.new(line_count)
      start_line = min(raw_start, line_count - 1)
      removed = min(raw_removed, line_count - start_line - 1)
      old_end_line = start_line + removed

      delta =
        EditDelta.replacement(
          0,
          0,
          {start_line, 0},
          {old_end_line, 0},
          "",
          {start_line + inserted, 0}
        )

      assert {:ok, updated} = LineIdentity.apply_edit(identity, delta)
      prefix = Enum.take(LineIdentity.source_ids(identity), start_line)
      suffix = Enum.drop(LineIdentity.source_ids(identity), old_end_line)
      assert Enum.take(LineIdentity.source_ids(updated), start_line) == prefix
      assert Enum.take(LineIdentity.source_ids(updated), -length(suffix)) == suffix
    end
  end
end
