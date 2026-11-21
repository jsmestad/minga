defmodule MingaEditor.RenderModel.Window.LazyRowTreeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaEditor.RenderModel.Window.LazyRowTree
  alias MingaEditor.RenderModel.Window.LazyRowTree.View

  test "sorted construction matches incremental insertion, including equal priorities" do
    cases = [
      [],
      [{4, 5, 2}],
      [{1, 2, 7}, {4, 5, 2}, {9, 10, 6}, {12, 1, 3}],
      [{1, 2, 2}, {4, 5, 2}, {9, 10, 2}]
    ]

    for entries <- cases do
      assert LazyRowTree.from_sorted(entries, &max_end/4) == insert_entries(entries)
    end
  end

  property "sorted construction keeps the same structure and summaries across priority mixes" do
    check all(pairs <- list_of(tuple({integer(0..20), integer(0..8)}), max_length: 40)) do
      entries = Enum.with_index(pairs, fn {offset, priority}, key -> {key, offset, priority} end)
      assert LazyRowTree.from_sorted(entries, &max_end/4) == insert_entries(entries)
    end
  end

  test "lazy summary shifts distribute through split and merge" do
    tree = LazyRowTree.from_sorted([{1, 2, 1}, {4, 5, 4}, {9, 1, 9}], &max_end/4)

    shifted = LazyRowTree.shift(tree, 7, &shift_max_end/2)
    assert LazyRowTree.summary(shifted) == LazyRowTree.summary(tree) + 7

    {left, right} = LazyRowTree.split(shifted, 12, &max_end/4, &shift_max_end/2)
    merged = LazyRowTree.merge(left, right, &max_end/4, &shift_max_end/2)

    assert entries(merged) == [{8, 2}, {11, 5}, {16, 1}]
    assert LazyRowTree.summary(merged) == 17
  end

  defp insert_entries(entries) do
    Enum.reduce(entries, nil, fn {key, offset, priority}, root ->
      leaf = LazyRowTree.leaf(key, offset, priority, &max_end/4)
      LazyRowTree.insert(root, leaf, &max_end/4, &shift_max_end/2)
    end)
  end

  defp entries(nil), do: []

  defp entries(tree) do
    %View{key: key, value: value, left: left, right: right} =
      LazyRowTree.view(tree, &shift_max_end/2)

    entries(left) ++ [{key, value}] ++ entries(right)
  end

  defp max_end(key, end_offset, left, right),
    do: max(key + end_offset, max(left || 0, right || 0))

  defp shift_max_end(max_end, shift), do: max_end + shift
end
