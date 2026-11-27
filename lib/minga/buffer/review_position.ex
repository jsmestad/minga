defmodule Minga.Buffer.ReviewPosition do
  @moduledoc "Ranks exact pending review heads without rebuilding the ledger when text moves."

  alias Minga.Buffer.Document
  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.ReviewDamage
  alias Minga.Buffer.UndoHistory
  alias Minga.Buffer.ReviewRibbon
  alias Minga.Core.LazyRowTree

  @enforce_keys [:root]
  defstruct @enforce_keys

  @type rank :: {index :: pos_integer(), total :: pos_integer()}
  @typep byte_range :: {non_neg_integer(), non_neg_integer()}
  @typep head :: {byte_count :: non_neg_integer(), gap? :: boolean()}
  @typep summary :: {reach :: non_neg_integer(), count :: pos_integer()}
  @typep tree :: LazyRowTree.t(head(), summary())
  @opaque t :: %__MODULE__{root: tree()}

  @spec build(UndoHistory.t(), Document.t()) :: t()
  def build(history, document) do
    bounds = [{0, Document.content_byte_size(document), true}]
    root = history |> ReviewRibbon.regions(document, bounds) |> build_heads()
    %__MODULE__{root: root}
  end

  @spec at(t(), non_neg_integer()) :: rank() | nil
  def at(%__MODULE__{root: root}, point) do
    case find_rank(root, point, 0) do
      nil -> nil
      rank -> {rank, count(LazyRowTree.summary(root))}
    end
  end

  @doc "Moves untouched heads and replaces only the authored byte ranges affected by review or edits."
  @spec revise(t(), UndoHistory.t(), Document.t(), [byte_range()], [EditDelta.t()]) :: t()
  def revise(%__MODULE__{root: root}, history, document, ranges, deltas) do
    {root, boundaries} = Enum.reduce(deltas, {root, []}, &apply_delta/2)
    size = Document.content_byte_size(document)

    damage =
      Enum.map(ranges ++ boundaries, fn {first, last} -> {min(first, size), min(last, size)} end)

    rows = ReviewRibbon.damage_rows(document, damage)
    {query, regions} = repair_regions(history, document, rows)

    root =
      Enum.reduce(query, root, fn {first, stop, eof?}, root ->
        drop_intersecting(root, {first, if(eof?, do: stop, else: stop - 1)})
      end)

    root = regions |> heads() |> Enum.reduce(root, &put_head/2)

    %__MODULE__{root: root}
  end

  @spec repair_regions(UndoHistory.t(), Document.t(), [{non_neg_integer(), non_neg_integer()}]) ::
          {[{non_neg_integer(), non_neg_integer(), boolean()}], [ReviewRibbon.t()]}
  defp repair_regions(history, document, rows) do
    query = for {first, last} <- rows, do: ReviewRibbon.byte_bounds(document, first, last)
    regions = ReviewRibbon.regions(history, document, query)
    extent = for {_, first, stop} <- regions, do: ReviewRibbon.source_rows(document, first, stop)
    expanded = ReviewDamage.merge_ranges(rows, extent)

    if expanded == rows,
      do: {query, regions},
      else: repair_regions(history, document, expanded)
  end

  @spec put_head({non_neg_integer(), head(), non_neg_integer()}, tree()) :: tree()
  defp put_head({key, head, priority}, tree) do
    tree = LazyRowTree.update(tree, key, fn _ -> :delete end, &summarize/4, &shift_summary/2)
    node = LazyRowTree.leaf(key, head, priority, &summarize/4)
    LazyRowTree.insert(tree, node, &summarize/4, &shift_summary/2)
  end

  @spec apply_delta(EditDelta.t(), {tree(), [byte_range()]}) :: {tree(), [byte_range()]}
  defp apply_delta(delta, {root, damage}) do
    first = max(0, delta.start_byte - 1)
    root = drop_intersecting(root, {first, delta.old_end_byte + 1})
    shift = delta.new_end_byte - delta.old_end_byte

    root =
      if shift == 0 do
        root
      else
        {left, right} =
          LazyRowTree.split(root, delta.old_end_byte + 1, &summarize/4, &shift_summary/2)

        LazyRowTree.merge(
          left,
          LazyRowTree.shift(right, shift, &shift_summary/2),
          &summarize/4,
          &shift_summary/2
        )
      end

    damage =
      damage
      |> Enum.map(&EditDelta.transform_byte_range(&1, delta))
      |> ReviewDamage.merge_ranges([{first, delta.new_end_byte + 1}])

    {root, damage}
  end

  @spec drop_intersecting(tree(), byte_range()) :: tree()
  defp drop_intersecting(tree, {first, last}) do
    tree
    |> heads_touching(first, last, [])
    |> Enum.reduce(tree, fn key, root ->
      LazyRowTree.update(root, key, fn _ -> :delete end, &summarize/4, &shift_summary/2)
    end)
  end

  @spec heads_touching(tree(), non_neg_integer(), non_neg_integer(), [non_neg_integer()]) ::
          [non_neg_integer()]
  defp heads_touching(nil, _first, _last, acc), do: acc

  defp heads_touching(tree, first, last, acc) do
    {furthest, _size} = LazyRowTree.summary(tree)

    if furthest < first do
      acc
    else
      %{key: start, value: head, left: left, right: right} =
        LazyRowTree.view(tree, &shift_summary/2)

      acc = heads_touching(left, first, last, acc)

      heads_touching_right(start, head, right, {first, last}, acc)
    end
  end

  @spec heads_touching_right(
          non_neg_integer(),
          head(),
          tree(),
          {non_neg_integer(), non_neg_integer()},
          [non_neg_integer()]
        ) :: [non_neg_integer()]
  defp heads_touching_right(start, _head, _right, {_first, last}, acc) when start > last, do: acc

  defp heads_touching_right(start, head, right, {first, last}, acc) do
    acc = if reach(start, head) >= first, do: [start | acc], else: acc
    heads_touching(right, first, last, acc)
  end

  @spec find_rank(tree(), non_neg_integer(), non_neg_integer()) :: pos_integer() | nil
  defp find_rank(nil, _point, _preceding), do: nil

  defp find_rank(tree, point, preceding) do
    {furthest, _size} = LazyRowTree.summary(tree)

    if furthest >= point do
      tree |> LazyRowTree.view(&shift_summary/2) |> find_rank_at(point, preceding)
    end
  end

  @spec find_rank_at(
          LazyRowTree.View.t(head(), {non_neg_integer(), non_neg_integer()}),
          non_neg_integer(),
          non_neg_integer()
        ) :: pos_integer() | nil
  defp find_rank_at(%{key: start, left: left}, point, preceding) when start > point,
    do: find_rank(left, point, preceding)

  defp find_rank_at(
         %{key: start, value: {length, gap?}, left: left, right: right},
         point,
         preceding
       ) do
    rank = preceding + count(LazyRowTree.summary(left)) + 1

    find_rank(right, point, rank) ||
      if(point < start + length or (gap? and point == start),
        do: rank,
        else: find_rank(left, point, preceding)
      )
  end

  @spec build_heads([ReviewRibbon.t()]) :: tree()
  defp build_heads(regions), do: LazyRowTree.from_sorted(heads(regions), &summarize/4)

  @spec heads([ReviewRibbon.t()]) :: [{non_neg_integer(), head(), non_neg_integer()}]
  defp heads(regions) do
    regions
    |> Enum.reduce([], fn
      {_unit, start, stop}, [{start, {length, gap?}, priority} | rest] ->
        [{start, {max(length, stop - start), gap? or start == stop}, priority} | rest]

      {_unit, start, stop}, acc ->
        [{start, {stop - start, start == stop}, :erlang.phash2({:review_head, start})} | acc]
    end)
    |> Enum.reverse()
  end

  @spec summarize(non_neg_integer(), head(), summary() | nil, summary() | nil) :: summary()
  defp summarize(start, head, left, right) do
    {max(reach(start, head), max(furthest(left), furthest(right))),
     1 + count(left) + count(right)}
  end

  @spec reach(non_neg_integer(), head()) :: non_neg_integer()
  defp reach(start, {length, _gap?}), do: start + max(0, length - 1)

  @spec furthest(summary() | nil) :: non_neg_integer()
  defp furthest(nil), do: 0
  defp furthest({last, _count}), do: last

  @spec count(summary() | nil) :: non_neg_integer()
  defp count(nil), do: 0
  defp count({_last, total}), do: total

  @spec shift_summary(summary(), integer()) :: summary()
  defp shift_summary({last, total}, delta), do: {last + delta, total}
end
