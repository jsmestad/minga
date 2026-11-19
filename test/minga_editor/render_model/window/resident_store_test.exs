defmodule MingaEditor.RenderModel.Window.ResidentStoreTest do
  @moduledoc """
  Invariants for the persistent resident entry-list store (#2658, AC3).

  Ranked properties (per the test strategy):

    a. incremental store state == a from-scratch rebuild after any edit/insert/
       delete sequence (asserted after every step, not just at the end);
    c. the digest changes iff a row actually changed (edit-back-to-original
       produces the prior digest, no spurious emits);
    b. the incremental digest == a full recompute after any sequence.

  The store is a generic list-with-digest; it sees row-index sets only, never
  per-dirty-source detail, so no change-source knowledge is tested here.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.RenderModel.Window.ContentDigest
  alias Minga.RenderModel.Window.Row
  alias Minga.Core.Decorations
  alias MingaEditor.Mouse.TextEvent
  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.RenderModel.Window.SourceOffsetMap
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.Renderer.TextInteractionIndex
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Renderer.TextPresentation

  @max_rows 100

  # ── Generators ─────────────────────────────────────────────────────────

  # Entries carry a unique id (assigned by the harness), a content hash drawn
  # from a small pool so edits can collide back to a prior value, and an opaque
  # payload derived from both so a payload mismatch is caught alongside the hash.
  defp content_hash_gen, do: integer(0..8)

  defp op_gen do
    one_of([
      tuple({constant(:insert), content_hash_gen()}),
      constant(:delete),
      tuple({constant(:replace), content_hash_gen()})
    ])
  end

  defp op_list_gen do
    gen all(ops <- list_of(op_gen(), max_length: 60)) do
      ops
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp make_entry(id, content_hash) do
    ResidentStore.entry(id, content_hash, {:payload, id, content_hash})
  end

  defp visual_entry(index) do
    row = %Row{
      row_id: Row.stable_id(:normal, index),
      row_type: :normal,
      buf_line: index,
      visual_index: 0,
      text: "line #{index}",
      spans: [],
      content_hash: Row.compute_hash("line #{index}", [])
    }

    ResidentStore.entry(
      row.row_id,
      row.content_hash,
      VisualRow.new(
        row,
        SourceOffsetMap.new(row.text, row.text, Decorations.new(), index),
        0,
        byte_size(row.text),
        0
      )
    )
  end

  test "rank and select preserve groups split by chunks and pointer lease projection" do
    entries = [visual_entry(0) | Enum.map(1..130, &continuation_entry/1)] ++ [visual_entry(1)]
    store = ResidentStore.from_entries(entries)

    assert ResidentStore.line_count(store) == 2
    assert ResidentStore.line_extent(store, 0) == {0, 131}
    assert ResidentStore.visual_rank(store, 2) == 132
    assert ResidentStore.anchor_at(store, 64) == {0, 64}
    assert ResidentStore.anchor_at(store, 128) == {0, 128}
    assert ResidentStore.anchor_at(store, 131) == {1, 0}

    inserted = visual_entry(25)
    next = ResidentStore.insert_at(store, 0, inserted)
    assert ResidentStore.line_extent(next, 1) == {1, 131}
    assert ResidentStore.entry_at(next, 129) == ResidentStore.entry_at(store, 128)

    assert [%VisualRow{buf_line: 1, visual_index: 128}] =
             ResidentStore.payload_range(next, 129, 1)

    index = TextInteractionIndex.new()
    reader = TextInteractionIndex.reader(index)
    buffer = self()
    identity = {:wrapped_resident, :width_basis, 1, :identity}

    presentation =
      TextPresentation.new(5, buffer, 11, identity, {:resident, next}, 7)
      |> TextPresentation.settle_scroll(4)

    index = TextInteractionIndex.publish(index, presentation)
    assert :ok = TextInteractionIndex.activate(index, 5, 7)

    assert {:ok, {1, 128}, true} =
             Reader.scroll_anchor(reader, 5, buffer, 11, :width_basis, {1, 127}, 1, 4)

    assert {:ok, {1, 127}, false} =
             Reader.scroll_anchor(reader, 5, buffer, 11, :width_basis, {1, 128}, -1, 4)

    assert :error = Reader.scroll_anchor(reader, 5, buffer, 10, :width_basis, {1, 128}, 1, 4)
    assert :error = Reader.scroll_anchor(reader, 5, buffer, 11, :stale_width, {1, 128}, 1, 4)

    next_identity = {:wrapped_resident, :width_basis, 2, :identity}

    next_presentation =
      TextPresentation.new(5, buffer, 11, next_identity, {:resident, next}, 8)
      |> TextPresentation.settle_scroll(4)

    index = TextInteractionIndex.publish(index, next_presentation)
    assert :error = Reader.seek_scroll_rank(reader, 5, 7, {buffer, 11, :width_basis, 2}, 0, 4)

    event =
      TextEvent.new(%{
        window_id: 5,
        presentation_id: 7,
        row_index: 129,
        row_id: Row.stable_id(:wrap_continuation, 0, 128),
        utf16_offset: 0,
        button: :left,
        mods: 0,
        event_type: :press,
        click_count: 1,
        scroll_x: 0,
        scroll_y: 0
      })

    assert {:ok, %{line: 1, byte: 128, source_version: 11}} = Reader.resolve(reader, event)
    _index = TextInteractionIndex.drop_buffer(index, buffer)
    assert :error = Reader.scroll_anchor(reader, 5, buffer, 11, :width_basis, {1, 128}, 1, 4)
  end

  test "thumb seeks keep the displayed lease across echoes but reject it after a settled re-anchor" do
    index = TextInteractionIndex.new()
    reader = TextInteractionIndex.reader(index)
    buffer = self()
    rows = {:resident, ResidentStore.from_entries(Enum.map(0..2, &visual_entry/1))}
    scroll_context = {buffer, 11, :width_basis, 1}

    displayed_identity = {:wrapped_resident, :width_basis, 1, :identity}

    displayed =
      TextPresentation.new(5, buffer, 11, displayed_identity, rows, 7)
      |> TextPresentation.settle_scroll(4)

    index = TextInteractionIndex.publish(index, displayed)
    assert :ok = TextInteractionIndex.activate(index, 5, 7)

    echo_identity = {:wrapped_resident, :width_basis, 1, :echo}

    echo =
      TextPresentation.new(5, buffer, 11, echo_identity, rows, 8)
      |> TextPresentation.settle_scroll(4)

    index = TextInteractionIndex.publish(index, echo)

    assert {:ok, {1, 0}, false} = Reader.seek_scroll_rank(reader, 5, 7, scroll_context, 1, 1)

    reanchored_identity = {:wrapped_resident, :width_basis, 1, :reanchored}

    reanchored =
      TextPresentation.new(5, buffer, 11, reanchored_identity, rows, 9)
      |> TextPresentation.settle_scroll(5)

    index = TextInteractionIndex.publish(index, reanchored)

    assert TextInteractionIndex.last_publication_nodes(index) == 0
    assert {:ok, {^buffer, 11}} = Reader.source(reader, 5, 7)
    assert :error = Reader.seek_scroll_rank(reader, 5, 7, scroll_context, 1, 1)

    assert {:ok, {1, 0}, false} =
             Reader.scroll_anchor(reader, 5, buffer, 11, :width_basis, {0, 0}, 1, 1)

    assert :ok = TextInteractionIndex.activate(index, 5, 9)
    assert {:ok, {1, 0}, false} = Reader.seek_scroll_rank(reader, 5, 9, scroll_context, 1, 1)
  end

  defp continuation_entry(offset) do
    source = String.duplicate("x", 131)

    row = %Row{
      row_id: Row.stable_id(:wrap_continuation, 0, offset),
      row_type: :wrap_continuation,
      buf_line: 0,
      visual_index: offset,
      text: "x",
      spans: [],
      content_hash: Row.compute_hash("x", [])
    }

    map =
      SourceOffsetMap.new(source, source, Decorations.new(), 0)
      |> SourceOffsetMap.slice(offset, offset + 1, offset, offset + 1)

    ResidentStore.entry(
      row.row_id,
      row.content_hash,
      VisualRow.new(row, map, offset, offset + 1, 0)
    )
  end

  # Applies one op to the store and to the plain-list oracle, choosing an index
  # deterministically from the current size and the harness's next id.
  defp apply_op({:insert, hash}, {store, model, next_id}) do
    size = length(model)
    index = rem(next_id, size + 1)
    entry = make_entry(next_id, hash)

    {
      ResidentStore.insert_at(store, index, entry),
      List.insert_at(model, index, entry),
      next_id + 1
    }
  end

  defp apply_op(:delete, {store, [], next_id}), do: {store, [], next_id}

  defp apply_op(:delete, {store, model, next_id}) do
    size = length(model)
    index = rem(next_id, size)
    {ResidentStore.delete_at(store, index), List.delete_at(model, index), next_id}
  end

  defp apply_op({:replace, _hash}, {store, [], next_id}), do: {store, [], next_id}

  defp apply_op({:replace, hash}, {store, model, next_id}) do
    size = length(model)
    index = rem(next_id, size)
    existing = Enum.at(model, index)
    entry = make_entry(existing.id, hash)

    {
      ResidentStore.replace_at(store, index, entry),
      List.replace_at(model, index, entry),
      next_id + 1
    }
  end

  defp assert_consistent(store, model) do
    assert ResidentStore.entries(store) == model

    assert ResidentStore.digest(store) ==
             ContentDigest.of_pairs(Enum.map(model, &{&1.id, &1.content_hash}))
  end

  # ── Property (a) + (b): incremental == from-scratch after every step ─────

  describe "property: incremental store equals from-scratch rebuild" do
    property "entries and digest match the oracle after every mutation" do
      check all(
              initial <- list_of(content_hash_gen(), max_length: 20),
              ops <- op_list_gen()
            ) do
        initial_entries =
          initial
          |> Enum.with_index()
          |> Enum.map(fn {hash, id} -> make_entry(id, hash) end)

        store0 = ResidentStore.from_entries(initial_entries)
        assert_consistent(store0, initial_entries)

        Enum.reduce(ops, {store0, initial_entries, length(initial_entries)}, fn op, acc ->
          {store, model, next_id} = apply_op(op, acc)
          # Assert equality after EVERY step so a mid-sequence divergence fails here.
          assert_consistent(store, model)
          assert length(model) <= @max_rows
          {store, model, next_id}
        end)
      end
    end
  end

  # ── Property (c): digest change detection ────────────────────────────────

  describe "property: digest changes iff a row changed" do
    property "editing a row back to its original content restores the prior digest" do
      check all(
              hashes <- list_of(content_hash_gen(), min_length: 1, max_length: 30),
              other_hash <- content_hash_gen()
            ) do
        entries =
          hashes
          |> Enum.with_index()
          |> Enum.map(fn {hash, id} -> make_entry(id, hash) end)

        store = ResidentStore.from_entries(entries)
        index = rem(other_hash, length(entries))
        original = Enum.at(entries, index)

        changed =
          ResidentStore.replace_at(store, index, make_entry(original.id, other_hash))

        restored =
          ResidentStore.replace_at(changed, index, original)

        if other_hash == original.content_hash do
          assert ResidentStore.digest(changed) == ResidentStore.digest(store)
        end

        assert ResidentStore.digest(restored) == ResidentStore.digest(store)
        assert ResidentStore.entries(restored) == entries
      end
    end
  end

  # ── rebuild/3 splice (the builder's in-place-edit path) ──────────────────

  describe "rebuild/3" do
    test "an empty dirty set returns the store unchanged (scroll/cursor frame)" do
      entries = for i <- 0..9, do: make_entry(i, i)
      store = ResidentStore.from_entries(entries)

      rebuilt = ResidentStore.rebuild(store, MapSet.new(), fn _ -> raise "must not build" end)

      assert rebuilt == store
      assert ResidentStore.digest(rebuilt) == ResidentStore.digest(store)
    end

    test "only dirty indices are rebuilt and the digest updates incrementally" do
      entries = for i <- 0..9, do: make_entry(i, i)
      store = ResidentStore.from_entries(entries)

      dirty = MapSet.new([3, 7])
      built = fn index -> make_entry(index, index + 100) end

      rebuilt = ResidentStore.rebuild(store, dirty, built)

      expected_entries =
        entries
        |> List.replace_at(3, built.(3))
        |> List.replace_at(7, built.(7))

      assert ResidentStore.entries(rebuilt) == expected_entries

      assert ResidentStore.digest(rebuilt) ==
               ContentDigest.of_pairs(Enum.map(expected_entries, &{&1.id, &1.content_hash}))
    end

    test "projects VisualRow payload positions while preserving the typed payload" do
      entries = [visual_entry(10), visual_entry(11), visual_entry(12)]
      store = ResidentStore.from_entries(entries)

      store = ResidentStore.insert_at(store, 0, visual_entry(9))

      assert {:ok, %VisualRow{buf_line: 2, row: %Row{buf_line: 2}} = payload} =
               ResidentStore.payload_at(store, 2)

      assert payload.row.row_id == Enum.at(entries, 1).id

      assert [
               %VisualRow{buf_line: 1, row: %Row{buf_line: 1}},
               %VisualRow{buf_line: 2, row: %Row{buf_line: 2}}
             ] =
               ResidentStore.payload_range(store, 1, 2)
    end

    property "rebuild equals replacing the dirty positions from scratch" do
      check all(
              size <- integer(1..40),
              hashes <- list_of(content_hash_gen(), length: size),
              dirty_list <- list_of(integer(0..(size - 1)), max_length: size),
              new_hashes <- list_of(content_hash_gen(), length: size)
            ) do
        entries =
          hashes
          |> Enum.with_index()
          |> Enum.map(fn {hash, id} -> make_entry(id, hash) end)

        store = ResidentStore.from_entries(entries)
        dirty = MapSet.new(dirty_list)
        build_fun = fn index -> make_entry(index, Enum.at(new_hashes, index)) end

        rebuilt = ResidentStore.rebuild(store, dirty, build_fun)

        expected =
          Enum.reduce(dirty, entries, fn index, acc ->
            List.replace_at(acc, index, build_fun.(index))
          end)

        assert ResidentStore.entries(rebuilt) == expected

        assert ResidentStore.digest(rebuilt) ==
                 ContentDigest.of_pairs(Enum.map(expected, &{&1.id, &1.content_hash}))
      end
    end
  end

  describe "persistent mutation work counters" do
    test "counts rows copied by both split boundaries and the inserted row" do
      entries = for i <- 0..63, do: make_entry(i, i)
      store = ResidentStore.from_entries(entries)
      changed = ResidentStore.replace_at(store, 32, make_entry(32, 999))

      assert ResidentStore.work(changed) == %{
               # The removed entry and replacement are both examined for digest updates.
               rows_visited: 2,
               # Split 32/32 copies 64 rows, splitting its 32-row tail copies 32,
               # and the replacement copies one: no boundary work is hidden.
               rows_copied: 97,
               rows_emitted: 1,
               chunks_touched: 11
             }
    end

    test "an edit on the 64-row chunk boundary reports its actual smaller copy" do
      entries = for i <- 0..64, do: make_entry(i, i)
      store = ResidentStore.from_entries(entries)
      changed = ResidentStore.replace_at(store, 64, make_entry(64, 999))

      assert ResidentStore.work(changed) == %{
               rows_visited: 2,
               rows_copied: 2,
               rows_emitted: 1,
               chunks_touched: 5
             }
    end

    @tag :perf
    test "a 65,536-row one-line edit has fixed row work and logarithmic chunk work" do
      small_entries = for i <- 0..255, do: make_entry(i, i)
      large_entries = for i <- 0..65_535, do: make_entry(i, i)

      small =
        small_entries
        |> ResidentStore.from_entries()
        |> ResidentStore.replace_at(64, make_entry(64, 999))
        |> ResidentStore.work()

      large =
        large_entries
        |> ResidentStore.from_entries()
        |> ResidentStore.replace_at(32_768, make_entry(32_768, 999))
        |> ResidentStore.work()

      assert small.rows_visited == large.rows_visited
      assert small.rows_copied == large.rows_copied
      assert small.rows_emitted == large.rows_emitted
      assert large.rows_copied == 129
      assert large.rows_emitted == 1
      assert large.chunks_touched <= 64
    end
  end

  # ── Edge cases from the test strategy ────────────────────────────────────

  describe "edge cases" do
    test "empty document then first insert" do
      store = ResidentStore.new()
      assert ResidentStore.empty?(store)
      assert ResidentStore.digest(store) == ContentDigest.empty()

      entry = make_entry(0, 7)
      store = ResidentStore.insert_at(store, 0, entry)

      assert ResidentStore.entries(store) == [entry]
      assert ResidentStore.digest(store) == ContentDigest.of_pairs([{0, 7}])
    end

    test "deleting the last remaining row yields a well-defined empty digest" do
      entry = make_entry(0, 7)
      store = ResidentStore.from_entries([entry])

      store = ResidentStore.delete_at(store, 0)

      assert ResidentStore.empty?(store)
      assert ResidentStore.digest(store) == ContentDigest.empty()
    end

    test "two same-frame mutations on adjacent rows both apply (dirty set is a union)" do
      entries = for i <- 0..4, do: make_entry(i, i)
      store = ResidentStore.from_entries(entries)

      dirty = MapSet.new([2, 3])
      rebuilt = ResidentStore.rebuild(store, dirty, fn index -> make_entry(index, index + 50) end)

      assert Enum.at(ResidentStore.entries(rebuilt), 2).content_hash == 52
      assert Enum.at(ResidentStore.entries(rebuilt), 3).content_hash == 53
      # Neighbours untouched.
      assert Enum.at(ResidentStore.entries(rebuilt), 1).content_hash == 1
      assert Enum.at(ResidentStore.entries(rebuilt), 4).content_hash == 4
    end

    test "content edited back to original within one batch produces no digest change" do
      entries = for i <- 0..4, do: make_entry(i, i)
      store = ResidentStore.from_entries(entries)

      # Rebuild index 2 to the SAME content it already had.
      rebuilt =
        ResidentStore.rebuild(store, MapSet.new([2]), fn index -> make_entry(index, index) end)

      assert ResidentStore.digest(rebuilt) == ResidentStore.digest(store)
      assert ResidentStore.entries(rebuilt) == entries
    end
  end
end
