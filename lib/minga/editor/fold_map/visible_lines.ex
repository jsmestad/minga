defmodule Minga.Editor.FoldMap.VisibleLines do
  @moduledoc """
  Computes the mapping from screen rows to buffer lines for a fold-aware
  viewport.

  Given a fold map, the first visible buffer line, and the number of
  screen rows, produces a list describing what to render at each row.
  The content stage uses this to skip folded lines and show fold summaries.
  """

  alias Minga.Editor.FoldMap
  alias Minga.Editing.Fold.Range, as: FoldRange

  @typedoc """
  What to render at a screen row.

  - `{buf_line, :normal}` — render the buffer line normally
  - `{buf_line, {:fold_start, hidden_count}}` — render the buffer line
    with a fold summary suffix showing how many lines are hidden
  """
  @type line_entry :: {non_neg_integer(), :normal | {:fold_start, pos_integer()}}

  @doc """
  Computes the list of visible line entries for a viewport.

  `first_buf_line` is the first buffer line to show (typically from
  viewport scrolling). `visible_rows` is the number of screen rows.
  `total_lines` is the total line count in the buffer.

  Returns a list of `line_entry()` tuples, one per screen row (up to
  `visible_rows`). Folded regions are skipped; fold start lines include
  the hidden count.

  When the fold map is empty, returns nil to signal the caller to use
  the existing (faster) sequential path.
  """
  @spec compute(FoldMap.t(), non_neg_integer(), pos_integer(), non_neg_integer()) ::
          [line_entry()] | nil
  def compute(%FoldMap{folds: []}, _first, _rows, _total), do: nil

  def compute(%FoldMap{} = fm, first_buf_line, visible_rows, total_lines) do
    build_entries(fm, first_buf_line, visible_rows, total_lines, [])
  end

  @spec build_entries(FoldMap.t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), [
          line_entry()
        ]) ::
          [line_entry()]
  defp build_entries(_fm, _buf_line, 0, _total, acc), do: Enum.reverse(acc)

  defp build_entries(_fm, buf_line, _remaining, total, acc) when buf_line >= total,
    do: Enum.reverse(acc)

  defp build_entries(fm, buf_line, remaining, total, acc) do
    case FoldMap.fold_at(fm, buf_line) do
      {:ok, %FoldRange{start_line: start, end_line: end_line}} when buf_line == start ->
        # This is a fold start line: show it with summary
        hidden = end_line - start
        entry = {buf_line, {:fold_start, hidden}}
        # Skip to after the fold
        build_entries(fm, end_line + 1, remaining - 1, total, [entry | acc])

      {:ok, %FoldRange{end_line: end_line}} ->
        # Inside a fold but not at start (shouldn't happen if first_buf_line
        # is correctly computed, but handle gracefully)
        build_entries(fm, end_line + 1, remaining, total, acc)

      :none ->
        entry = {buf_line, :normal}
        build_entries(fm, buf_line + 1, remaining - 1, total, [entry | acc])
    end
  end

  @doc """
  Returns the buffer line range needed to fetch all visible lines.

  This is used to request the right slice from the buffer. Returns
  `{first_buf_line, last_buf_line}` (inclusive). The caller should
  fetch lines from first to last and index into them.
  """
  @spec buffer_range([line_entry()]) :: {non_neg_integer(), non_neg_integer()} | nil
  def buffer_range([]), do: nil

  def buffer_range(entries) do
    {first, _} = List.first(entries)
    {last, _} = List.last(entries)
    {first, last}
  end
end
