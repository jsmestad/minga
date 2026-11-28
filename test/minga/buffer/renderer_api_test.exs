defmodule Minga.Buffer.RendererAPITest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.RenderSnapshot
  alias Minga.Buffer.RendererConsume

  test "renderer consume atomically returns lineage metadata and advances only renderer" do
    buffer = start_supervised!({Buffer, content: "one\ntwo"})
    first = Buffer.renderer_consume(buffer)

    assert %RendererConsume{version: 0, line_count: 2, change_sequence: 0, changes: {:ok, []}} =
             first

    :ok = Buffer.move_to(buffer, {0, 3})
    :ok = Buffer.insert_text(buffer, "\nnew")

    assert %RendererConsume{version: 1, line_count: 3, change_sequence: 1, changes: {:ok, [_]}} =
             Buffer.renderer_consume(buffer)

    assert {:ok, []} = Buffer.consume_edit_deltas(buffer, :renderer)
  end

  test "renderer consume returns one bounded changed snapshot with no Document" do
    buffer = start_supervised!({Buffer, content: "zero\none\ntwo\nthree"})
    _initial = Buffer.renderer_consume(buffer)

    :ok = Buffer.move_to(buffer, {2, 0})
    :ok = Buffer.insert_text(buffer, "changed ")

    assert %RendererConsume{
             version: 1,
             changes: {:ok, [_]},
             snapshot:
               %RenderSnapshot{first_line: 2, lines: ["changed two"], version: 1} = snapshot
           } = Buffer.renderer_consume(buffer)

    refute Map.has_key?(Map.from_struct(snapshot), :document)
  end

  test "retry consume snapshots a prior pending range and a second edit as separate ranges" do
    buffer = start_supervised!({Buffer, content: "zero\none\ntwo\nthree\nfour"})
    _initial = Buffer.renderer_consume(buffer)

    :ok = Buffer.move_to(buffer, {1, 0})
    :ok = Buffer.insert_text(buffer, "A")

    assert %RendererConsume{snapshot: %RenderSnapshot{first_line: 1, lines: ["Aone"]}} =
             Buffer.renderer_consume(buffer)

    :ok = Buffer.move_to(buffer, {3, 0})
    :ok = Buffer.insert_text(buffer, "B")

    assert %RendererConsume{
             version: 2,
             changes: {:ok, [_]},
             snapshot: %RenderSnapshot{
               first_line: 1,
               lines: ["Aone"],
               extra_ranges: [{3, 14, ["Bthree"]}],
               version: 2
             }
           } = Buffer.renderer_consume(buffer, [{1, 1}])
  end

  test "retry range follows pending content shifted by a structural edit" do
    buffer = start_supervised!({Buffer, content: "zero\none\ntwo\nthree\nfour"})
    _initial = Buffer.renderer_consume(buffer)

    :ok = Buffer.move_to(buffer, {3, 0})
    :ok = Buffer.insert_text(buffer, "X")

    assert %RendererConsume{snapshot: %RenderSnapshot{first_line: 3, lines: ["Xthree"]}} =
             Buffer.renderer_consume(buffer)

    :ok = Buffer.move_to(buffer, {0, 0})
    :ok = Buffer.insert_text(buffer, "new\n")

    assert %RendererConsume{
             snapshot: %RenderSnapshot{
               first_line: 0,
               lines: ["new", "zero"],
               extra_ranges: [{4, 17, ["Xthree"]}]
             }
           } = Buffer.renderer_consume(buffer, [{3, 3}])
  end

  test "two edits far apart in one consume are read as two ranges, without the lines between" do
    content = Enum.map_join(0..999, "\n", &"line #{&1}")
    buffer = start_supervised!({Buffer, content: content})
    _initial = Buffer.renderer_consume(buffer)

    :ok = Buffer.move_to(buffer, {10, 0})
    :ok = Buffer.insert_text(buffer, "above\n")
    :ok = Buffer.move_to(buffer, {900, 0})
    :ok = Buffer.insert_text(buffer, "below\n")

    assert %RendererConsume{
             changes: {:ok, [_, _]},
             snapshot: %RenderSnapshot{
               first_line: 10,
               lines: ["above", "line 10"],
               extra_ranges: [{900, _offset, ["below", "line 899"]}]
             }
           } = Buffer.renderer_consume(buffer)
  end

  test "edits on touching lines are read as one range" do
    buffer = start_supervised!({Buffer, content: "zero\none\ntwo\nthree"})
    _initial = Buffer.renderer_consume(buffer)

    :ok = Buffer.move_to(buffer, {1, 0})
    :ok = Buffer.insert_text(buffer, "A")
    :ok = Buffer.move_to(buffer, {2, 0})
    :ok = Buffer.insert_text(buffer, "B")

    assert %RendererConsume{
             snapshot: %RenderSnapshot{first_line: 1, lines: ["Aone", "Btwo"], extra_ranges: []}
           } = Buffer.renderer_consume(buffer)
  end

  test "version-checked range fetch returns no Document and rejects an intervening edit" do
    buffer = start_supervised!({Buffer, content: "zero\none\ntwo\nthree"})
    consume = Buffer.renderer_consume(buffer)

    assert {:ok, %RenderSnapshot{lines: ["one", "two"], first_line: 1} = view} =
             Buffer.render_lines(buffer, consume.version, 1, 2)

    refute Map.has_key?(Map.from_struct(view), :document)
    assert :erlang.external_size(view) < 10_000

    :ok = Buffer.insert_text(buffer, "changed")
    assert :stale = Buffer.render_lines(buffer, consume.version, 1, 2)
  end

  test "Keep changes the authored gutter lease without a text resnapshot or edit delta" do
    buffer = start_supervised!({Buffer, content: "one\ntwo"}, id: :reviewed)
    other = start_supervised!({Buffer, content: "one\ntwo"}, id: :other)
    source = EditSource.minga("task", "step")
    assert :ok = Buffer.apply_edit(buffer, 0, 0, 0, 2, "ONE", source)
    assert :ok = Buffer.apply_edit(other, 0, 0, 0, 2, "ONE", source)

    before = Buffer.renderer_consume(buffer)

    assert {:ok, [{:text, _group, {0, 0}, 0}]} =
             Buffer.render_review_regions(buffer, before.review_lease, [{0, 0}])

    assert {:ok, []} = Buffer.render_review_regions(buffer, before.review_lease, [{1, 1}])
    assert :stale = Buffer.render_review_regions(other, before.review_lease, [{0, 0}])

    assert {:ok, target, {:minga, "task"}, 1} = Buffer.prepare_review(buffer, :latest)
    assert :ok = Buffer.decide_review(buffer, target, :keep)

    assert %RendererConsume{changes: {:ok, []}, snapshot: nil} =
             kept = Buffer.renderer_consume(buffer)

    assert kept.version == before.version
    assert kept.change_sequence == before.change_sequence
    assert :stale = Buffer.render_review_regions(buffer, before.review_lease, [{0, 0}])

    assert {:ok, [{:kept, {0, 0}, 0}]} =
             Buffer.render_review_regions(buffer, kept.review_lease, [{0, 0}])
  end

  test "task review offers precise locations and cannot decide an obsolete unit" do
    buffer = start_supervised!({Buffer, content: "abc\nmiddle\nend\n"})

    edit = fn position, length, text, source ->
      assert {:ok, _} =
               Minga.Buffer.Process.replace_byte_range_if_version(
                 buffer,
                 Buffer.version(buffer),
                 position,
                 length,
                 text,
                 source
               )
    end

    source = EditSource.minga("task", "one step")
    edit.({0, 0}, 3, "ABC", source)
    edit.({2, 0}, 3, "END", source)

    assert {[{unit, offered, [{{0, 0}, {0, 3}}, {{2, 0}, {2, 3}}]}], all, {0, 0}} =
             Buffer.task_review_entries(buffer, "task")

    assert {:ok, "abc\nmiddle\nend\n", "ABC\nmiddle\nEND\n"} =
             Buffer.preview_review(buffer, offered)

    assert Buffer.content(buffer) == "ABC\nmiddle\nEND\n"

    assert {[], nil, {0, 0}} = Buffer.task_review_entries(buffer, "different")
    edit.({1, 0}, 6, "MIDDLE", EditSource.minga("other", "one"))
    assert {:error, :stale_review} = Buffer.preview_review(buffer, offered)
    assert {:error, :stale_review} = Buffer.decide_review(buffer, offered, :keep)

    assert {:error, :stale_review} = Buffer.decide_review(buffer, all, :keep)
    assert {[{^unit, fresh, _}], _, {0, 0}} = Buffer.task_review_entries(buffer, "task")
    assert :ok = Buffer.decide_review(buffer, fresh, :keep)
    assert {[], nil, {1, 0}} = Buffer.task_review_entries(buffer, "task")
    assert {[{_, _, [{{1, 0}, {1, 6}}]}], _, {0, 0}} = Buffer.task_review_entries(buffer, "other")
    assert Buffer.content(buffer) == "ABC\nMIDDLE\nEND\n"
  end

  test "a task's aggregate offer keeps its distinct units together" do
    buffer = start_supervised!({Buffer, content: "abc\nmiddle\nend"})
    assert :ok = Buffer.apply_edit(buffer, 0, 0, 0, 2, "ABC", EditSource.minga("task", "first"))
    assert :ok = Buffer.apply_edit(buffer, 2, 0, 2, 2, "END", EditSource.minga("task", "second"))
    assert {[_, _], all, {0, 0}} = Buffer.task_review_entries(buffer, "task")
    assert :ok = Buffer.decide_review(buffer, all, :keep)
    assert {[], nil, {2, 0}} = Buffer.task_review_entries(buffer, "task")
    assert Buffer.content(buffer) == "ABC\nmiddle\nEND"
  end

  @tag :tmp_dir
  test "review locations relocate across edits but cannot name replacement history", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "replacement.txt")
    File.write!(path, "first\nsecond")
    buffer = start_supervised!({Buffer, content: "first\nsecond", swap_dir: nil})
    source = EditSource.minga("task", "one")

    assert :ok = Buffer.apply_edit(buffer, 1, 0, 1, 5, "SECOND", source)
    assert {[{location, _, _}], _, {0, 0}} = Buffer.task_review_entries(buffer, "task")
    assert :ok = Buffer.move_to(buffer, {0, 0})
    assert :ok = Buffer.insert_text(buffer, "added\n")
    assert {:ok, {2, 0}} = Buffer.move_to_review_unit(buffer, location)

    assert :ok = Buffer.open(buffer, path)
    assert :ok = Buffer.apply_edit(buffer, 1, 0, 1, 5, "NEW", source)
    assert {[{fresh, _, _}], _, {0, 0}} = Buffer.task_review_entries(buffer, "task")
    assert :unavailable = Buffer.move_to_review_unit(buffer, location)
    assert {:ok, {1, 0}} = Buffer.move_to_review_unit(buffer, fresh)
  end

  test "multiple Keeps report disjoint damage bounded to affected rows and their joins" do
    buffer = start_supervised!({Buffer, content: "abc\nmiddle\nuntouched\nlast\nend\n"})
    assert :ok = Buffer.apply_edit(buffer, 0, 0, 0, 2, "ABC", EditSource.minga("one", "one"))

    assert {:ok, _} =
             Minga.Buffer.Process.replace_byte_range_if_version(
               buffer,
               Buffer.version(buffer),
               {4, 3},
               1,
               "",
               EditSource.minga("two", "two")
             )

    assert %RendererConsume{review_lease: before, review_damage: :reset_required} =
             Buffer.renderer_consume(buffer)

    for name <- ["one", "two"] do
      task = {:minga, name}
      assert {:ok, target, ^task, 1} = Buffer.prepare_review(buffer, {:task, task})
      assert :ok = Buffer.decide_review(buffer, target, :keep)
    end

    assert %RendererConsume{
             review_lease: after_keep,
             review_damage: {:since, ^before, [{0, 1}, {3, 4}]},
             changes: {:ok, []},
             snapshot: nil
           } = Buffer.renderer_consume(buffer)

    assert %RendererConsume{review_damage: {:since, ^after_keep, []}} =
             Buffer.renderer_consume(buffer)
  end

  test "a presented ribbon prepares exactly its grouped units without using the caret" do
    buffer = start_supervised!({Buffer, content: "one\ntwo\nthree\nunchanged\nfour\n"})

    for {row, old, new} <- [{0, "one", "ONE"}, {1, "two", "TWO"}, {2, "three", "THREE"}] do
      source = EditSource.minga("task", new)
      assert :ok = Buffer.apply_edit(buffer, row, 0, row, byte_size(old), new, source)
    end

    assert :ok = Buffer.apply_edit(buffer, 4, 0, 4, 4, "FOUR", EditSource.minga("other", "four"))
    assert :ok = Buffer.move_to(buffer, {4, 0})
    %{review_lease: lease, version: version} = Buffer.renderer_consume(buffer)

    assert {:ok, [{:text, first, {0, 0}, 2}]} =
             Buffer.render_review_regions(buffer, lease, [{1, 1}])

    assert {:ok, [{:text, other, {4, 0}, 4}]} =
             Buffer.render_review_regions(buffer, lease, [{4, 4}])

    assert {:error, :stale_selection} =
             Buffer.prepare_review(buffer, {:presented_ribbon, lease, {:text, first, {1, 0}}})

    assert {:ok, target, _, 3} =
             Buffer.prepare_review(buffer, {:presented_ribbon, lease, {:text, first, {0, 0}}})

    assert Buffer.cursor(buffer) == {4, 0}
    assert :ok = Buffer.decide_review(buffer, target, :keep)
    assert Buffer.version(buffer) == version

    assert {:error, :stale_selection} =
             Buffer.prepare_review(buffer, {:presented_ribbon, lease, {:text, other, {4, 0}}})

    assert {:ok, _, _, 1} = Buffer.prepare_review(buffer, {:cursor, 1})
  end

  test "a presented deletion head still identifies its exact unit at the end of file" do
    buffer = start_supervised!({Buffer, content: "before tail"})
    assert :ok = Buffer.apply_edit(buffer, 0, 6, 0, 11, "", EditSource.minga("task", "delete"))
    %{review_lease: lease} = Buffer.renderer_consume(buffer)

    assert {:ok, [{:gap, id, {0, 6}} = head]} =
             Buffer.render_review_regions(buffer, lease, [{0, 0}])

    assert {:error, :stale_selection} =
             Buffer.prepare_review(buffer, {:presented_ribbon, lease, {:text, id, {0, 6}}})

    assert {:ok, target, _, 1} = Buffer.prepare_review(buffer, {:presented_ribbon, lease, head})

    assert {:ok, [_receipt]} = Buffer.decide_review(buffer, target, :reject)
    assert Buffer.content(buffer) == "before tail"
  end

  test "review regions join adjacent pieces without bridging disjoint work from the same unit" do
    buffer = start_supervised!({Buffer, content: "abcdef\nmid\nuvwxyz"})
    source = EditSource.minga("task", "resumed")
    other = EditSource.minga("other", "different")

    for {position, count, text, author} <- [
          {{0, 0}, 2, "AB", source},
          {{1, 0}, 1, "M", other},
          {{0, 2}, 2, "CD", source},
          {{2, 1}, 2, "VW", source}
        ] do
      assert {:ok, _} =
               Minga.Buffer.Process.replace_byte_range_if_version(
                 buffer,
                 Buffer.version(buffer),
                 position,
                 count,
                 text,
                 author
               )
    end

    %{review_lease: lease} = Buffer.renderer_consume(buffer)

    assert {:ok, [{:text, unit, {0, 0}, 0}]} =
             Buffer.render_review_regions(buffer, lease, [{0, 0}])

    assert {:ok, [{:text, ^unit, {2, 1}, 2}]} =
             Buffer.render_review_regions(buffer, lease, [{2, 2}])

    assert {:ok,
            [
              {:text, ^unit, {0, 0}, 0},
              {:text, other_unit, {1, 0}, 1},
              {:text, ^unit, {2, 1}, 2}
            ]} = Buffer.render_review_regions(buffer, lease, [{0, 2}])

    assert {:ok, [{:text, ^unit, {0, 0}, 0}, {:text, ^unit, {2, 1}, 2}]} =
             Buffer.render_review_regions(buffer, lease, [{0, 0}, {2, 2}])

    assert other_unit != unit
  end

  test "human edits contribute a bounded strand without hiding the pending review identity" do
    buffer = start_supervised!({Buffer, content: "abc\nplain\nlast"})
    assert :ok = Buffer.apply_edit(buffer, 0, 0, 0, 2, "ABC", EditSource.minga("task", "step"))
    :ok = Buffer.move_to(buffer, {0, 1})
    :ok = Buffer.insert_text(buffer, "!")
    :ok = Buffer.move_to(buffer, {1, 0})
    :ok = Buffer.insert_text(buffer, ">")
    %{review_lease: lease} = Buffer.renderer_consume(buffer)

    assert {:ok, [{:text, _unit, {0, 0}, 0}, {:you, {0, 1}, 0}]} =
             Buffer.render_review_regions(buffer, lease, [{0, 0}])

    assert {:ok, [{:you, {1, 0}, 1}]} = Buffer.render_review_regions(buffer, lease, [{1, 1}])
    assert {:ok, []} = Buffer.render_review_regions(buffer, lease, [{2, 2}])

    :ok = Buffer.move_to(buffer, {0, 1})
    assert :empty = Buffer.prepare_review(buffer, {:cursor, 1})
    :ok = Buffer.move_to(buffer, {0, 2})
    assert {:ok, _, {:minga, "task"}, 1} = Buffer.prepare_review(buffer, {:cursor, 1})
  end

  test "a fully replaced authored row has a shared strand without a new review head" do
    buffer = start_supervised!({Buffer, content: "before\nmiddle\nend\n"})
    source = EditSource.minga("task", "step")
    :ok = Buffer.move_to(buffer, {1, 0})
    assert :ok = Buffer.insert_text(buffer, "one\ntwo\n", source)
    :ok = Buffer.move_to(buffer, {4, 0})
    assert :ok = Buffer.insert_text(buffer, "three\n", source)

    assert {:ok, _} =
             Minga.Buffer.Process.replace_byte_range_if_version(
               buffer,
               Buffer.version(buffer),
               {2, 0},
               4,
               "TWO>",
               EditSource.user()
             )

    :ok = Buffer.move_to(buffer, {4, 0})
    assert :ok = Buffer.insert_text(buffer, "!")

    %{review_lease: pending} = Buffer.renderer_consume(buffer)
    assert {:ok, [{:shared, {2, 0}, 2}]} = Buffer.render_review_regions(buffer, pending, [{2, 2}])
    assert {:ok, [{:you, {4, 0}, 4}]} = Buffer.render_review_regions(buffer, pending, [{4, 4}])
    assert :ok = Buffer.move_to(buffer, {1, 0})
    assert {:ok, {3, 0}} = Buffer.move_to_review_change(buffer, :next, 1)

    assert {:ok, target, _, 1} = Buffer.prepare_review(buffer, :latest)
    assert :ok = Buffer.decide_review(buffer, target, :keep)

    %{review_lease: kept, review_damage: {:since, ^pending, damage}} =
      Buffer.renderer_consume(buffer)

    assert Enum.any?(damage, fn {first, last} -> first <= 2 and last >= 2 end)
    assert {:ok, [{:you, {2, 0}, 2}]} = Buffer.render_review_regions(buffer, kept, [{2, 2}])
  end

  test "a human replacement sweeping an already deleted Minga byte remains human" do
    buffer = start_supervised!({Buffer, content: "ab\n"})
    :ok = Buffer.move_to(buffer, {0, 1})
    assert :ok = Buffer.insert_text(buffer, "X", EditSource.minga("task", "step"))
    :ok = Buffer.move_to(buffer, {0, 1})
    assert :ok = Buffer.delete_at(buffer)
    assert :ok = Buffer.apply_edit(buffer, 0, 0, 0, 1, "AB")
    assert Buffer.content(buffer) == "AB\n"
    %{review_lease: lease} = Buffer.renderer_consume(buffer)
    assert {:ok, [{:you, {0, 0}, 0}]} = Buffer.render_review_regions(buffer, lease, [{0, 0}])
  end

  test "a trailing empty line owns the EOF review gap" do
    buffer = start_supervised!({Buffer, content: "one\nx"})
    assert :ok = Buffer.apply_edit(buffer, 1, 0, 1, 0, "", EditSource.minga("task", "step"))
    %{review_lease: lease} = Buffer.renderer_consume(buffer)

    assert {:ok, []} = Buffer.render_review_regions(buffer, lease, [{0, 0}])
    assert {:ok, [{:gap, _group, {1, 0}}]} = Buffer.render_review_regions(buffer, lease, [{1, 1}])
    assert {:ok, []} = Buffer.render_review_regions(buffer, lease, [{2, 2}])

    assert {:ok, target, {:minga, "task"}, 1} = Buffer.prepare_review(buffer, :latest)
    assert :ok = Buffer.decide_review(buffer, target, :keep)
    %{review_lease: kept} = Buffer.renderer_consume(buffer)

    assert {:ok, []} = Buffer.render_review_regions(buffer, kept, [{0, 0}])
    assert {:ok, [{:kept, {1, 0}, 1}]} = Buffer.render_review_regions(buffer, kept, [{1, 1}])
    assert :empty = Buffer.prepare_review(buffer, :latest)
  end

  test "an EOF deletion stays on its own line when the same unit inserted the preceding line" do
    buffer = start_supervised!({Buffer, content: "x"})
    source = EditSource.minga("task", "step")
    edit_at(buffer, {0, 0}, 0, "A\n", source)
    edit_at(buffer, {1, 0}, 1, "", source)

    %{review_lease: lease} = Buffer.renderer_consume(buffer)

    assert {:ok, [{:text, unit, {0, 0}, 0}, {:gap, unit, {1, 0}}]} =
             Buffer.render_review_regions(buffer, lease, [{0, 1}])
  end

  test "split or clipped visible ranges preserve the original head of the same continuous change" do
    buffer = start_supervised!({Buffer, content: "z"})
    step = EditSource.minga("task", "step")
    edit_at(buffer, {0, 0}, 0, "A\n", step)
    edit_at(buffer, {1, 0}, 1, "Z", EditSource.minga("other", "different"))
    edit_at(buffer, {1, 0}, 0, "B\nC\nD\nE", step)

    %{review_lease: lease} = Buffer.renderer_consume(buffer)

    assert {:ok, [{:text, first, {0, 0}, 4}, {:text, other, {4, 1}, 4}]} =
             Buffer.render_review_regions(buffer, lease, [{0, 1}, {3, 4}])

    assert first != other

    assert {:ok, [{:text, ^first, {0, 0}, 4}, {:text, ^other, {4, 1}, 4}]} =
             Buffer.render_review_regions(buffer, lease, [{3, 4}])
  end

  defp edit_at(buffer, position, count, text, author) do
    assert {:ok, _} =
             Minga.Buffer.Process.replace_byte_range_if_version(
               buffer,
               Buffer.version(buffer),
               position,
               count,
               text,
               author
             )
  end

  # Replacing the whole document from a file records no deltas, so the
  # renderer must be told to rebuild its line lineage instead of being handed
  # an empty change list for content it has never seen.
  @tag :tmp_dir
  test "replacing content from disk requires the renderer to rebuild its lineage",
       %{tmp_dir: dir} do
    path = Path.join(dir, "notes.md")
    other = Path.join(dir, "other.md")
    File.write!(path, "one\ntwo\n")
    File.write!(other, "a\nb\nc\nd\ne\n")

    replacements = [
      reload: fn buffer ->
        File.write!(path, "one\ntwo\nthree\nfour\n")
        Buffer.reload(buffer)
      end,
      open: fn buffer -> Buffer.open(buffer, other) end
    ]

    for {operation, replace} <- replacements do
      buffer = start_supervised!({Buffer, file_path: path}, id: operation)
      before = Buffer.renderer_consume(buffer)

      assert :ok = replace.(buffer)

      assert %RendererConsume{changes: :reset_required} =
               consumed = Buffer.renderer_consume(buffer)

      assert consumed.change_sequence > before.change_sequence, "#{operation} kept the sequence"
      assert consumed.line_count != before.line_count
    end
  end
end
