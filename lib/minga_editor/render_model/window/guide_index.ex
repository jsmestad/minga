defmodule MingaEditor.RenderModel.Window.GuideIndex do
  @moduledoc """
  Persistent index of nonblank resident rows and their raw indent levels.

  Lazy suffix shifts make structural edits logarithmic. Blank-row guide continuity is represented as compressed ranges resolved from the next nonblank row, so edits never walk a long blank suffix.
  """

  alias Minga.Core.IndentGuide
  alias Minga.RenderModel.Window.ResidentSemantics.GuideRun
  alias MingaEditor.RenderModel.Window.{LazyRowTree, VisualRow}
  alias MingaEditor.RenderModel.Window.LazyRowTree.View

  @type tree_node :: LazyRowTree.t(non_neg_integer(), non_neg_integer())

  @enforce_keys [:root, :row_count]
  defstruct [:root, :row_count]

  @type t :: %__MODULE__{root: tree_node(), row_count: non_neg_integer()}

  @spec build([VisualRow.t()], pos_integer()) :: t()
  def build(entries, tab_width) when is_list(entries) and tab_width > 0 do
    root =
      Enum.reduce(entries, nil, fn %VisualRow{} = entry, tree ->
        if blank?(entry.source_text) do
          tree
        else
          LazyRowTree.insert(
            tree,
            leaf(entry.buf_line, IndentGuide.indent_level(entry.source_text, tab_width)),
            &summarize/4,
            &shift_summary/2
          )
        end
      end)

    %__MODULE__{root: root, row_count: length(entries)}
  end

  @doc "Applies one immutable-base row splice and returns the updated index."
  @spec splice(t(), non_neg_integer(), non_neg_integer(), [VisualRow.t()], pos_integer()) :: t()
  def splice(%__MODULE__{} = index, start_row, delete_count, inserted, tab_width) do
    {left, rest} = LazyRowTree.split(index.root, start_row, &summarize/4, &shift_summary/2)

    {_removed, right} =
      LazyRowTree.split(rest, start_row + delete_count, &summarize/4, &shift_summary/2)

    shift = length(inserted) - delete_count
    right = LazyRowTree.shift(right, shift, &shift_summary/2)

    inserted_tree =
      Enum.reduce(inserted, nil, fn %VisualRow{} = entry, tree ->
        if blank?(entry.source_text) do
          tree
        else
          LazyRowTree.insert(
            tree,
            leaf(entry.buf_line, IndentGuide.indent_level(entry.source_text, tab_width)),
            &summarize/4,
            &shift_summary/2
          )
        end
      end)

    %__MODULE__{
      root:
        LazyRowTree.merge(
          LazyRowTree.merge(left, inserted_tree, &summarize/4, &shift_summary/2),
          right,
          &summarize/4,
          &shift_summary/2
        ),
      row_count: index.row_count - delete_count + length(inserted)
    }
  end

  @doc "Returns the smallest final half-open range whose blank continuity can change at a splice."
  @spec affected_bounds(t(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def affected_bounds(%__MODULE__{} = index, start_row, insert_count) do
    first =
      case previous(index.root, start_row) do
        nil -> 0
        {line, _level} -> line + 1
      end

    last =
      case next(index.root, start_row + insert_count) do
        nil -> index.row_count
        {line, _level} -> min(line + 1, index.row_count)
      end

    {first, max(last, first)}
  end

  @doc "Returns compressed resolved guide levels for a half-open row range."
  @spec runs(t(), non_neg_integer(), non_neg_integer()) :: [GuideRun.t()]
  def runs(%__MODULE__{}, start_row, end_row) when start_row >= end_row, do: []

  def runs(%__MODULE__{root: root}, start_row, end_row) do
    nodes = root |> collect(start_row, end_row, []) |> Enum.reverse()
    build_runs(nodes, start_row, end_row, []) |> Enum.reverse() |> merge_adjacent([])
  end

  @spec all_runs(t()) :: [GuideRun.t()]
  def all_runs(%__MODULE__{row_count: count} = index), do: runs(index, 0, count)

  @spec max_level(t()) :: non_neg_integer()
  def max_level(%__MODULE__{root: nil}), do: 0
  def max_level(%__MODULE__{root: root}), do: LazyRowTree.summary(root)

  @spec work(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def work(%__MODULE__{root: root}, start_row, end_row), do: count_range(root, start_row, end_row)

  defp build_runs([], cursor, end_row, acc) when cursor < end_row,
    do: [%GuideRun{start_row: cursor, end_row: end_row, level: 0} | acc]

  defp build_runs([], _cursor, _end_row, acc), do: acc

  defp build_runs([{line, level} | rest], cursor, end_row, acc) do
    acc =
      if cursor < line,
        do: [%GuideRun{start_row: cursor, end_row: line, level: level} | acc],
        else: acc

    acc = [%GuideRun{start_row: line, end_row: min(line + 1, end_row), level: level} | acc]
    build_runs(rest, line + 1, end_row, acc)
  end

  defp merge_adjacent([], acc), do: Enum.reverse(acc)
  defp merge_adjacent([run], acc), do: Enum.reverse([run | acc])

  defp merge_adjacent(
         [
           %GuideRun{end_row: edge, level: level} = left,
           %GuideRun{start_row: edge, level: level} = right | rest
         ],
         acc
       ) do
    merge_adjacent([%GuideRun{left | end_row: right.end_row} | rest], acc)
  end

  defp merge_adjacent([run | rest], acc), do: merge_adjacent(rest, [run | acc])

  defp blank?(text), do: text == "" or String.trim(text) == ""

  defp leaf(line, level) do
    LazyRowTree.leaf(line, level, :erlang.phash2({:resident_guide, line}), &summarize/4)
  end

  defp summarize(_line, level, left, right),
    do: max(level, max(left || 0, right || 0))

  defp shift_summary(summary, _shift), do: summary

  defp previous(nil, _line), do: nil

  defp previous(root, line) do
    %View{key: root_line, value: level, left: left, right: right} =
      LazyRowTree.view(root, &shift_summary/2)

    if root_line < line,
      do: previous(right, line) || {root_line, level},
      else: previous(left, line)
  end

  defp next(nil, _line), do: nil

  defp next(root, line) do
    %View{key: root_line, value: level, left: left, right: right} =
      LazyRowTree.view(root, &shift_summary/2)

    if root_line >= line, do: next(left, line) || {root_line, level}, else: next(right, line)
  end

  defp collect(nil, _start, _end, acc), do: acc

  defp collect(root, start_row, end_row, acc) do
    %View{key: line, value: level, left: left, right: right} =
      LazyRowTree.view(root, &shift_summary/2)

    acc = if line >= start_row, do: collect(left, start_row, end_row, acc), else: acc
    acc = if line >= start_row and line < end_row, do: [{line, level} | acc], else: acc
    if line < end_row, do: collect(right, start_row, end_row, acc), else: acc
  end

  defp count_range(nil, _start, _end), do: 0

  defp count_range(root, start_row, end_row) do
    root |> collect(start_row, end_row, []) |> length()
  end
end
