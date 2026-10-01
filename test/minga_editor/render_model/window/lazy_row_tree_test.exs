defmodule MingaEditor.RenderModel.Window.LazyRowTreeTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.Window.LazyRowTree
  alias MingaEditor.RenderModel.Window.LazyRowTree.View

  test "lazy summary shifts distribute through split and merge" do
    tree =
      Enum.reduce([{1, 2}, {4, 5}, {9, 1}], nil, fn {key, end_offset}, root ->
        leaf = LazyRowTree.leaf(key, end_offset, key, &max_end/4)
        LazyRowTree.insert(root, leaf, &max_end/4, &shift_max_end/2)
      end)

    shifted = LazyRowTree.shift(tree, 7, &shift_max_end/2)
    assert LazyRowTree.summary(shifted) == LazyRowTree.summary(tree) + 7

    {left, right} = LazyRowTree.split(shifted, 12, &max_end/4, &shift_max_end/2)
    merged = LazyRowTree.merge(left, right, &max_end/4, &shift_max_end/2)

    assert entries(merged) == [{8, 2}, {11, 5}, {16, 1}]
    assert LazyRowTree.summary(merged) == 17
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
