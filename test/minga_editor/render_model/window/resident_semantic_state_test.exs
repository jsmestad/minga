defmodule MingaEditor.RenderModel.Window.ResidentSemanticStateTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Diagnostics.Diagnostic
  alias Minga.RenderModel.Window.{Row, RowDelta, RowSplice}

  alias MingaEditor.RenderModel.Window.{
    ResidentBuild,
    ResidentSemanticState,
    ResidentStore,
    SourceOffsetMap,
    VisualRow
  }

  test "keyframe publishes absolute cursor, selection, sparse layers, and complete disabled guide coverage" do
    resident = resident(["root", "", "    child"], 1)
    {_id, decorations} = Decorations.add_annotation(Decorations.new(), 2, "note")
    decorations = Decorations.build_ann_line_cache(decorations)

    {_state, semantics} =
      ResidentSemanticState.build(
        nil,
        input(resident, hydration_result(), decorations,
          guides_enabled?: false,
          cursor_row: 2,
          cursor_col: 4,
          selection: {:char, {0, 1}, {2, 3}},
          diagnostics_snapshot: {1, [diagnostic(2)]}
        )
      )

    assert semantics.header.mode == :keyframe
    assert semantics.cursor.eligible
    assert semantics.cursor.row == 2
    assert semantics.selection.start_row == 0
    assert semantics.selection.end_row == 2
    assert semantics.guide_cols == []
    assert [%{start_row: 0, end_row: 3, runs: runs}] = semantics.guide_replacements
    assert Enum.map(runs, &{&1.start_row, &1.end_row, &1.level}) == [{0, 1, 0}, {1, 3, 2}]
    assert {:replace, [%{start_row: 2}]} = semantics.diagnostics
    assert {:replace, [%{row: 2, text: "note"}]} = semantics.annotations
  end

  test "guide state stays current while disabled and becomes renderable without a keyframe" do
    first = resident(["root", "", "    child"], 1)

    {state, _keyframe} =
      ResidentSemanticState.build(
        nil,
        input(first, hydration_result(), Decorations.new(), guides_enabled?: false)
      )

    changed_entry = entry(2, "  child")
    second = resident(["root", "", "  child"], 2)
    delta = row_delta(3, [RowSplice.new(2, 1, [changed_entry.row])])

    {state, disabled} =
      ResidentSemanticState.build(
        state,
        input(second, result(delta, [changed_entry]), Decorations.new(), guides_enabled?: false)
      )

    assert disabled.guide_cols == []
    assert [%{runs: [%{level: 1}]}] = disabled.guide_replacements

    {_state, enabled} =
      ResidentSemanticState.build(
        state,
        input(second, result(empty_delta(3), []), Decorations.new(), guides_enabled?: true)
      )

    assert enabled.header.mode == :delta
    assert enabled.guide_cols == [2]
    assert enabled.guide_replacements == []
  end

  test "a resident rehydration publishes a semantic keyframe" do
    first = resident(["one", "two"], 1)

    {state, _} =
      ResidentSemanticState.build(nil, input(first, hydration_result(), Decorations.new()))

    second = resident(["changed", "two"], 2)

    {_state, semantics} =
      ResidentSemanticState.build(
        state,
        input(second, hydration_result(), Decorations.new())
      )

    assert semantics.header.mode == :keyframe
    assert semantics.header.base_revision == 0
    assert [%{start_row: 0, end_row: 2}] = semantics.guide_replacements
  end

  test "overlapping guide continuity updates are canonicalized" do
    first = resident(["root", "", "", "", "    child"], 1)

    {state, _} =
      ResidentSemanticState.build(nil, input(first, hydration_result(), Decorations.new()))

    one = entry(1, "")
    three = entry(3, "")

    delta =
      row_delta(5, [RowSplice.new(1, 1, [one.row]), RowSplice.new(3, 1, [three.row])])

    {_state, semantics} =
      ResidentSemanticState.build(
        state,
        input(first, result(delta, [one, three]), Decorations.new())
      )

    assert [%{start_row: 1, end_row: 5}] = semantics.guide_replacements
  end

  test "dense annotations emit one bounded edited-row replacement" do
    lines = Enum.map(0..9_999, &"line #{&1}")
    first = resident(lines, 1)

    decorations =
      Enum.reduce(0..9_999, Decorations.new(), fn line, acc ->
        {_id, next} = Decorations.add_annotation(acc, line, "note #{line}")
        next
      end)
      |> Decorations.build_ann_line_cache()

    {state, _} =
      ResidentSemanticState.build(nil, input(first, hydration_result(), decorations))

    changed = entry(5_000, "edited")
    second = resident(List.replace_at(lines, 5_000, "edited"), 2)
    delta = row_delta(10_000, [RowSplice.new(5_000, 1, [changed.row])])

    {_state, semantics} =
      ResidentSemanticState.build(
        state,
        input(second, result(delta, [changed]), decorations)
      )

    assert {:replace_ranges, [%{start_row: 5_000, end_row: 5_001, annotations: [%{row: 5_000}]}]} =
             semantics.annotations
  end

  test "structural insertion reconciles a clamped annotation and its shifted old rank" do
    first = resident(["a", "b"], 1)
    {_id, decorations} = Decorations.add_annotation(Decorations.new(), 0, "note")
    {state, _} = ResidentSemanticState.build(nil, input(first, hydration_result(), decorations))

    shifted =
      decorations
      |> Decorations.adjust_for_edit({0, 0}, {0, 0}, {1, 0})
      |> Decorations.build_ann_line_cache()

    inserted = entry(0, "new")
    second = resident(["new", "a", "b"], 2)
    {:ok, delta} = RowDelta.new(2, 3, [RowSplice.new(0, 0, [inserted.row])])

    {_state, semantics} =
      ResidentSemanticState.build(
        state,
        input(second, result(delta, [inserted]), shifted)
      )

    assert {:replace_ranges,
            [%{start_row: 0, end_row: 2, annotations: [%{row: 0, text: "note"}]}]} =
             semantics.annotations
  end

  test "rejects resident extents above the supported cap" do
    oversized = %{resident([], 1) | line_count: 65_537}

    assert_raise ArgumentError, ~r/at most 65,536 rows/, fn ->
      ResidentSemanticState.build(nil, input(oversized, hydration_result(), Decorations.new()))
    end
  end

  defp input(resident, resident_result, decorations, overrides \\ []) do
    Map.merge(
      %{
        window_id: 1,
        content_epoch: 1,
        resident_build: resident,
        resident_result: resident_result,
        keyframe?: false,
        cursor_eligible: true,
        cursor_row: 0,
        cursor_col: 0,
        cursorline_bg: 0x112233,
        selection: nil,
        diagnostics_snapshot: {0, []},
        annotations_revision: decorations.annotation_version,
        decorations: decorations,
        tab_width: 2,
        guides_enabled?: true
      },
      Map.new(overrides)
    )
  end

  defp diagnostic(line) do
    %Diagnostic{
      range: %{start_line: line, start_col: 0, end_line: line, end_col: 1},
      severity: :warning,
      message: "warning"
    }
  end

  defp hydration_result,
    do: %{row_delta: nil, inserted_payloads: []}

  defp result(delta, inserted_payloads),
    do: %{row_delta: delta, inserted_payloads: inserted_payloads}

  defp empty_delta(count), do: row_delta(count, [])

  defp row_delta(count, splices) do
    {:ok, delta} = RowDelta.new(count, count, splices)
    delta
  end

  defp resident(lines, revision) do
    entries = Enum.with_index(lines, fn text, line -> entry(line, text) end)

    %ResidentBuild{
      store:
        ResidentStore.from_entries(
          Enum.map(entries, fn %VisualRow{row: row} = payload ->
            ResidentStore.entry(row.row_id, row.content_hash, payload)
          end)
        ),
      line_count: length(lines),
      revision: revision
    }
  end

  defp entry(line, text) do
    source_map = SourceOffsetMap.new(text, text, Decorations.new(), line)

    %VisualRow{
      row: row(line, text),
      buf_line: line,
      visual_index: 0,
      display_row: line,
      source_text: text,
      source_offset_map: source_map,
      source_start_byte: 0,
      source_end_byte: byte_size(text),
      source_start_col: 0,
      source_end_col: String.length(text),
      composed_start_utf16: 0,
      composed_end_utf16: String.length(text),
      indent_width: 0,
      row_width: String.length(text)
    }
  end

  defp row(line, text) do
    %Row{
      row_id: Row.stable_id(:normal, line + 1),
      row_type: :normal,
      buf_line: line,
      text: text,
      spans: [],
      content_hash: Row.compute_hash(text, [])
    }
  end
end
