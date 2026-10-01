defmodule MingaEditor.RenderModel.Window.DiagnosticIndexTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Diagnostics.Diagnostic
  alias Minga.RenderModel.Window.{DiagnosticRange, Row, RowSplice}

  alias MingaEditor.RenderModel.Window.{
    DiagnosticIndex,
    ResidentBuild,
    ResidentStore,
    SourceOffsetMap,
    VisualRow
  }

  test "projects UTF-8, UTF-16, and UTF-32 endpoints from retained source rows" do
    resident = resident(["zero", "a😀b"])

    index =
      DiagnosticIndex.build(
        [
          diagnostic(1, 5, 6, :utf8),
          diagnostic(1, 3, 4, :utf16),
          diagnostic(1, 2, 3, :utf32)
        ],
        resident
      )

    assert Enum.map(DiagnosticIndex.to_ranges(index), &{&1.start_col, &1.end_col}) == [
             {5, 6},
             {5, 6},
             {5, 6}
           ]
  end

  test "unrelated dense diagnostics stay retained with constant splice work" do
    lines = Enum.map(0..9_999, &"line #{&1}")
    resident = resident(lines)

    diagnostics =
      Enum.map(1_000..9_999, fn line -> diagnostic(line, 0, 1, :utf8) end)

    index = DiagnosticIndex.build(diagnostics, resident)
    splice = RowSplice.new(5, 1, [row(5, "edited")])
    edited = resident(List.replace_at(lines, 5, "edited"), 2)

    {updated, starts, work} = DiagnosticIndex.apply_splices(index, [splice], edited)

    assert starts == []
    assert work == %{groups_reprojected: 0, suffix_shifts: 0}
    assert Enum.count(DiagnosticIndex.to_ranges(updated)) == 9_000
  end

  test "in-place edits reproject only diagnostic start groups whose endpoint is touched" do
    first = resident(["start", "middle", "a😀b"])
    index = DiagnosticIndex.build([diagnostic(0, 1, 3, :utf16, 2)], first)
    edited = resident(["start", "middle", "aa😀b"], 2)
    splice = RowSplice.new(2, 1, [row(2, "aa😀b")])

    {updated, starts, work} = DiagnosticIndex.apply_splices(index, [splice], edited)

    assert starts == [0]
    assert work == %{groups_reprojected: 1, suffix_shifts: 0}

    assert [%{start_row: 0, end_row: 2, end_col: end_col}] =
             DiagnosticIndex.ranges_at(updated, starts)

    expected = diagnostic(0, 1, 3, :utf16, 2)
    assert {_row, ^end_col} = Diagnostic.end_position(expected, "aa😀b")
  end

  test "structural edits lazily shift suffix diagnostics and adjust multiline crossings" do
    resident = resident(["zero", "one", "two", "three"])

    index =
      DiagnosticIndex.build(
        [diagnostic(0, 0, 1, :utf8, 2), diagnostic(3, 0, 1, :utf8)],
        resident
      )

    splice = RowSplice.new(1, 1, [])
    edited = resident(["zero", "two", "three"], 2)
    {updated, starts, work} = DiagnosticIndex.apply_splices(index, [splice], edited)

    assert starts == []
    assert work == %{groups_reprojected: 1, suffix_shifts: 1}

    assert DiagnosticIndex.to_ranges(updated) == [
             %DiagnosticRange{
               start_row: 0,
               start_col: 0,
               end_row: 1,
               end_col: 1,
               severity: :error
             },
             %DiagnosticRange{
               start_row: 2,
               start_col: 0,
               end_row: 2,
               end_col: 1,
               severity: :error
             }
           ]
  end

  test "deleting a diagnostic start removes stale diagnostics" do
    resident = resident(["zero", "one", "two"])
    index = DiagnosticIndex.build([diagnostic(1, 0, 1, :utf8)], resident)
    edited = resident(["zero", "two"], 2)

    {updated, starts, work} =
      DiagnosticIndex.apply_splices(index, [RowSplice.new(1, 1, [])], edited)

    assert starts == []
    assert work.suffix_shifts == 1
    assert DiagnosticIndex.to_ranges(updated) == []
  end

  defp diagnostic(start_line, start_col, end_col, encoding, end_line \\ nil) do
    %Diagnostic{
      range: %{
        start_line: start_line,
        start_col: start_col,
        end_line: end_line || start_line,
        end_col: end_col
      },
      severity: :error,
      message: "diagnostic",
      encoding: encoding
    }
  end

  defp resident(lines, revision \\ 1) do
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
