defmodule MingaEditor.RenderModel.Window.DiagnosticIndex do
  @moduledoc """
  Persistent resident diagnostic index with lazy suffix shifts.

  Diagnostics are grouped by start row. Each compact entry keeps its end-row offset plus source and projected columns. Structural row splices therefore shift an unchanged suffix in logarithmic work, while in-place edits reproject only groups whose start or end touches an edited row.
  """

  alias Minga.Diagnostics.Diagnostic
  alias Minga.RenderModel.Window.{DiagnosticRange, RowSplice}
  alias MingaEditor.RenderModel.Window.{LazyRowTree, ResidentBuild, ResidentStore, VisualRow}
  alias MingaEditor.RenderModel.Window.LazyRowTree.View

  @type compact ::
          {end_offset :: non_neg_integer(), start_source_col :: non_neg_integer(),
           end_source_col :: non_neg_integer(), Diagnostic.encoding(), Diagnostic.severity(),
           start_col :: non_neg_integer(), end_col :: non_neg_integer()}

  @type tree_node :: LazyRowTree.t(tuple(), non_neg_integer())

  @type work :: %{groups_reprojected: non_neg_integer(), suffix_shifts: non_neg_integer()}

  @enforce_keys [:root]
  defstruct [:root]

  @type t :: %__MODULE__{root: tree_node()}

  @spec build([Diagnostic.t()], ResidentBuild.t()) :: t()
  def build(diagnostics, %ResidentBuild{} = resident) do
    root =
      diagnostics
      |> Enum.flat_map(&compact_diagnostic(&1, resident))
      |> Enum.group_by(fn {line, _entry} -> line end, fn {_line, entry} -> entry end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(nil, fn {line, entries}, tree ->
        LazyRowTree.insert(
          tree,
          leaf(line, List.to_tuple(entries)),
          &summarize/4,
          &shift_summary/2
        )
      end)

    %__MODULE__{root: root}
  end

  @spec to_ranges(t()) :: [DiagnosticRange.t()]
  def to_ranges(%__MODULE__{root: root}), do: collect_ranges(root, [])

  @doc "Applies immutable-base row splices and returns final start rows that need column replacement."
  @spec apply_splices(t(), [RowSplice.t()], ResidentBuild.t()) ::
          {t(), [non_neg_integer()], work()}
  def apply_splices(%__MODULE__{} = index, splices, %ResidentBuild{} = resident) do
    {root, starts, _shift, work} =
      Enum.reduce(splices, {index.root, MapSet.new(), 0, empty_work()}, fn splice,
                                                                           {root, starts, shift,
                                                                            work} ->
        start_row = splice.start_index + shift
        insert_count = RowSplice.insert_count(splice)
        starts = shift_markers(starts, start_row, splice.delete_count, insert_count)

        {root, touched, splice_work} =
          apply_splice(root, start_row, splice.delete_count, insert_count, resident)

        {root, MapSet.union(starts, MapSet.new(touched)),
         shift + insert_count - splice.delete_count, add_work(work, splice_work)}
      end)

    {%__MODULE__{root: root}, starts |> Enum.sort(), work}
  end

  @spec ranges_at(t(), [non_neg_integer()]) :: [DiagnosticRange.t()]
  def ranges_at(%__MODULE__{} = index, starts) do
    Enum.flat_map(starts, fn start_row ->
      case fetch(index.root, start_row) do
        nil -> []
        entries -> compact_ranges(start_row, entries)
      end
    end)
  end

  defp apply_splice(root, start_row, delete_count, insert_count, resident)
       when delete_count == insert_count do
    end_row = start_row + insert_count
    starts = affected_starts(root, start_row, end_row)

    root =
      Enum.reduce(starts, root, fn line, tree ->
        update_group(tree, line, &reproject_group(line, &1, resident))
      end)

    {root, starts, %{groups_reprojected: length(starts), suffix_shifts: 0}}
  end

  defp apply_splice(root, start_row, delete_count, insert_count, resident) do
    delete_end = start_row + delete_count
    crossing_starts = crossing_starts(root, start_row)

    root =
      Enum.reduce(crossing_starts, root, fn line, tree ->
        update_group(tree, line, fn entries ->
          adjust_crossing_group(
            line,
            entries,
            start_row,
            delete_end,
            insert_count,
            resident.line_count
          )
        end)
      end)

    {before, from_start} =
      LazyRowTree.split(root, start_row, &summarize/4, &shift_summary/2)

    {_deleted, suffix} =
      LazyRowTree.split(from_start, delete_end, &summarize/4, &shift_summary/2)

    suffix = LazyRowTree.shift(suffix, insert_count - delete_count, &shift_summary/2)

    {LazyRowTree.merge(before, suffix, &summarize/4, &shift_summary/2), [],
     %{groups_reprojected: length(crossing_starts), suffix_shifts: 1}}
  end

  defp compact_diagnostic(diagnostic, resident) do
    start_line = diagnostic.range.start_line
    end_line = diagnostic.range.end_line

    with true <- start_line < resident.line_count and end_line < resident.line_count,
         {:ok, %VisualRow{source_text: start_text}} <-
           ResidentStore.payload_at(resident.store, start_line),
         {:ok, %VisualRow{source_text: end_text}} <-
           ResidentStore.payload_at(resident.store, end_line) do
      {_row, start_col} = Diagnostic.start_position(diagnostic, start_text)
      {_row, end_col} = Diagnostic.end_position(diagnostic, end_text)

      [
        {start_line,
         {end_line - start_line, diagnostic.range.start_col, diagnostic.range.end_col,
          diagnostic.encoding, diagnostic.severity, start_col, end_col}}
      ]
    else
      _ -> []
    end
  end

  defp reproject_group(start_line, entries, resident) do
    entries
    |> Tuple.to_list()
    |> Enum.flat_map(fn {end_offset, source_start, source_end, encoding, severity, _start, _end} ->
      end_line = start_line + end_offset

      with {:ok, %VisualRow{source_text: start_text}} <-
             ResidentStore.payload_at(resident.store, start_line),
           {:ok, %VisualRow{source_text: end_text}} <-
             ResidentStore.payload_at(resident.store, end_line) do
        {_row, start_col} =
          Diagnostic.start_position(
            diagnostic(start_line, source_start, end_line, source_end, encoding, severity),
            start_text
          )

        {_row, end_col} =
          Diagnostic.end_position(
            diagnostic(start_line, source_start, end_line, source_end, encoding, severity),
            end_text
          )

        [{end_offset, source_start, source_end, encoding, severity, start_col, end_col}]
      else
        :error -> []
      end
    end)
    |> List.to_tuple()
  end

  defp diagnostic(start_line, start_col, end_line, end_col, encoding, severity) do
    %Diagnostic{
      range: %{
        start_line: start_line,
        start_col: start_col,
        end_line: end_line,
        end_col: end_col
      },
      severity: severity,
      message: "",
      encoding: encoding
    }
  end

  defp adjust_crossing_group(
         start_line,
         entries,
         splice_start,
         delete_end,
         insert_count,
         row_count
       ) do
    entries
    |> Tuple.to_list()
    |> Enum.flat_map(
      &adjust_crossing_entry(
        &1,
        {start_line, splice_start, delete_end, insert_count, row_count}
      )
    )
    |> List.to_tuple()
  end

  defp adjust_crossing_entry(
         {end_offset, _source_start, _source_end, _encoding, _severity, _start_col, _end_col} =
           entry,
         {start_line, splice_start, _delete_end, _insert_count, _row_count}
       )
       when start_line + end_offset < splice_start,
       do: [entry]

  defp adjust_crossing_entry(
         {end_offset, source_start, source_end, encoding, severity, start_col, end_col},
         {start_line, splice_start, delete_end, insert_count, row_count}
       ) do
    mapped_end = map_row(start_line + end_offset, splice_start, delete_end, insert_count)

    adjusted_crossing_entry(
      mapped_end,
      row_count,
      start_line,
      {source_start, source_end, encoding, severity, start_col, end_col}
    )
  end

  defp adjusted_crossing_entry(
         mapped_end,
         row_count,
         start_line,
         {source_start, source_end, encoding, severity, start_col, end_col}
       )
       when mapped_end < row_count do
    [
      {mapped_end - start_line, source_start, source_end, encoding, severity, start_col, end_col}
    ]
  end

  defp adjusted_crossing_entry(_mapped_end, _row_count, _start_line, _entry), do: []

  defp map_row(row, start_row, delete_end, insert_count) when row >= delete_end,
    do: row + insert_count - (delete_end - start_row)

  defp map_row(_row, start_row, _delete_end, 0), do: start_row

  defp map_row(row, start_row, _delete_end, insert_count),
    do: start_row + min(row - start_row, insert_count - 1)

  defp shift_markers(markers, start_row, delete_count, insert_count) do
    delete_end = start_row + delete_count
    shift = insert_count - delete_count

    Enum.reduce(markers, MapSet.new(), fn line, acc ->
      shift_marker(acc, line, start_row, delete_end, shift)
    end)
  end

  defp shift_marker(acc, line, start_row, _delete_end, _shift) when line < start_row,
    do: MapSet.put(acc, line)

  defp shift_marker(acc, line, _start_row, delete_end, shift) when line >= delete_end,
    do: MapSet.put(acc, line + shift)

  defp shift_marker(acc, _line, _start_row, _delete_end, _shift), do: acc

  defp affected_starts(_root, start_row, end_row) when start_row >= end_row, do: []

  defp affected_starts(root, start_row, end_row) do
    root
    |> collect_overlaps(start_row, end_row, [])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp crossing_starts(root, start_row) do
    root
    |> collect_crossing(start_row, [])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp collect_overlaps(nil, _start_row, _end_row, acc), do: acc

  defp collect_overlaps(root, start_row, end_row, acc) do
    %View{key: line, value: entries, left: left, right: right, summary: max_end} =
      LazyRowTree.view(root, &shift_summary/2)

    if max_end < start_row do
      acc
    else
      acc = collect_overlaps(left, start_row, end_row, acc)

      acc =
        if line < end_row and group_max_end(line, entries) >= start_row,
          do: [line | acc],
          else: acc

      if line < end_row, do: collect_overlaps(right, start_row, end_row, acc), else: acc
    end
  end

  defp collect_crossing(nil, _row, acc), do: acc

  defp collect_crossing(root, row, acc) do
    %View{key: line, value: entries, left: left, right: right, summary: max_end} =
      LazyRowTree.view(root, &shift_summary/2)

    if max_end < row do
      acc
    else
      acc = collect_crossing(left, row, acc)
      acc = if line < row and group_max_end(line, entries) >= row, do: [line | acc], else: acc
      if line < row, do: collect_crossing(right, row, acc), else: acc
    end
  end

  defp compact_ranges(start_row, entries) do
    entries
    |> Tuple.to_list()
    |> Enum.map(fn {end_offset, _source_start, _source_end, _encoding, severity, start_col,
                    end_col} ->
      %DiagnosticRange{
        start_row: start_row,
        start_col: start_col,
        end_row: start_row + end_offset,
        end_col: end_col,
        severity: severity
      }
    end)
  end

  defp collect_ranges(nil, acc), do: acc

  defp collect_ranges(root, acc) do
    %View{key: line, value: entries, left: left, right: right} =
      LazyRowTree.view(root, &shift_summary/2)

    acc = collect_ranges(right, acc)
    acc = Enum.reduce(Enum.reverse(compact_ranges(line, entries)), acc, &[&1 | &2])
    collect_ranges(left, acc)
  end

  defp fetch(nil, _line), do: nil

  defp fetch(root, line) do
    %View{key: root_line, value: entries, left: left, right: right} =
      LazyRowTree.view(root, &shift_summary/2)

    case root_line do
      ^line -> entries
      n when line < n -> fetch(left, line)
      _ -> fetch(right, line)
    end
  end

  defp update_group(root, line, fun) do
    LazyRowTree.update(
      root,
      line,
      fn entries -> replacement(fun.(entries)) end,
      &summarize/4,
      &shift_summary/2
    )
  end

  defp replacement({}), do: :delete
  defp replacement(entries), do: {:replace, entries}

  defp leaf(line, entries) do
    LazyRowTree.leaf(
      line,
      entries,
      :erlang.phash2({:resident_diagnostic, line}),
      &summarize/4
    )
  end

  defp summarize(line, entries, left, right),
    do: max(group_max_end(line, entries), max(left || 0, right || 0))

  defp shift_summary(max_end, shift), do: max_end + shift

  defp group_max_end(line, entries) do
    entries
    |> Tuple.to_list()
    |> Enum.reduce(line, fn {offset, _a, _b, _c, _d, _e, _f}, current ->
      max(current, line + offset)
    end)
  end

  defp empty_work, do: %{groups_reprojected: 0, suffix_shifts: 0}

  defp add_work(left, right) do
    %{
      groups_reprojected: left.groups_reprojected + right.groups_reprojected,
      suffix_shifts: left.suffix_shifts + right.suffix_shifts
    }
  end
end
