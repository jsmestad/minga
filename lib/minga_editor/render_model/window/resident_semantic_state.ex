defmodule MingaEditor.RenderModel.Window.ResidentSemanticState do
  @moduledoc "Renderer-owned persistent state for bounded resident semantic updates."

  alias Minga.Core.Decorations
  alias Minga.Diagnostics.Diagnostic

  alias Minga.RenderModel.Window.{
    Annotation,
    ResidentSemantics,
    RowDelta,
    RowSplice
  }

  alias Minga.RenderModel.Window.ResidentSemantics.{
    AnnotationReplace,
    Cursor,
    Cursorline,
    DiagnosticReplace,
    GuideReplace,
    Header,
    Selection
  }

  alias MingaEditor.RenderModel.Window.{
    DiagnosticIndex,
    GuideIndex,
    ResidentBuild,
    ResidentStore,
    VisualRow
  }

  @enforce_keys [
    :content_epoch,
    :revision,
    :row_revision,
    :row_count,
    :guide_index,
    :tab_width,
    :diagnostics_revision,
    :diagnostic_index,
    :annotations_revision
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          content_epoch: non_neg_integer(),
          revision: pos_integer(),
          row_revision: pos_integer(),
          row_count: non_neg_integer(),
          guide_index: GuideIndex.t(),
          tab_width: pos_integer(),
          diagnostics_revision: non_neg_integer(),
          diagnostic_index: DiagnosticIndex.t(),
          annotations_revision: non_neg_integer()
        }

  @type input :: %{
          required(:window_id) => pos_integer(),
          required(:content_epoch) => non_neg_integer(),
          required(:resident_build) => ResidentBuild.t(),
          required(:resident_result) => map(),
          required(:keyframe?) => boolean(),
          required(:cursor_eligible) => boolean(),
          required(:cursor_row) => non_neg_integer(),
          required(:cursor_col) => non_neg_integer(),
          required(:cursorline_bg) => non_neg_integer() | nil,
          required(:selection) => term(),
          required(:diagnostics_snapshot) => {non_neg_integer(), [Diagnostic.t()]},
          required(:annotations_revision) => non_neg_integer(),
          required(:decorations) => Decorations.t(),
          required(:tab_width) => pos_integer(),
          required(:guides_enabled?) => boolean()
        }

  @spec build(t() | nil, input()) :: {t(), ResidentSemantics.t()}
  def build(previous, input) do
    %ResidentBuild{} = resident = input.resident_build
    validate_row_count!(resident.line_count)
    keyframe? = keyframe?(previous, input)
    guide_index = next_guide_index(previous, resident, input, keyframe?)
    row_splices = semantic_row_splices(input.resident_result.row_delta)
    guide_replacements = guide_replacements(previous, guide_index, input, keyframe?)
    revision = if previous == nil, do: 1, else: previous.revision + 1

    {diagnostics_revision, diagnostic_index, diagnostics} =
      diagnostic_layer(previous, resident, input, keyframe?)

    annotations = annotation_layer(previous, input, keyframe?)
    {first_row_id, last_row_id} = boundary_row_ids(resident)
    max_level = GuideIndex.max_level(guide_index)

    active_guide_col =
      if input.guides_enabled?,
        do: active_guide_col(max_level, input.tab_width, input.cursor_col),
        else: 0xFFFF

    state = %__MODULE__{
      content_epoch: input.content_epoch,
      revision: revision,
      row_revision: resident.revision,
      row_count: resident.line_count,
      guide_index: guide_index,
      tab_width: input.tab_width,
      diagnostics_revision: diagnostics_revision,
      diagnostic_index: diagnostic_index,
      annotations_revision: input.annotations_revision
    }

    semantics = %ResidentSemantics{
      header: %Header{
        window_id: input.window_id,
        content_epoch: input.content_epoch,
        mode: if(keyframe?, do: :keyframe, else: :delta),
        base_revision: if(keyframe?, do: 0, else: previous.revision),
        revision: revision,
        target_row_revision: resident.revision,
        row_count: resident.line_count,
        first_row_id: first_row_id,
        last_row_id: last_row_id
      },
      cursor: %Cursor{
        eligible: input.cursor_eligible,
        row: input.cursor_row,
        col: input.cursor_col
      },
      cursorline: cursorline(input),
      selection: selection(input.selection),
      diagnostics: diagnostics,
      annotations: annotations,
      tab_width: input.tab_width,
      active_guide_col: active_guide_col,
      guide_cols:
        if(input.guides_enabled?,
          do: Enum.map(1..max_level//1, &(&1 * input.tab_width)),
          else: []
        ),
      row_splices: row_splices,
      guide_replacements: guide_replacements
    }

    {state, semantics}
  end

  defp keyframe?(nil, _input), do: true

  defp keyframe?(previous, input) do
    input.keyframe? or previous.content_epoch != input.content_epoch or
      previous.tab_width != input.tab_width or input.resident_result.row_delta == nil
  end

  defp next_guide_index(_previous, resident, input, true) do
    resident.store
    |> ResidentStore.payloads()
    |> GuideIndex.build(input.tab_width)
  end

  defp next_guide_index(previous, _resident, input, false) do
    apply_guide_splices(
      previous.guide_index,
      input.resident_result.row_delta,
      input.resident_result.inserted_payloads,
      input.tab_width
    )
  end

  defp apply_guide_splices(index, %RowDelta{splices: []}, _inserted, _tab_width), do: index

  defp apply_guide_splices(index, %RowDelta{splices: splices}, inserted, tab_width) do
    by_line = Map.new(inserted, fn %VisualRow{buf_line: line} = entry -> {line, entry} end)

    {index, _shift} =
      Enum.reduce(splices, {index, 0}, fn %RowSplice{} = splice, {acc, shift} ->
        start_row = splice.start_index + shift
        insert_count = RowSplice.insert_count(splice)

        rows =
          if insert_count == 0,
            do: [],
            else: Enum.map(start_row..(start_row + insert_count - 1), &Map.fetch!(by_line, &1))

        next = GuideIndex.splice(acc, start_row, splice.delete_count, rows, tab_width)
        {next, shift + insert_count - splice.delete_count}
      end)

    index
  end

  defp guide_replacements(_previous, guide_index, _input, true) do
    runs = GuideIndex.all_runs(guide_index)
    [%GuideReplace{start_row: 0, end_row: guide_index.row_count, runs: runs}]
  end

  defp guide_replacements(_previous, guide_index, input, false) do
    {ranges, _shift} =
      Enum.map_reduce(input.resident_result.row_delta.splices, 0, fn splice, shift ->
        start_row = splice.start_index + shift
        insert_count = RowSplice.insert_count(splice)
        {first, last} = GuideIndex.affected_bounds(guide_index, start_row, insert_count)

        {{first, last}, shift + insert_count - splice.delete_count}
      end)

    ranges
    |> canonical_ranges()
    |> Enum.map(fn {first, last} ->
      %GuideReplace{
        start_row: first,
        end_row: last,
        runs: GuideIndex.runs(guide_index, first, last)
      }
    end)
  end

  defp semantic_row_splices(%RowDelta{splices: splices}) do
    Enum.map(splices, fn splice ->
      %ResidentSemantics.RowSplice{
        start_row: splice.start_index,
        delete_count: splice.delete_count,
        insert_count: RowSplice.insert_count(splice)
      }
    end)
  end

  defp semantic_row_splices(nil), do: []

  defp diagnostic_layer(previous, resident, input, keyframe?) do
    {revision, diagnostics} = input.diagnostics_snapshot
    replace? = keyframe? or previous.diagnostics_revision != revision
    diagnostic_layer(previous, resident, diagnostics, revision, input, replace?)
  end

  defp diagnostic_layer(_previous, resident, diagnostics, revision, _input, true) do
    index = DiagnosticIndex.build(diagnostics, resident)
    {revision, index, {:replace, DiagnosticIndex.to_ranges(index)}}
  end

  defp diagnostic_layer(previous, resident, _diagnostics, revision, input, false) do
    {index, starts, _work} =
      DiagnosticIndex.apply_splices(
        previous.diagnostic_index,
        input.resident_result.row_delta.splices,
        resident
      )

    layer = diagnostic_range_layer(index, starts)
    {revision, index, layer}
  end

  defp diagnostic_range_layer(_index, []), do: :retain

  defp diagnostic_range_layer(index, starts),
    do: {:replace_ranges, diagnostic_replacements(index, starts)}

  defp diagnostic_replacements(index, starts) do
    starts
    |> Enum.map(fn start_row ->
      %DiagnosticReplace{
        start_row: start_row,
        end_row: start_row + 1,
        diagnostics: DiagnosticIndex.ranges_at(index, [start_row])
      }
    end)
    |> merge_diagnostic_replacements([])
  end

  defp merge_diagnostic_replacements([], acc), do: Enum.reverse(acc)

  defp merge_diagnostic_replacements(
         [%DiagnosticReplace{start_row: edge} = right | rest],
         [%DiagnosticReplace{end_row: edge} = left | acc]
       ) do
    merged = %DiagnosticReplace{
      left
      | end_row: right.end_row,
        diagnostics: left.diagnostics ++ right.diagnostics
    }

    merge_diagnostic_replacements(rest, [merged | acc])
  end

  defp merge_diagnostic_replacements([replacement | rest], acc),
    do: merge_diagnostic_replacements(rest, [replacement | acc])

  defp annotation_layer(_previous, input, true), do: annotation_layer_for(input, true, [])

  defp annotation_layer(previous, input, false),
    do:
      annotation_layer_for(
        input,
        previous.annotations_revision != input.annotations_revision,
        input.resident_result.row_delta.splices
      )

  defp annotation_layer_for(input, true, _splices) do
    {:replace,
     absolute_annotations(input.decorations.annotations, input.resident_build.line_count)}
  end

  defp annotation_layer_for(_input, false, []), do: :retain

  defp annotation_layer_for(input, false, splices),
    do:
      {:replace_ranges,
       annotation_replacements(input.decorations, splices, input.resident_build.line_count)}

  defp absolute_annotations(annotations, row_count) do
    annotations
    |> Enum.sort_by(fn annotation -> {annotation.line, annotation.priority} end)
    |> Enum.filter(&(&1.line < row_count))
    |> Enum.map(fn annotation ->
      %Annotation{
        row: annotation.line,
        kind: annotation.kind,
        fg: annotation.fg,
        bg: annotation.bg,
        text: annotation.text
      }
    end)
  end

  defp annotation_replacements(decorations, splices, row_count) do
    {ranges, _shift} =
      Enum.map_reduce(splices, 0, fn splice, shift ->
        start_row = splice.start_index + shift
        insert_count = RowSplice.insert_count(splice)

        end_row =
          min(
            annotation_replacement_end(start_row, splice.delete_count, insert_count),
            row_count
          )

        {{start_row, end_row}, shift + insert_count - splice.delete_count}
      end)

    ranges
    |> canonical_ranges()
    |> Enum.map(fn {start_row, end_row} ->
      %AnnotationReplace{
        start_row: start_row,
        end_row: end_row,
        annotations:
          decorations
          |> Decorations.annotations_for_range(start_row, end_row)
          |> absolute_annotations(end_row)
      }
    end)
  end

  defp annotation_replacement_end(start_row, delete_count, insert_count)
       when insert_count > 0 and delete_count != insert_count,
       do: start_row + insert_count + 1

  defp annotation_replacement_end(start_row, _delete_count, insert_count),
    do: start_row + insert_count

  defp cursorline(%{cursor_eligible: true, cursorline_bg: bg, cursor_row: row})
       when is_integer(bg),
       do: %Cursorline{row: row, bg_rgb: bg}

  defp cursorline(_input), do: nil

  defp selection(nil), do: nil

  defp selection({:line, start_row, end_row}),
    do: %Selection{type: :line, start_row: start_row, start_col: 0, end_row: end_row, end_col: 0}

  defp selection({:char, {start_row, start_col}, {end_row, end_col}}),
    do: %Selection{
      type: :char,
      start_row: start_row,
      start_col: start_col,
      end_row: end_row,
      end_col: end_col
    }

  defp boundary_row_ids(%ResidentBuild{line_count: 0}), do: {0, 0}

  defp boundary_row_ids(%ResidentBuild{store: store, line_count: count}) do
    {:ok, %VisualRow{row: first}} = ResidentStore.payload_at(store, 0)
    {:ok, %VisualRow{row: last}} = ResidentStore.payload_at(store, count - 1)
    {first.row_id, last.row_id}
  end

  defp active_guide_col(0, _tab_width, _cursor_col), do: 0xFFFF

  defp active_guide_col(max_level, tab_width, cursor_col) do
    level = min(div(cursor_col, tab_width), max_level)
    if level > 0, do: level * tab_width, else: 0xFFFF
  end

  defp canonical_ranges(ranges) do
    ranges
    |> Enum.reject(fn {start_row, end_row} -> start_row >= end_row end)
    |> Enum.sort()
    |> Enum.reduce([], &merge_range/2)
    |> Enum.reverse()
  end

  defp merge_range(range, []), do: [range]

  defp merge_range({start_row, end_row}, [{current_start, current_end} | rest])
       when start_row <= current_end,
       do: [{current_start, max(current_end, end_row)} | rest]

  defp merge_range(range, acc), do: [range | acc]

  defp validate_row_count!(count) when count <= 65_536, do: :ok

  defp validate_row_count!(count),
    do: raise(ArgumentError, "resident semantics supports at most 65,536 rows, got #{count}")
end
