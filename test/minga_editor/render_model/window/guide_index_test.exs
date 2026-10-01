defmodule MingaEditor.RenderModel.Window.GuideIndexTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.RenderModel.Window.{ResidentSemantics.GuideRun, Row}
  alias MingaEditor.RenderModel.Window.{GuideIndex, SourceOffsetMap, VisualRow}

  test "blank continuity updates as one compressed range without visiting the blank suffix" do
    entries =
      [entry(0, "root")] ++ Enum.map(1..10_000, &entry(&1, "")) ++ [entry(10_001, "    leaf")]

    index = GuideIndex.build(entries, 2)

    assert GuideIndex.all_runs(index) == [
             %GuideRun{start_row: 0, end_row: 1, level: 0},
             %GuideRun{start_row: 1, end_row: 10_002, level: 2}
           ]

    updated = GuideIndex.splice(index, 10_001, 1, [entry(10_001, "  leaf")], 2)
    assert GuideIndex.affected_bounds(updated, 10_001, 1) == {1, 10_002}
    assert GuideIndex.work(updated, 1, 10_002) == 1

    assert GuideIndex.runs(updated, 1, 10_002) == [
             %GuideRun{start_row: 1, end_row: 10_002, level: 1}
           ]
  end

  test "structural splices shift unchanged nonblank suffixes lazily" do
    index = GuideIndex.build([entry(0, "root"), entry(1, "  one"), entry(2, "    two")], 2)
    updated = GuideIndex.splice(index, 0, 0, [entry(0, "inserted")], 2)

    assert updated.row_count == 4

    assert GuideIndex.all_runs(updated) == [
             %GuideRun{start_row: 0, end_row: 2, level: 0},
             %GuideRun{start_row: 2, end_row: 3, level: 1},
             %GuideRun{start_row: 3, end_row: 4, level: 2}
           ]
  end

  defp entry(line, text) do
    map = SourceOffsetMap.new(text, text, Decorations.new(), line)

    %VisualRow{
      row: %Row{
        row_id: Row.stable_id(:normal, line + 1),
        row_type: :normal,
        buf_line: line,
        text: text,
        spans: [],
        content_hash: Row.compute_hash(text, [])
      },
      buf_line: line,
      visual_index: 0,
      display_row: line,
      source_text: text,
      source_offset_map: map,
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
end
