defmodule Minga.RenderModel.Window.Gutter.AuthorshipIndex do
  @moduledoc false

  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.RendererConsume
  alias Minga.Core.LazyRowTree

  @typep region :: RendererConsume.review_region()
  @typep entry ::
           {:text, pos_integer(), non_neg_integer(), non_neg_integer()}
           | {:gap, pos_integer(), non_neg_integer()}
           | {:kept | :you | :shared, non_neg_integer(), non_neg_integer()}
  @typep row :: {[entry()], non_neg_integer()}
  @opaque t :: LazyRowTree.t(row(), non_neg_integer())

  @spec new([region()]) :: t()
  def new(regions) do
    regions
    |> group_by_row()
    |> Enum.sort()
    |> Enum.map(fn {line, entries} -> {line, row(entries), priority(line)} end)
    |> LazyRowTree.from_sorted(&summarize/4)
  end

  @spec all(t()) :: [region()]
  def all(root), do: collect(root, 0, :all, []) |> Enum.reverse()

  @spec overlapping(t(), [RendererConsume.line_range()]) :: MapSet.t(region())
  def overlapping(root, ranges) do
    Enum.reduce(ranges, MapSet.new(), fn {first, last}, seen ->
      root |> collect(first, last, []) |> Enum.reduce(seen, &MapSet.put(&2, &1))
    end)
  end

  @spec replace(t(), [region()], [region()]) :: t()
  def replace(root, [], []), do: root

  def replace(root, removed, added) do
    changes =
      Map.merge(
        Map.new(group_by_row(removed), fn {line, entries} -> {line, {entries, []}} end),
        Map.new(group_by_row(added), fn {line, entries} -> {line, {[], entries}} end),
        fn _line, {removed, _}, {_, added} -> {removed, added} end
      )

    Enum.reduce(changes, root, fn {line, {removed, added}}, acc ->
      replace_row(acc, line, removed, added)
    end)
  end

  @spec apply_deltas(t(), [EditDelta.t()]) :: {t(), non_neg_integer() | nil}
  def apply_deltas(root, deltas) do
    Enum.reduce(deltas, {root, nil}, fn delta, {index, first_shift} ->
      %EditDelta{
        start_position: {start, _},
        old_end_position: {old_end, _},
        new_end_position: {new_end, _}
      } = delta

      first = max(0, start - 1)
      affected = index |> overlapping([{first, old_end + 1}]) |> MapSet.to_list()
      index = replace(index, affected, [])
      shift = new_end - old_end

      if shift == 0 do
        {index, first_shift}
      else
        {prefix, suffix} = LazyRowTree.split(index, old_end + 1, &summarize/4, &shift_summary/2)
        suffix = LazyRowTree.shift(suffix, shift, &shift_summary/2)
        index = LazyRowTree.merge(prefix, suffix, &summarize/4, &shift_summary/2)
        {index, if(first_shift, do: min(first_shift, first), else: first)}
      end
    end)
  end

  @spec group_by_row([region()]) :: %{optional(non_neg_integer()) => [entry()]}
  defp group_by_row(regions) do
    Enum.reduce(regions, %{}, fn region, groups ->
      {line, entry} = compact(region)
      Map.update(groups, line, [entry], &[entry | &1])
    end)
  end

  @spec replace_row(t(), non_neg_integer(), [entry()], [entry()]) :: t()
  defp replace_row(root, line, removed, added) do
    {prefix, from_line} = LazyRowTree.split(root, line, &summarize/4, &shift_summary/2)
    {current, suffix} = LazyRowTree.split(from_line, line + 1, &summarize/4, &shift_summary/2)

    entries =
      case LazyRowTree.view(current, &shift_summary/2) do
        nil ->
          added

        %{value: {old, _last}} ->
          retain_row_entries(old, MapSet.new(removed), added)
      end

    with_updated_row =
      case entries do
        [] ->
          prefix

        _ ->
          leaf = LazyRowTree.leaf(line, row(entries), priority(line), &summarize/4)
          LazyRowTree.merge(prefix, leaf, &summarize/4, &shift_summary/2)
      end

    LazyRowTree.merge(with_updated_row, suffix, &summarize/4, &shift_summary/2)
  end

  @spec retain_row_entries([entry()], MapSet.t(entry()), [entry()]) :: [entry()]
  defp retain_row_entries(old, dropped, added) do
    Enum.reduce(old, added, fn entry, acc ->
      if MapSet.member?(dropped, entry), do: acc, else: [entry | acc]
    end)
  end

  @spec collect(t(), non_neg_integer(), non_neg_integer() | :all, [region()]) :: [region()]
  defp collect(nil, _first, _last, acc), do: acc

  defp collect(tree, first, last, acc) do
    if LazyRowTree.summary(tree) < first do
      acc
    else
      %{key: line, value: {entries, _end}, left: left, right: right} =
        LazyRowTree.view(tree, &shift_summary/2)

      acc = collect(left, first, last, acc)

      if last == :all or line <= last do
        acc = Enum.reduce(entries, acc, &add_overlapping(&1, line, first, &2))
        collect(right, first, last, acc)
      else
        acc
      end
    end
  end

  @spec add_overlapping(entry(), non_neg_integer(), non_neg_integer(), [region()]) :: [region()]
  defp add_overlapping(entry, line, first, acc) do
    if line + extent(entry) >= first, do: [absolute(entry, line) | acc], else: acc
  end

  @spec row([entry()]) :: row()
  defp row(entries), do: {Enum.sort(entries), Enum.reduce(entries, 0, &max(extent(&1), &2))}

  @spec priority(non_neg_integer()) :: non_neg_integer()
  defp priority(line), do: :erlang.phash2({:authorship, line})

  @spec summarize(non_neg_integer(), row(), non_neg_integer() | nil, non_neg_integer() | nil) ::
          non_neg_integer()
  defp summarize(line, {_entries, own_end}, left, right),
    do: max(line + own_end, max(left || 0, right || 0))

  @spec shift_summary(non_neg_integer(), integer()) :: non_neg_integer()
  defp shift_summary(last, delta), do: last + delta

  @spec extent(entry()) :: non_neg_integer()
  defp extent({:text, _id, _column, offset}), do: offset
  defp extent({:gap, _id, _column}), do: 0
  defp extent({_role, _column, offset}), do: offset

  @spec compact(region()) :: {non_neg_integer(), entry()}
  defp compact({:text, id, {line, col}, last}), do: {line, {:text, id, col, last - line}}
  defp compact({:gap, id, {line, col}}), do: {line, {:gap, id, col}}
  defp compact({role, {line, col}, last}), do: {line, {role, col, last - line}}

  @spec absolute(entry(), non_neg_integer()) :: region()
  defp absolute({:text, id, col, offset}, line), do: {:text, id, {line, col}, line + offset}
  defp absolute({:gap, id, col}, line), do: {:gap, id, {line, col}}
  defp absolute({role, col, offset}, line), do: {role, {line, col}, line + offset}
end
