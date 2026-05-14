defmodule Minga.Core.Diff do
  @moduledoc """
  In-memory line diffing and hunk operations.

  Uses `List.myers_difference/2` to compute line-level diffs between
  two versions of text. Produces hunk structs consumed by git gutter
  rendering, hunk navigation, AI diff review, and patch generation.

  Pure computation with no side effects.
  """

  @typedoc """
  A contiguous region of change.

  * `:added` — new lines not in the base
  * `:modified` — lines that differ from the base
  * `:deleted` — lines removed from the base (rendered on the line above)
  """
  @type hunk_type :: :added | :modified | :deleted

  @typedoc """
  A hunk represents a contiguous group of changed lines.

  * `type` — the kind of change
  * `start_line` — first buffer line affected (0-indexed)
  * `count` — number of buffer lines in this hunk (0 for pure deletions)
  * `old_start` — first line in the base content (0-indexed)
  * `old_count` — number of base lines replaced/deleted
  * `old_lines` — the original lines from base (for revert and preview)
  """
  @type hunk :: %{
          type: hunk_type(),
          start_line: non_neg_integer(),
          count: non_neg_integer(),
          old_start: non_neg_integer(),
          old_count: non_neg_integer(),
          old_lines: [String.t()]
        }

  @typedoc "A word-level diff segment: equal, deleted, or inserted text."
  @type word_segment :: {:eq | :del | :ins, String.t()}

  @typedoc "A character range within a line: {start_col, end_col} (0-based, exclusive end)."
  @type char_range :: {non_neg_integer(), non_neg_integer()}

  @doc """
  Diffs base lines against current lines and returns a list of hunks.

  Both inputs should be lists of strings (one per line, without trailing newlines).
  """
  @spec diff_lines([String.t()], [String.t()]) :: [hunk()]
  def diff_lines(base_lines, current_lines) do
    List.myers_difference(base_lines, current_lines)
    |> build_hunks(0, 0, [])
    |> Enum.reverse()
  end

  @doc """
  Computes character-level differences between two strings.

  Returns a list of tagged segments indicating equal, deleted, and inserted
  character ranges. Skips computation for lines longer than 500 characters,
  returning the full old line as `:del` and full new line as `:ins`.
  """
  @spec word_diff(String.t(), String.t()) :: [word_segment()]
  def word_diff(old_line, new_line)
      when byte_size(old_line) > 500 or byte_size(new_line) > 500 do
    [{:del, old_line}, {:ins, new_line}]
  end

  def word_diff(old_line, new_line) do
    String.myers_difference(old_line, new_line)
  end

  @doc """
  Extracts character ranges for changed segments from a word-level diff.

  Returns `{del_ranges, ins_ranges}` where each range is `{start_col, end_col}`
  with 0-based start and exclusive end. Ranges track column offsets from the
  perspective of each side: `:del` ranges index into the old line, `:ins` ranges
  index into the new line.
  """
  @spec word_diff_ranges(String.t(), String.t()) :: {[char_range()], [char_range()]}
  def word_diff_ranges(old_line, new_line) do
    segments = word_diff(old_line, new_line)
    del_ranges = extract_ranges(segments, :del)
    ins_ranges = extract_ranges(segments, :ins)
    {del_ranges, ins_ranges}
  end

  @doc """
  Converts hunks to a per-line sign map for the gutter renderer.

  Returns `%{line_number => :added | :modified | :deleted}`.
  Deleted hunks are placed on the line above the deletion point
  (or line 0 if deleted at the start).
  """
  @spec signs_for_hunks([hunk()]) :: %{non_neg_integer() => hunk_type()}
  def signs_for_hunks(hunks) do
    Enum.reduce(hunks, %{}, &add_hunk_signs/2)
  end

  @spec add_hunk_signs(hunk(), %{non_neg_integer() => hunk_type()}) ::
          %{non_neg_integer() => hunk_type()}
  defp add_hunk_signs(%{type: :deleted, start_line: start}, acc) do
    sign_line = max(0, start - 1)
    Map.put_new(acc, sign_line, :deleted)
  end

  defp add_hunk_signs(%{type: type, start_line: start, count: count}, acc) do
    Enum.reduce(0..(count - 1)//1, acc, fn offset, inner_acc ->
      Map.put(inner_acc, start + offset, type)
    end)
  end

  @doc """
  Finds the hunk containing or nearest to the given buffer line.
  """
  @spec hunk_at_line([hunk()], non_neg_integer()) :: hunk() | nil
  def hunk_at_line([], _line), do: nil

  def hunk_at_line(hunks, line) do
    Enum.find(hunks, fn hunk ->
      case hunk.type do
        :deleted ->
          hunk.start_line == line or hunk.start_line - 1 == line

        _ ->
          line >= hunk.start_line and line < hunk.start_line + hunk.count
      end
    end)
  end

  @doc """
  Finds the start line of the next hunk after the given line.
  Returns `nil` if no hunk follows.
  """
  @spec next_hunk_line([hunk()], non_neg_integer()) :: non_neg_integer() | nil
  def next_hunk_line(hunks, line) do
    hunks
    |> Enum.filter(fn h -> h.start_line > line end)
    |> case do
      [] -> nil
      [first | _] -> first.start_line
    end
  end

  @doc """
  Finds the start line of the previous hunk before the given line.
  Returns `nil` if no hunk precedes.
  """
  @spec prev_hunk_line([hunk()], non_neg_integer()) :: non_neg_integer() | nil
  def prev_hunk_line(hunks, line) do
    hunks
    |> Enum.filter(fn h -> h.start_line < line end)
    |> List.last()
    |> case do
      nil -> nil
      hunk -> hunk.start_line
    end
  end

  @doc """
  Returns buffer lines with the given hunk reverted to base content.

  For added hunks: removes the added lines.
  For modified hunks: replaces with the old lines.
  For deleted hunks: re-inserts the old lines at the deletion point.
  """
  @spec revert_hunk([String.t()], hunk()) :: [String.t()]
  def revert_hunk(current_lines, %{type: :added, start_line: start, count: count}) do
    {before, rest} = Enum.split(current_lines, start)
    {_removed, after_} = Enum.split(rest, count)
    before ++ after_
  end

  def revert_hunk(current_lines, %{type: :modified, start_line: start, count: count} = hunk) do
    {before, rest} = Enum.split(current_lines, start)
    {_removed, after_} = Enum.split(rest, count)
    before ++ hunk.old_lines ++ after_
  end

  def revert_hunk(current_lines, %{type: :deleted, start_line: start} = hunk) do
    {before, after_} = Enum.split(current_lines, start)
    before ++ hunk.old_lines ++ after_
  end

  @doc """
  Generates a unified diff patch for a single hunk.

  The patch can be fed to `git apply --cached` to stage just this hunk.
  Uses the standard unified diff format with `a/` and `b/` path prefixes.
  """
  @spec generate_patch(String.t(), [String.t()], [String.t()], hunk()) :: String.t()
  def generate_patch(relative_path, base_lines, current_lines, hunk) do
    # Context lines around the hunk (standard 3 lines)
    ctx = 3

    {old_start, old_end} = base_range(hunk, length(base_lines), ctx)
    {new_start, new_end} = current_range(hunk, length(current_lines), ctx)

    old_context_lines = Enum.slice(base_lines, old_start..(old_end - 1)//1)
    new_context_lines = Enum.slice(current_lines, new_start..(new_end - 1)//1)

    # Build unified diff body
    diff_body = unified_diff_body(old_context_lines, new_context_lines)

    old_count = old_end - old_start
    new_count = new_end - new_start

    header = [
      "--- a/#{relative_path}\n",
      "+++ b/#{relative_path}\n",
      "@@ -#{old_start + 1},#{old_count} +#{new_start + 1},#{new_count} @@\n"
    ]

    IO.iodata_to_binary([header | diff_body])
  end

  # ── Private: word-level diff helpers ────────────────────────────────────────

  @spec extract_ranges([word_segment()], :del | :ins) :: [char_range()]
  defp extract_ranges(segments, target_tag) do
    skip_tag = opposite_tag(target_tag)

    {ranges, _offset} =
      Enum.reduce(segments, {[], 0}, fn
        {^skip_tag, _text}, {acc, offset} ->
          # The opposite side's text doesn't advance our column offset
          {acc, offset}

        {^target_tag, text}, {acc, offset} ->
          len = String.length(text)
          {[{offset, offset + len} | acc], offset + len}

        {:eq, text}, {acc, offset} ->
          {acc, offset + String.length(text)}
      end)

    Enum.reverse(ranges)
  end

  @spec opposite_tag(:del | :ins) :: :ins | :del
  defp opposite_tag(:del), do: :ins
  defp opposite_tag(:ins), do: :del

  # ── Private: hunk building ─────────────────────────────────────────────────

  @spec build_hunks([{atom(), [String.t()]}], non_neg_integer(), non_neg_integer(), [hunk()]) ::
          [hunk()]
  defp build_hunks([], _cur, _base, acc), do: acc

  defp build_hunks([{:eq, lines} | rest], cur, base, acc) do
    len = length(lines)
    build_hunks(rest, cur + len, base + len, acc)
  end

  # Delete followed by insert = modification
  defp build_hunks([{:del, del_lines}, {:ins, ins_lines} | rest], cur, base, acc) do
    hunk = %{
      type: :modified,
      start_line: cur,
      count: length(ins_lines),
      old_start: base,
      old_count: length(del_lines),
      old_lines: del_lines
    }

    build_hunks(rest, cur + length(ins_lines), base + length(del_lines), [hunk | acc])
  end

  # Pure deletion
  defp build_hunks([{:del, del_lines} | rest], cur, base, acc) do
    hunk = %{
      type: :deleted,
      start_line: cur,
      count: 0,
      old_start: base,
      old_count: length(del_lines),
      old_lines: del_lines
    }

    build_hunks(rest, cur, base + length(del_lines), [hunk | acc])
  end

  # Pure insertion
  defp build_hunks([{:ins, ins_lines} | rest], cur, base, acc) do
    hunk = %{
      type: :added,
      start_line: cur,
      count: length(ins_lines),
      old_start: base,
      old_count: 0,
      old_lines: []
    }

    build_hunks(rest, cur + length(ins_lines), base, [hunk | acc])
  end

  # ── Three-way merge ─────────────────────────────────────────────────────────

  @typedoc """
  A hunk in a three-way merge result.

  * `{:resolved, lines}` — auto-merged content (from either side or unchanged)
  * `{:conflict, fork_lines, parent_lines}` — both sides changed the same region
  """
  @type merge_hunk :: {:resolved, [String.t()]} | {:conflict, [String.t()], [String.t()]}

  @typedoc "Result of a three-way merge."
  @type merge3_result :: {:ok, [String.t()]} | {:conflict, [merge_hunk()]}

  @doc """
  Three-way merge: given a common ancestor and two divergent versions (fork and parent),
  produces a merged result or identifies conflicts.

  Non-overlapping changes from both sides are merged automatically.
  Overlapping changes (both sides modified the same region of the ancestor)
  become conflicts.

  Returns `{:ok, merged_lines}` when all changes merge cleanly, or
  `{:conflict, merge_hunks}` when at least one conflict exists.
  The hunks list contains both resolved and conflicting regions.
  """
  @spec merge3([String.t()], [String.t()], [String.t()]) ::
          {:ok, [String.t()]} | {:conflict, [merge_hunk()]}
  def merge3(ancestor, fork, parent) when parent == ancestor, do: {:ok, fork}
  def merge3(ancestor, fork, parent) when fork == ancestor, do: {:ok, parent}
  def merge3(_ancestor, fork, parent) when fork == parent, do: {:ok, fork}

  def merge3(ancestor, fork, parent) do
    # Compute diffs from ancestor to each side
    fork_ops = List.myers_difference(ancestor, fork)
    parent_ops = List.myers_difference(ancestor, parent)

    # Convert myers ops to indexed edit regions
    fork_edits = ops_to_edits(fork_ops)
    parent_edits = ops_to_edits(parent_ops)

    # Walk both edit lists and merge
    hunks = merge_edits(ancestor, fork_edits, parent_edits)

    if Enum.any?(hunks, &match?({:conflict, _, _}, &1)) do
      {:conflict, hunks}
    else
      merged = Enum.flat_map(hunks, fn {:resolved, lines} -> lines end)
      {:ok, merged}
    end
  end

  # Converts myers_difference ops into a list of {start, count, replacement_lines}
  # edit records, where start/count refer to the ancestor line range.
  @spec ops_to_edits([{atom(), [String.t()]}]) :: [
          {non_neg_integer(), non_neg_integer(), [String.t()]}
        ]
  defp ops_to_edits(ops) do
    {edits, _pos} =
      Enum.reduce(ops, {[], 0}, fn
        {:eq, lines}, {acc, pos} ->
          {acc, pos + length(lines)}

        {:del, del_lines}, {acc, pos} ->
          {[{pos, length(del_lines), :pending_del} | acc], pos + length(del_lines)}

        {:ins, ins_lines}, {[{start, count, :pending_del} | rest], pos} ->
          # del followed by ins = replacement
          {[{start, count, ins_lines} | rest], pos}

        {:ins, ins_lines}, {acc, pos} ->
          # pure insertion at current position
          {[{pos, 0, ins_lines} | acc], pos}
      end)

    # Resolve any trailing pending_del (pure deletion)
    edits
    |> Enum.map(fn
      {start, count, :pending_del} -> {start, count, []}
      edit -> edit
    end)
    |> Enum.reverse()
  end

  # Walks both edit lists against the ancestor, producing merge hunks.
  @spec merge_edits([String.t()], [{non_neg_integer(), non_neg_integer(), [String.t()]}], [
          {non_neg_integer(), non_neg_integer(), [String.t()]}
        ]) :: [merge_hunk()]
  defp merge_edits(ancestor, fork_edits, parent_edits) do
    do_merge(ancestor, 0, fork_edits, parent_edits, [])
    |> Enum.reverse()
  end

  # Both edit lists exhausted: emit remaining ancestor lines.
  defp do_merge(ancestor_remaining, _pos, [], [], acc) do
    prepend_non_empty_resolved(ancestor_remaining, acc)
  end

  # Only fork edits remain.
  defp do_merge(ancestor_remaining, pos, [fe | fork_rest], [], acc) do
    {start, count, replacement} = fe
    end_pos = start + count

    {unchanged, ancestor_remaining} =
      consume_ancestor_region(ancestor_remaining, pos, start, end_pos)

    acc = prepend_non_empty_resolved(unchanged, acc)
    acc = [{:resolved, replacement} | acc]
    do_merge(ancestor_remaining, end_pos, fork_rest, [], acc)
  end

  # Only parent edits remain.
  defp do_merge(ancestor_remaining, pos, [], [pe | parent_rest], acc) do
    {start, count, replacement} = pe
    end_pos = start + count

    {unchanged, ancestor_remaining} =
      consume_ancestor_region(ancestor_remaining, pos, start, end_pos)

    acc = prepend_non_empty_resolved(unchanged, acc)
    acc = [{:resolved, replacement} | acc]
    do_merge(ancestor_remaining, end_pos, [], parent_rest, acc)
  end

  # Both sides have edits: pick the earlier one, detect overlaps.
  defp do_merge(
         ancestor_remaining,
         pos,
         [fe | fork_rest] = fork_edits,
         [pe | parent_rest] = parent_edits,
         acc
       ) do
    {f_start, f_count, f_replacement} = fe
    {p_start, p_count, p_replacement} = pe

    f_end = f_start + f_count
    p_end = p_start + p_count

    cond do
      # Both sides made the same change (identical replacement for the same region).
      # Must be checked before the "before" conditions because identical insertions
      # at the same position (f_end == p_start) would otherwise be duplicated.
      f_start == p_start and f_count == p_count and f_replacement == p_replacement ->
        {unchanged, ancestor_remaining} =
          consume_ancestor_region(ancestor_remaining, pos, f_start, f_end)

        acc = prepend_non_empty_resolved(unchanged, acc)
        acc = [{:resolved, f_replacement} | acc]
        do_merge(ancestor_remaining, f_end, fork_rest, parent_rest, acc)

      # Fork edit is entirely before parent edit (no overlap).
      f_end <= p_start ->
        {unchanged, ancestor_remaining} =
          consume_ancestor_region(ancestor_remaining, pos, f_start, f_end)

        acc = prepend_non_empty_resolved(unchanged, acc)
        acc = [{:resolved, f_replacement} | acc]
        do_merge(ancestor_remaining, f_end, fork_rest, parent_edits, acc)

      # Parent edit is entirely before fork edit (no overlap).
      p_end <= f_start ->
        {unchanged, ancestor_remaining} =
          consume_ancestor_region(ancestor_remaining, pos, p_start, p_end)

        acc = prepend_non_empty_resolved(unchanged, acc)
        acc = [{:resolved, p_replacement} | acc]
        do_merge(ancestor_remaining, p_end, fork_edits, parent_rest, acc)

      # Overlap: conflict.
      true ->
        conflict_start = min(f_start, p_start)
        conflict_end = max(f_end, p_end)

        {unchanged, ancestor_remaining} =
          consume_ancestor_region(ancestor_remaining, pos, conflict_start, conflict_end)

        acc = prepend_non_empty_resolved(unchanged, acc)
        acc = [{:conflict, f_replacement, p_replacement} | acc]

        {fork_rest2, parent_rest2} = skip_consumed_edits(fork_rest, parent_rest, conflict_end)
        do_merge(ancestor_remaining, conflict_end, fork_rest2, parent_rest2, acc)
    end
  end

  @spec prepend_non_empty_resolved([String.t()], [merge_hunk()]) :: [merge_hunk()]
  defp prepend_non_empty_resolved([], acc), do: acc
  defp prepend_non_empty_resolved(lines, acc), do: [{:resolved, lines} | acc]

  @spec consume_ancestor_region(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {[String.t()], [String.t()]}
  defp consume_ancestor_region(ancestor_remaining, pos, start, end_pos) do
    unprocessed_start = max(start, pos)
    {unchanged, at_edit} = Enum.split(ancestor_remaining, max(start - pos, 0))
    {_consumed, remaining} = Enum.split(at_edit, max(end_pos - unprocessed_start, 0))
    {unchanged, remaining}
  end

  # Skip edits that fall within the conflict region
  @spec skip_consumed_edits(
          [{non_neg_integer(), non_neg_integer(), [String.t()]}],
          [{non_neg_integer(), non_neg_integer(), [String.t()]}],
          non_neg_integer()
        ) ::
          {[{non_neg_integer(), non_neg_integer(), [String.t()]}],
           [{non_neg_integer(), non_neg_integer(), [String.t()]}]}
  defp skip_consumed_edits(fork_edits, parent_edits, conflict_end) do
    fork_rest =
      Enum.drop_while(fork_edits, fn {start, count, _} -> start + count <= conflict_end end)

    parent_rest =
      Enum.drop_while(parent_edits, fn {start, count, _} -> start + count <= conflict_end end)

    {fork_rest, parent_rest}
  end

  # ── Private: patch generation ──────────────────────────────────────────────

  @spec base_range(hunk(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp base_range(hunk, base_len, ctx) do
    start = max(0, hunk.old_start - ctx)
    end_ = min(base_len, hunk.old_start + hunk.old_count + ctx)
    {start, end_}
  end

  @spec current_range(hunk(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp current_range(hunk, cur_len, ctx) do
    start = max(0, hunk.start_line - ctx)
    end_ = min(cur_len, hunk.start_line + hunk.count + ctx)
    {start, end_}
  end

  @spec unified_diff_body([String.t()], [String.t()]) :: iodata()
  defp unified_diff_body(old_lines, new_lines) do
    List.myers_difference(old_lines, new_lines)
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &" #{&1}\n")
      {:del, lines} -> Enum.map(lines, &"-#{&1}\n")
      {:ins, lines} -> Enum.map(lines, &"+#{&1}\n")
    end)
  end
end
