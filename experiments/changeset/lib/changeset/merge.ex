defmodule Changeset.Merge do
  @moduledoc """
  Three-way merge for text content.

  Takes a common ancestor, the changeset's version ("ours"), and the
  current real version ("theirs"). Produces a merged result or reports
  conflicting hunks.

  Uses `List.myers_difference/2` for diffing (same algorithm as git).
  """

  @typedoc "A conflict hunk showing divergent changes."
  @type hunk :: %{
          line_start: non_neg_integer(),
          ancestor: [String.t()],
          ours: [String.t()],
          theirs: [String.t()]
        }

  @doc """
  Performs a three-way merge.

  - `ancestor`: content at the time the changeset was created
  - `ours`: the changeset's version
  - `theirs`: the current real file content

  Returns `{:ok, merged_content}` if changes don't overlap, or
  `{:conflict, [hunk]}` if they do.
  """
  @spec three_way(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:conflict, [hunk()]}
  def three_way(ancestor, ours, theirs) do
    ancestor_lines = String.split(ancestor, "\n", trim: false)
    ours_lines = String.split(ours, "\n", trim: false)
    theirs_lines = String.split(theirs, "\n", trim: false)

    # Compute diffs from ancestor to each version
    our_changes = diff_to_ranges(ancestor_lines, ours_lines)
    their_changes = diff_to_ranges(ancestor_lines, theirs_lines)

    # Check for overlapping changes
    case find_conflicts(our_changes, their_changes) do
      [] ->
        # No conflicts: apply both sets of changes
        merged = apply_changes(ancestor_lines, our_changes, their_changes)
        {:ok, Enum.join(merged, "\n")}

      conflicts ->
        {:conflict, build_conflict_hunks(ancestor_lines, ours_lines, theirs_lines, conflicts)}
    end
  end

  # -- Private --

  # Converts a Myers diff into a list of change ranges.
  # Each range is {:change, start_line, end_line, replacement_lines}
  defp diff_to_ranges(ancestor, modified) do
    diff = List.myers_difference(ancestor, modified)
    {ranges, _line} = Enum.reduce(diff, {[], 0}, &collect_range/2)
    Enum.reverse(ranges)
  end

  defp collect_range({:eq, lines}, {acc, line}) do
    {acc, line + length(lines)}
  end

  defp collect_range({:del, lines}, {acc, line}) do
    range_end = line + length(lines)
    # Look ahead: if next is :ins, combine into a replace
    {acc, range_end, lines}
    # We'll handle del+ins pairing in the reducer
    {[{:del, line, range_end, lines} | acc], range_end}
  end

  defp collect_range({:ins, lines}, {[{:del, start, del_end, _del_lines} | rest], _line}) do
    # Combine del+ins into a single replace operation
    {[{:change, start, del_end, lines} | rest], del_end}
  end

  defp collect_range({:ins, lines}, {acc, line}) do
    # Pure insertion (no preceding delete)
    {[{:change, line, line, lines} | acc], line}
  end

  # Find pairs of changes from ours and theirs that overlap.
  defp find_conflicts(our_changes, their_changes) do
    for our <- our_changes,
        their <- their_changes,
        ranges_overlap?(our, their) do
      {our, their}
    end
  end

  defp ranges_overlap?({_, our_start, our_end, _}, {_, their_start, their_end, _}) do
    our_start < their_end and their_start < our_end
  end

  # Apply non-conflicting changes from both sides to the ancestor.
  defp apply_changes(ancestor_lines, our_changes, their_changes) do
    # Merge all changes, sorted by position. Apply in reverse order
    # (from end of file to beginning) so line numbers stay valid.
    all_changes =
      (our_changes ++ their_changes)
      |> Enum.sort_by(fn {_, start, _, _} -> start end, :desc)
      |> Enum.dedup()

    Enum.reduce(all_changes, ancestor_lines, fn {_, start, end_line, replacement}, lines ->
      before = Enum.take(lines, start)
      after_lines = Enum.drop(lines, end_line)
      before ++ replacement ++ after_lines
    end)
  end

  defp build_conflict_hunks(ancestor_lines, ours_lines, theirs_lines, conflicts) do
    Enum.map(conflicts, fn {{_, our_start, our_end, _}, {_, their_start, their_end, _}} ->
      start = min(our_start, their_start)
      anc_end = max(our_end, their_end)

      %{
        line_start: start,
        ancestor: Enum.slice(ancestor_lines, start, anc_end - start),
        ours: Enum.slice(ours_lines, our_start, our_end - our_start),
        theirs: Enum.slice(theirs_lines, their_start, their_end - their_start)
      }
    end)
  end
end
