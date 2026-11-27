defmodule MingaEditor.RenderModel.Window.DiagnosticIndex do
  @moduledoc """
  Persistent resident diagnostic index with lazy suffix shifts.

  Diagnostics are keyed by logical source line and retain their original
  endpoint columns. Projected continuation offsets are relative to each
  endpoint's source group, so an untouched suffix shifts without reprojecting.
  """

  alias Minga.Core.LazyRowTree
  alias Minga.Core.LazyRowTree.View
  alias Minga.Diagnostics.Diagnostic
  alias Minga.RenderModel.Window.DiagnosticRange
  alias MingaEditor.RenderModel.Window.{ResidentBuild, ResidentStore}

  @type compact ::
          {end_line_offset :: non_neg_integer(), start_source_col :: non_neg_integer(),
           end_source_col :: non_neg_integer(), Diagnostic.encoding(), Diagnostic.severity(),
           {start_offset :: non_neg_integer(), start_col :: non_neg_integer()},
           {end_offset :: non_neg_integer(), end_col :: non_neg_integer()}}

  @type tree_node :: LazyRowTree.t(tuple(), non_neg_integer())

  @type work :: %{groups_reprojected: non_neg_integer(), suffix_shifts: non_neg_integer()}

  @enforce_keys [:root, :store, :wrapped?]
  defstruct @enforce_keys

  @type t :: %__MODULE__{root: tree_node(), store: ResidentStore.t(), wrapped?: boolean()}

  @spec build([Diagnostic.t()], ResidentBuild.t(), boolean()) :: t()
  def build(diagnostics, %ResidentBuild{store: store}, wrapped? \\ false) do
    line_count = ResidentStore.line_count(store)

    root =
      diagnostics
      |> Enum.reduce(%{}, fn diagnostic, groups ->
        %{start_line: first, end_line: last} = diagnostic.range

        if first < line_count and last < line_count do
          entry = project_diagnostic(diagnostic, store, wrapped?)
          Map.put(groups, first, [entry | Map.get(groups, first, [])])
        else
          groups
        end
      end)
      |> Enum.sort()
      |> Enum.map(fn {line, entries} ->
        entries = entries |> Enum.reverse() |> List.to_tuple()
        {line, entries, :erlang.phash2({:resident_diagnostic, line})}
      end)
      |> LazyRowTree.from_sorted(&summarize/4)

    %__MODULE__{root: root, store: store, wrapped?: wrapped?}
  end

  @spec to_ranges(t()) :: [DiagnosticRange.t()]
  def to_ranges(%__MODULE__{root: root, store: store}), do: collect_ranges(root, store, [])

  @doc "Applies logical source splices, returning final visual start ranks needing replacement."
  @spec apply_splices(t(), [ResidentBuild.source_splice()], ResidentBuild.t()) ::
          {t(), [non_neg_integer()], work()}
  def apply_splices(%__MODULE__{} = index, [], _resident), do: {index, [], empty_work()}

  def apply_splices(%__MODULE__{} = index, splices, %ResidentBuild{store: store}) do
    {root, starts, _shift, work} =
      Enum.reduce(splices, {index.root, MapSet.new(), 0, empty_work()}, fn
        {first, deleted, inserted}, {root, starts, shift, work} ->
          start_line = first + shift
          starts = shift_markers(starts, start_line, deleted, inserted)

          {root, touched, splice_work} =
            apply_splice(root, start_line, deleted, inserted, store, index.wrapped?)

          {root, MapSet.union(starts, touched), shift + inserted - deleted,
           add_work(work, splice_work)}
      end)

    updated = %{index | root: root, store: store}

    ranks =
      starts
      |> Enum.reduce(MapSet.new(), fn line, ranks ->
        case fetch(root, line) do
          nil -> ranks
          entries -> put_start_ranks(entries, ResidentStore.visual_rank(store, line), ranks)
        end
      end)
      |> Enum.sort()

    {updated, ranks, work}
  end

  @spec ranges_at(t(), [non_neg_integer()]) :: [DiagnosticRange.t()]
  def ranges_at(%__MODULE__{root: root, store: store}, starts) do
    starts
    |> Enum.reduce(%{}, fn rank, groups ->
      {line, offset} = ResidentStore.anchor_at(store, rank)

      case groups do
        %{^line => {base_rank, offsets}} ->
          Map.put(groups, line, {base_rank, MapSet.put(offsets, offset)})

        %{} ->
          Map.put(groups, line, {rank - offset, MapSet.new([offset])})
      end
    end)
    |> Enum.sort()
    |> Enum.flat_map(fn {line, ranks} ->
      ranges_at_line(fetch(root, line), line, ranks, store)
    end)
  end

  defp ranges_at_line(nil, _line, _ranks, _store), do: []

  defp ranges_at_line(entries, line, {base_rank, offsets}, store) do
    ranges =
      for index <- 0..(tuple_size(entries) - 1)//1,
          entry = elem(entries, index),
          MapSet.member?(offsets, start_offset(entry)) do
        compact_range(entry, line, base_rank, store)
      end

    Enum.sort_by(ranges, & &1.start_row)
  end

  defp apply_splice(root, first, count, count, store, wrapped?) do
    end_line = first + count
    candidates = affected_starts(root, first, end_line)

    {root, starts} =
      Enum.reduce(candidates, {root, MapSet.new()}, fn line, {root, starts} ->
        entries = fetch(root, line)

        if line >= first or group_end_in?(entries, line, first, end_line) do
          next = update_group(root, line, &reproject_group(line, &1, store, wrapped?))
          {next, MapSet.put(starts, line)}
        else
          {root, starts}
        end
      end)

    {root, starts, %{groups_reprojected: MapSet.size(starts), suffix_shifts: 0}}
  end

  defp apply_splice(root, first, deleted, inserted, store, wrapped?) do
    delete_end = first + deleted
    crossing = crossing_starts(root, first)

    {root, starts} =
      Enum.reduce(crossing, {root, MapSet.new()}, fn line, {root, starts} ->
        entries = fetch(root, line)

        {updated, dirty?} =
          entries
          |> Tuple.to_list()
          |> Enum.map_reduce(false, fn entry, dirty? ->
            {updated, changed?} =
              adjust_crossing(entry, line, first, delete_end, inserted, store, wrapped?)

            {updated, dirty? or changed?}
          end)

        root = update_group(root, line, fn _ -> List.to_tuple(updated) end)
        {root, if(dirty?, do: MapSet.put(starts, line), else: starts)}
      end)

    {before, from_start} = LazyRowTree.split(root, first, &summarize/4, &shift_summary/2)
    {_deleted, suffix} = LazyRowTree.split(from_start, delete_end, &summarize/4, &shift_summary/2)
    suffix = LazyRowTree.shift(suffix, inserted - deleted, &shift_summary/2)

    {LazyRowTree.merge(before, suffix, &summarize/4, &shift_summary/2), starts,
     %{groups_reprojected: length(crossing), suffix_shifts: 1}}
  end

  defp adjust_crossing({offset, _, _, _, _, _, _} = entry, line, first, _, _, _, _)
       when line + offset < first,
       do: {entry, false}

  defp adjust_crossing(
         {offset, a, b, encoding, severity, start_pos, end_pos},
         line,
         first,
         delete_end,
         inserted,
         _store,
         _wrapped?
       )
       when line + offset >= delete_end do
    {{offset + inserted + first - delete_end, a, b, encoding, severity, start_pos, end_pos},
     false}
  end

  defp adjust_crossing(
         {offset, a, b, encoding, severity, _, _},
         line,
         first,
         _delete_end,
         inserted,
         store,
         wrapped?
       ) do
    mapped_end = map_deleted_end(line + offset, first, inserted)
    diagnostic = diagnostic(line, a, mapped_end, b, encoding, severity)
    {project_diagnostic(diagnostic, store, wrapped?), true}
  end

  defp map_deleted_end(_line, first, 0), do: max(first - 1, 0)
  defp map_deleted_end(line, first, inserted), do: min(line, first + inserted - 1)

  defp project_diagnostic(diagnostic, store, wrapped?) do
    %{range: range, encoding: encoding, severity: severity} = diagnostic
    start_line = range.start_line
    end_line = range.end_line
    {:ok, start_entry} = ResidentStore.source_row(store, start_line)
    {:ok, end_entry} = ResidentStore.source_row(store, end_line)
    {_, start_byte} = Diagnostic.start_position(diagnostic, start_entry.source_text)
    {_, end_byte} = Diagnostic.end_position(diagnostic, end_entry.source_text)
    start_pos = project_endpoint(store, start_line, start_byte, :start, wrapped?)
    end_pos = project_endpoint(store, end_line, end_byte, :end, wrapped?)
    end_pos = if start_line == end_line, do: max(start_pos, end_pos), else: end_pos

    {end_line - start_line, range.start_col, range.end_col, encoding, severity, start_pos,
     end_pos}
  end

  defp project_endpoint(_store, _line, byte, _affinity, false), do: {0, byte}

  defp project_endpoint(store, line, byte, affinity, true) do
    {rank, col} = ResidentStore.source_position(store, line, byte, affinity)
    {rank - ResidentStore.visual_rank(store, line), col}
  end

  defp reproject_group(line, entries, store, wrapped?) do
    entries
    |> Tuple.to_list()
    |> Enum.map(fn {end_offset, source_start, source_end, encoding, severity, _, _} ->
      diagnostic(line, source_start, line + end_offset, source_end, encoding, severity)
      |> project_diagnostic(store, wrapped?)
    end)
    |> List.to_tuple()
  end

  defp group_end_in?(entries, line, first, last) do
    entries
    |> Tuple.to_list()
    |> Enum.any?(fn {offset, _, _, _, _, _, _} ->
      line + offset >= first and line + offset < last
    end)
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

  defp shift_markers(markers, _first, count, count), do: markers

  defp shift_markers(markers, first, deleted, inserted) do
    Enum.reduce(markers, MapSet.new(), fn line, acc ->
      shift_marker(acc, line, first, first + deleted, inserted - deleted)
    end)
  end

  defp shift_marker(acc, line, first, _, _) when line < first, do: MapSet.put(acc, line)

  defp shift_marker(acc, line, _, last, shift) when line >= last,
    do: MapSet.put(acc, line + shift)

  defp shift_marker(acc, _line, _first, _last, _shift), do: acc

  defp affected_starts(_root, start_row, end_row) when start_row >= end_row, do: []

  defp affected_starts(root, start_row, end_row) do
    root
    |> collect_overlaps(start_row, end_row, [])
    |> Enum.reverse()
  end

  defp crossing_starts(root, start_row) do
    root
    |> collect_crossing(start_row, [])
    |> Enum.reverse()
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

  defp put_start_ranks(entries, base_rank, ranks) do
    Enum.reduce(0..(tuple_size(entries) - 1)//1, ranks, fn index, ranks ->
      MapSet.put(ranks, base_rank + start_offset(elem(entries, index)))
    end)
  end

  defp start_offset({_, _, _, _, _, {offset, _}, _}), do: offset

  defp compact_ranges(entries, start_line, store) do
    base_rank = ResidentStore.visual_rank(store, start_line)

    ranges =
      for index <- 0..(tuple_size(entries) - 1)//1 do
        compact_range(elem(entries, index), start_line, base_rank, store)
      end

    Enum.sort_by(ranges, & &1.start_row)
  end

  defp compact_range(
         {end_line_offset, _, _, _, severity, {start_offset, start_col}, {end_offset, end_col}},
         start_line,
         base_rank,
         store
       ) do
    %DiagnosticRange{
      start_row: base_rank + start_offset,
      start_col: start_col,
      end_row: ResidentStore.visual_rank(store, start_line + end_line_offset) + end_offset,
      end_col: end_col,
      severity: severity
    }
  end

  defp collect_ranges(nil, _store, acc), do: acc

  defp collect_ranges(root, store, acc) do
    %View{key: line, value: entries, left: left, right: right} =
      LazyRowTree.view(root, &shift_summary/2)

    acc = collect_ranges(right, store, acc)
    acc = compact_ranges(entries, line, store) ++ acc
    collect_ranges(left, store, acc)
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
