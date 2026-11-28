defmodule Minga.Core.Diff do
  @moduledoc """
  In-memory line diffing and hunk operations.

  Uses `List.myers_difference/2` for nonempty line-level comparisons and direct hunks for whole-file additions and deletions. Produces hunks consumed by git gutter rendering, hunk navigation, AI diff review, and patch generation.

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
  def diff_lines([], []), do: []

  def diff_lines([], current_lines) when is_list(current_lines) do
    [
      %{
        type: :added,
        start_line: 0,
        count: length(current_lines),
        old_start: 0,
        old_count: 0,
        old_lines: []
      }
    ]
  end

  def diff_lines(base_lines, []) when is_list(base_lines) do
    [
      %{
        type: :deleted,
        start_line: 0,
        count: 0,
        old_start: 0,
        old_count: length(base_lines),
        old_lines: base_lines
      }
    ]
  end

  def diff_lines(base_lines, current_lines) do
    List.myers_difference(base_lines, current_lines)
    |> build_hunks(0, 0, [])
    |> Enum.reverse()
  end

  @doc """
  Returns the hunks of `diff_lines/2` when at most `max_edits` lines must be deleted or inserted to turn `base_lines` into `current_lines`, and `:over_budget` otherwise.

  A line diff costs time proportional to the line count times the number of edited lines, so reordering or rewriting a large file can take seconds. This function first measures that edit count with the same greedy algorithm and stops as soon as it passes `max_edits`, so the refusal costs at most about `(length(base_lines) + length(current_lines)) * max_edits` steps, and an accepted diff costs about the same again. A deleted line and an inserted line are one edit each, so a changed line is two.
  """
  @spec diff_lines_within([String.t()], [String.t()], non_neg_integer()) ::
          {:ok, [hunk()]} | :over_budget
  def diff_lines_within(base_lines, current_lines, max_edits)
      when is_list(base_lines) and is_list(current_lines) and is_integer(max_edits) and
             max_edits >= 0 do
    if edits_within?(List.to_tuple(base_lines), List.to_tuple(current_lines), max_edits),
      do: {:ok, diff_lines(base_lines, current_lines)},
      else: :over_budget
  end

  # Myers' greedy shortest-edit-script search, measuring only the distance.
  # Round `edits` extends the furthest-reaching path on every diagonal `k = x - y` within reach.
  # `reach` maps each diagonal to the base index its path has consumed.
  @spec edits_within?(tuple(), tuple(), non_neg_integer()) :: boolean()
  defp edits_within?(base, current, max_edits) do
    abs(tuple_size(base) - tuple_size(current)) <= max_edits and
      edit_rounds(base, current, 0, max_edits, %{1 => 0})
  end

  @spec edit_rounds(tuple(), tuple(), non_neg_integer(), non_neg_integer(), %{
          integer() => non_neg_integer()
        }) :: boolean()
  defp edit_rounds(_base, _current, edits, max_edits, _reach) when edits > max_edits, do: false

  defp edit_rounds(base, current, edits, max_edits, reach) do
    case extend_diagonals(base, current, edits, -edits, reach) do
      :reached_end -> true
      {:continue, reach} -> edit_rounds(base, current, edits + 1, max_edits, reach)
    end
  end

  @spec extend_diagonals(tuple(), tuple(), non_neg_integer(), integer(), %{
          integer() => non_neg_integer()
        }) :: :reached_end | {:continue, %{integer() => non_neg_integer()}}
  defp extend_diagonals(_base, _current, edits, k, reach) when k > edits, do: {:continue, reach}

  defp extend_diagonals(base, current, edits, k, reach) do
    x =
      if k == -edits or (k != edits and Map.fetch!(reach, k - 1) < Map.fetch!(reach, k + 1)),
        do: Map.fetch!(reach, k + 1),
        else: Map.fetch!(reach, k - 1) + 1

    x = follow_matches(base, current, x, x - k)

    if x >= tuple_size(base) and x - k >= tuple_size(current),
      do: :reached_end,
      else: extend_diagonals(base, current, edits, k + 2, Map.put(reach, k, x))
  end

  # Follows equal lines diagonally from `{x, y}` and returns the base index it stops at.
  @spec follow_matches(tuple(), tuple(), non_neg_integer(), integer()) :: non_neg_integer()
  defp follow_matches(base, current, x, y)
       when x < tuple_size(base) and y >= 0 and y < tuple_size(current) do
    if elem(base, x) == elem(current, y),
      do: follow_matches(base, current, x + 1, y + 1),
      else: x
  end

  defp follow_matches(_base, _current, x, _y), do: x

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
    len = Enum.count(lines)
    build_hunks(rest, cur + len, base + len, acc)
  end

  # Delete followed by insert = modification
  defp build_hunks([{:del, del_lines}, {:ins, ins_lines} | rest], cur, base, acc) do
    hunk = %{
      type: :modified,
      start_line: cur,
      count: Enum.count(ins_lines),
      old_start: base,
      old_count: Enum.count(del_lines),
      old_lines: del_lines
    }

    build_hunks(rest, cur + Enum.count(ins_lines), base + Enum.count(del_lines), [hunk | acc])
  end

  # Pure deletion
  defp build_hunks([{:del, del_lines} | rest], cur, base, acc) do
    hunk = %{
      type: :deleted,
      start_line: cur,
      count: 0,
      old_start: base,
      old_count: Enum.count(del_lines),
      old_lines: del_lines
    }

    build_hunks(rest, cur, base + Enum.count(del_lines), [hunk | acc])
  end

  # Pure insertion
  defp build_hunks([{:ins, ins_lines} | rest], cur, base, acc) do
    hunk = %{
      type: :added,
      start_line: cur,
      count: Enum.count(ins_lines),
      old_start: base,
      old_count: 0,
      old_lines: []
    }

    build_hunks(rest, cur + Enum.count(ins_lines), base, [hunk | acc])
  end

  # ── Three-way merge ─────────────────────────────────────────────────────────

  @typedoc """
  A hunk in a three-way merge result.

  * `{:resolved, lines}` — auto-merged content (from either side or unchanged)
  * `{:conflict, fork_lines, parent_lines}` — both sides changed the same region
  """
  @type merge_hunk :: {:resolved, [String.t()]} | {:conflict, [String.t()], [String.t()]}

  # Ancestor start and length, replacement lines, and their start in the writing side.
  @typep merge_edit :: {non_neg_integer(), non_neg_integer(), [String.t()], non_neg_integer()}

  @typedoc "A fork line interval kept at a known line in a publication result."
  @type placement ::
          {fork_line :: non_neg_integer(), result_line :: non_neg_integer(),
           count :: pos_integer()}

  @typep choice :: {[String.t()], [placement()]}

  @typedoc "Lines retained from the parent, or fork lines to replay against an unchanged ancestor interval in the parent."
  @type parent_alignment ::
          {:keep, placement()}
          | {:reconcile, non_neg_integer(), non_neg_integer(), non_neg_integer(),
             non_neg_integer()}
          | {:replay, ancestor_line :: non_neg_integer(), parent_line :: non_neg_integer(),
             parent_count :: non_neg_integer(), fork_line :: non_neg_integer(),
             result_line :: non_neg_integer(), result_count :: non_neg_integer()}

  @typedoc "The merged lines, selected fork positions, and the parent alignment of the same merge."
  @type projected_merge :: {choice(), [parent_alignment()]}

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
    regions = merge_regions(ancestor, fork, parent)

    if Enum.any?(regions, &match?({:conflict, _, _, _}, &1)) do
      {:conflict, Enum.map(regions, &review_region/1)}
    else
      merged = Enum.flat_map(regions, fn region -> elem(region, 1) end)
      {:ok, merged}
    end
  end

  @typedoc "A three-way region retaining the ancestor-relative Agent edits."
  @type merge_region ::
          {:resolved, [String.t()]}
          | {:fork | :shared, [String.t()], merge_edit()}
          | {:conflict, [String.t()], [String.t()], {[merge_edit()], non_neg_integer()}}

  @doc "Produces the ordered merge regions without discarding fork edit provenance."
  @spec merge_regions([String.t()], [String.t()], [String.t()], :by_text | [placement()]) ::
          [merge_region()]
  def merge_regions(ancestor, fork, parent, retained \\ :by_text) do
    fork_edits = fork_edits(ancestor, fork, retained)
    parent_edits = ancestor |> List.myers_difference(parent) |> ops_to_edits()
    merge_edits(ancestor, fork_edits, parent_edits)
  end

  @spec fork_edits([String.t()], [String.t()], :by_text | [placement()]) :: [merge_edit()]
  defp fork_edits(ancestor, fork, :by_text),
    do: ancestor |> List.myers_difference(fork) |> ops_to_edits()

  defp fork_edits(ancestor, fork, retained),
    do: anchored_edits(ancestor, fork, retained, {0, 0}, [])

  @spec anchored_edits(
          [String.t()],
          [String.t()],
          [placement()],
          {non_neg_integer(), non_neg_integer()},
          [merge_edit()]
        ) :: [merge_edit()]
  defp anchored_edits(ancestor, fork, [], {base, side}, edits) do
    Enum.reverse(prepend_edit(ancestor, fork, base, side, edits))
  end

  defp anchored_edits(ancestor, fork, [{old, new, count} | rest], {base, side}, edits) do
    {before, ancestor} = Enum.split(ancestor, old - base)
    {after_edit, fork} = Enum.split(fork, new - side)

    anchored_edits(
      Enum.drop(ancestor, count),
      Enum.drop(fork, count),
      rest,
      {old + count, new + count},
      prepend_edit(before, after_edit, base, side, edits)
    )
  end

  @spec prepend_edit([String.t()], [String.t()], non_neg_integer(), non_neg_integer(), [
          merge_edit()
        ]) :: [merge_edit()]
  defp prepend_edit(same, same, _base, _side, edits), do: edits

  defp prepend_edit([], replacement, base, side, edits),
    do: [{base, 0, replacement, side} | edits]

  defp prepend_edit(before, [], base, side, edits),
    do: [{base, length(before), [], side} | edits]

  defp prepend_edit(before, replacement, base, side, edits) do
    # Byte-identity anchors bound the gap. A splice may still preserve whole lines inside it.
    before |> List.myers_difference(replacement) |> prepend_ops(base, side, edits)
  end

  @spec review_region(merge_region()) :: merge_hunk()
  defp review_region({side, lines, _edit}) when side in [:fork, :shared], do: {:resolved, lines}
  defp review_region({:conflict, fork, parent, _selected}), do: {:conflict, fork, parent}
  defp review_region({:resolved, _lines} = region), do: region

  @doc "Merges cleanly while retaining both source alignments of the selected result."
  @spec merge3_projected([String.t()], [String.t()], [String.t()], :by_text | [placement()]) ::
          {:ok, projected_merge()} | {:conflict, [merge_hunk()]}
  def merge3_projected(ancestor, fork, parent, retained \\ :by_text)

  def merge3_projected(ancestor, fork, ancestor, _retained) do
    count = length(fork)
    choice = {fork, place([], 0, 0, count)}
    {:ok, {choice, [{:replay, 0, 0, length(ancestor), 0, 0, count}]}}
  end

  def merge3_projected(ancestor, ancestor, parent, _retained), do: {:ok, kept_parent(parent)}
  def merge3_projected(_ancestor, fork, fork, _retained), do: {:ok, kept_parent(fork)}

  def merge3_projected(ancestor, fork, parent, retained) do
    regions = merge_regions(ancestor, fork, parent, retained)

    case resolve_regions(regions, [], [], []) do
      {:ok, ordered, _edits} -> {:ok, place_results(ordered)}
      {:error, :invalid_decisions} -> {:conflict, Enum.map(regions, &review_region/1)}
    end
  end

  @doc "Resolves the reviewed regions, retaining the actual parent and fork alignments and the selected fork."
  @spec resolve_merge([String.t()], [merge_region()], [:accepted | :rejected]) ::
          {:ok, projected_merge(), choice()} | {:error, :invalid_decisions}
  def resolve_merge(ancestor, regions, decisions) do
    case resolve_regions(regions, decisions, [], []) do
      {:ok, ordered, edits} ->
        merged = place_results(ordered)
        selected = place_edits(ancestor, edits, 0, 0, [], [])
        {:ok, merged, selected}

      {:error, :invalid_decisions} = error ->
        error
    end
  end

  @typep parent_choice ::
           :keep
           | {:replay, non_neg_integer(), non_neg_integer()}
           | {:replace, non_neg_integer()}
  @typep chosen_region :: {[String.t()], non_neg_integer() | nil, parent_choice()}

  @spec resolve_regions(
          [merge_region()],
          [:accepted | :rejected],
          [chosen_region()],
          [merge_edit()]
        ) :: {:ok, [chosen_region()], [merge_edit()]} | {:error, :invalid_decisions}
  defp resolve_regions([], [], merged, edits),
    do: {:ok, Enum.reverse(merged), Enum.reverse(edits)}

  defp resolve_regions([{:resolved, lines} | rest], decisions, merged, edits),
    do: resolve_regions(rest, decisions, [{lines, nil, :keep} | merged], edits)

  defp resolve_regions(
         [{:fork, lines, {ancestor, count, _, start} = edit} | rest],
         decisions,
         merged,
         edits
       ) do
    choice = {lines, start, {:replay, ancestor, count}}
    resolve_regions(rest, decisions, [choice | merged], [edit | edits])
  end

  defp resolve_regions(
         [{:shared, lines, {_, _, _, start} = edit} | rest],
         decisions,
         merged,
         edits
       ),
       do: resolve_regions(rest, decisions, [{lines, start, :keep} | merged], [edit | edits])

  defp resolve_regions(
         [{:conflict, lines, lines, {selected, start}} | rest],
         decisions,
         merged,
         edits
       ),
       do:
         resolve_regions(
           rest,
           decisions,
           [{lines, start, :keep} | merged],
           Enum.reverse(selected, edits)
         )

  defp resolve_regions(
         [{:conflict, fork, parent, {selected, start}} | rest],
         [:accepted | decisions],
         merged,
         edits
       ),
       do:
         resolve_regions(
           rest,
           decisions,
           [{fork, start, {:replace, length(parent)}} | merged],
           Enum.reverse(selected, edits)
         )

  defp resolve_regions(
         [{:conflict, _fork, parent, _selected} | rest],
         [:rejected | decisions],
         merged,
         edits
       ),
       do: resolve_regions(rest, decisions, [{parent, nil, :keep} | merged], edits)

  defp resolve_regions(_regions, _decisions, _merged, _edits), do: {:error, :invalid_decisions}

  @spec kept_parent([String.t()]) :: projected_merge()
  defp kept_parent([]), do: {{[], []}, []}
  defp kept_parent(parent), do: {{parent, []}, [{:keep, {0, 0, length(parent)}}]}

  @spec place_results([chosen_region()]) :: projected_merge()
  defp place_results(regions) do
    {_, _, lines, placements, alignment} =
      Enum.reduce(regions, {0, 0, [], [], []}, &place_region/2)

    {{Enum.reverse(lines), Enum.reverse(placements)}, Enum.reverse(alignment)}
  end

  @typep placed_regions ::
           {non_neg_integer(), non_neg_integer(), [String.t()], [placement()],
            [parent_alignment()]}
  @spec place_region(chosen_region(), placed_regions()) :: placed_regions()
  defp place_region({lines, source, choice}, {parent, result, out, placements, alignment}) do
    count = length(lines)
    placements = place(placements, source, result, count)

    {parent_count, alignment} =
      case choice do
        :keep when count > 0 ->
          {count, [{:keep, {parent, result, count}} | alignment]}

        :keep ->
          {0, alignment}

        {:replay, ancestor, consumed} ->
          {consumed, [{:replay, ancestor, parent, consumed, source, result, count} | alignment]}

        {:replace, consumed} ->
          {consumed, [{:reconcile, parent, result, consumed, count} | alignment]}
      end

    {parent + parent_count, result + count, Enum.reverse(lines, out), placements, alignment}
  end

  @spec place_edits(
          [String.t()],
          [merge_edit()],
          non_neg_integer(),
          non_neg_integer(),
          [String.t()],
          [placement()]
        ) :: choice()
  defp place_edits(lines, [], _pos, _result, out, placements),
    do: {Enum.reverse(out, lines), Enum.reverse(placements)}

  defp place_edits(
         lines,
         [{start, count, replacement, source} | edits],
         pos,
         result,
         out,
         placements
       ) do
    {unchanged, remaining} = consume_ancestor_region(lines, pos, start, start + count)
    at = result + length(unchanged)
    size = length(replacement)
    out = Enum.reverse(replacement, Enum.reverse(unchanged, out))

    place_edits(
      remaining,
      edits,
      start + count,
      at + size,
      out,
      place(placements, source, at, size)
    )
  end

  @spec place([placement()], non_neg_integer() | nil, non_neg_integer(), non_neg_integer()) ::
          [placement()]
  defp place(placements, nil, _result, _count), do: placements
  defp place(placements, _source, _result, 0), do: placements
  defp place(placements, source, result, count), do: [{source, result, count} | placements]

  # Ancestor and side coordinates advance independently over the same diff.
  @spec ops_to_edits([{atom(), [String.t()]}]) :: [merge_edit()]
  defp ops_to_edits(ops), do: ops |> prepend_ops(0, 0, []) |> Enum.reverse()

  @spec prepend_ops([{atom(), [String.t()]}], non_neg_integer(), non_neg_integer(), [merge_edit()]) ::
          [merge_edit()]
  defp prepend_ops([], _base, _side, edits), do: edits

  defp prepend_ops([{:eq, lines} | rest], base, side, edits) do
    count = length(lines)
    prepend_ops(rest, base + count, side + count, edits)
  end

  defp prepend_ops([{:del, lines}, {:ins, added} | rest], base, side, edits) do
    count = length(lines)
    prepend_ops(rest, base + count, side + length(added), [{base, count, added, side} | edits])
  end

  defp prepend_ops([{:del, lines} | rest], base, side, edits) do
    count = length(lines)
    prepend_ops(rest, base + count, side, [{base, count, [], side} | edits])
  end

  defp prepend_ops([{:ins, lines} | rest], base, side, edits) do
    prepend_ops(rest, base, side + length(lines), [{base, 0, lines, side} | edits])
  end

  # Walks both edit lists against the ancestor, producing merge hunks.
  @spec merge_edits([String.t()], [merge_edit()], [merge_edit()]) :: [merge_region()]
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
    {start, count, replacement, _side} = fe
    end_pos = start + count

    {unchanged, ancestor_remaining} =
      consume_ancestor_region(ancestor_remaining, pos, start, end_pos)

    acc = prepend_non_empty_resolved(unchanged, acc)
    acc = [{:fork, replacement, fe} | acc]
    do_merge(ancestor_remaining, end_pos, fork_rest, [], acc)
  end

  # Only parent edits remain.
  defp do_merge(ancestor_remaining, pos, [], [pe | parent_rest], acc) do
    {start, count, replacement, _side} = pe
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
         [fe | fork_rest],
         [pe | parent_rest],
         acc
       ) do
    merge_overlapping_edits(ancestor_remaining, pos, {fe, fork_rest}, {pe, parent_rest}, acc)
  end

  # Both sides made the same change (identical replacement for the same region).
  # Must be checked before the "before" conditions because identical insertions
  # at the same position would otherwise be duplicated.
  defp merge_overlapping_edits(
         ancestor_remaining,
         pos,
         {{start, count, replacement, fork_start}, fork_rest},
         {{start, count, replacement, _parent_start}, parent_rest},
         acc
       ) do
    end_pos = start + count

    {unchanged, ancestor_remaining} =
      consume_ancestor_region(ancestor_remaining, pos, start, end_pos)

    acc = prepend_non_empty_resolved(unchanged, acc)
    acc = [{:shared, replacement, {start, count, replacement, fork_start}} | acc]
    do_merge(ancestor_remaining, end_pos, fork_rest, parent_rest, acc)
  end

  # Fork edit is entirely before parent edit (no overlap).
  defp merge_overlapping_edits(
         ancestor_remaining,
         pos,
         {{f_start, f_count, f_replacement, _side} = fork_edit, fork_rest},
         {{p_start, p_count, _p_replacement, _side2} = parent_edit, parent_rest},
         acc
       )
       when f_start + f_count <= p_start and
              not (f_start == p_start and f_count == 0 and p_count == 0) do
    f_end = f_start + f_count

    {unchanged, ancestor_remaining} =
      consume_ancestor_region(ancestor_remaining, pos, f_start, f_end)

    acc = prepend_non_empty_resolved(unchanged, acc)
    acc = [{:fork, f_replacement, fork_edit} | acc]

    do_merge(
      ancestor_remaining,
      f_end,
      fork_rest,
      [parent_edit | parent_rest],
      acc
    )
  end

  # Parent edit is entirely before fork edit (no overlap).
  defp merge_overlapping_edits(
         ancestor_remaining,
         pos,
         {{f_start, f_count, _f_replacement, _side} = fork_edit, fork_rest},
         {{p_start, p_count, p_replacement, _side2}, parent_rest},
         acc
       )
       when p_start + p_count <= f_start and
              not (f_start == p_start and f_count == 0 and p_count == 0) do
    p_end = p_start + p_count

    {unchanged, ancestor_remaining} =
      consume_ancestor_region(ancestor_remaining, pos, p_start, p_end)

    acc = prepend_non_empty_resolved(unchanged, acc)
    acc = [{:resolved, p_replacement} | acc]

    do_merge(
      ancestor_remaining,
      p_end,
      [fork_edit | fork_rest],
      parent_rest,
      acc
    )
  end

  # Overlap: conflict.
  defp merge_overlapping_edits(
         ancestor_remaining,
         pos,
         {{f_start, f_count, _f_replacement, f_side} = fork_edit, fork_rest},
         {{p_start, p_count, _p_replacement, _p_side} = parent_edit, parent_rest},
         acc
       ) do
    conflict_start = min(f_start, p_start)
    conflict_end = max(f_start + f_count, p_start + p_count)

    {conflict_end, fork_edits, fork_rest, parent_edits, parent_rest} =
      extend_conflict(
        conflict_end,
        [fork_edit],
        fork_rest,
        [parent_edit],
        parent_rest
      )

    {unchanged, at_conflict} = Enum.split(ancestor_remaining, conflict_start - pos)
    {region, remaining} = Enum.split(at_conflict, conflict_end - conflict_start)
    fork_edits = Enum.reverse(fork_edits)
    fork = apply_region_edits(region, conflict_start, fork_edits, [])
    parent = apply_region_edits(region, conflict_start, Enum.reverse(parent_edits), [])
    acc = prepend_non_empty_resolved(unchanged, acc)

    do_merge(remaining, conflict_end, fork_rest, parent_rest, [
      {:conflict, fork, parent, {fork_edits, f_side - (f_start - conflict_start)}} | acc
    ])
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

  @spec extend_conflict(non_neg_integer(), [merge_edit()], [merge_edit()], [merge_edit()], [
          merge_edit()
        ]) ::
          {non_neg_integer(), [merge_edit()], [merge_edit()], [merge_edit()], [merge_edit()]}
  defp extend_conflict(
         end_pos,
         fork_edits,
         [{start, count, _, _side} = edit | rest],
         parent_edits,
         parent_rest
       )
       when start < end_pos do
    extend_conflict(
      max(end_pos, start + count),
      [edit | fork_edits],
      rest,
      parent_edits,
      parent_rest
    )
  end

  defp extend_conflict(end_pos, fork_edits, fork_rest, parent_edits, [
         {start, count, _, _side} = edit | rest
       ])
       when start < end_pos do
    extend_conflict(
      max(end_pos, start + count),
      fork_edits,
      fork_rest,
      [edit | parent_edits],
      rest
    )
  end

  defp extend_conflict(end_pos, fork_edits, fork_rest, parent_edits, parent_rest),
    do: {end_pos, fork_edits, fork_rest, parent_edits, parent_rest}

  @spec apply_region_edits([String.t()], non_neg_integer(), [merge_edit()], [String.t()]) :: [
          String.t()
        ]
  defp apply_region_edits(lines, _pos, [], acc), do: Enum.reverse(acc, lines)

  defp apply_region_edits(lines, pos, [{start, count, replacement, _side} | edits], acc) do
    {unchanged, remaining} = consume_ancestor_region(lines, pos, start, start + count)
    acc = Enum.reverse(replacement, Enum.reverse(unchanged, acc))
    apply_region_edits(remaining, start + count, edits, acc)
  end
end
