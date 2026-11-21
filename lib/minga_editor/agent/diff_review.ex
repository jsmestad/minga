defmodule MingaEditor.Agent.DiffReview do
  @moduledoc """
  Pure data structure for reviewing agent file edits.

  Wraps the hunks produced by `Git.Diff.diff_lines/2` with navigation
  state and per-hunk resolution tracking. The file viewer renders in
  "diff mode" when a `DiffReview` is present, and the user can accept
  or reject individual hunks without leaving the agentic view.
  """

  alias Minga.Core.Diff
  alias __MODULE__.DisplayLine
  alias Minga.Git

  @default_context_lines 3

  @typedoc "Resolution status for a single hunk."
  @type resolution :: :accepted | :rejected

  @typedoc "Diff review state."
  @type t :: %__MODULE__{
          path: String.t(),
          after_lines: [String.t()],
          hunks: [Diff.hunk()],
          current_hunk_index: non_neg_integer(),
          resolutions: %{non_neg_integer() => resolution()},
          fork_revision: Minga.Buffer.Fork.review_revision() | nil
        }

  @enforce_keys [:path, :after_lines, :hunks]
  defstruct [
    :path,
    :after_lines,
    hunks: [],
    current_hunk_index: 0,
    resolutions: %{},
    fork_revision: nil
  ]

  @doc """
  Creates a new DiffReview from a file path and before/after content strings.

  Splits content into lines, computes hunks via `Git.Diff.diff_lines/2`,
  and initializes with no resolutions and the cursor on the first hunk.
  Returns `nil` if there are no hunks (no changes detected).
  """
  @spec new(String.t(), String.t(), String.t()) :: t() | nil
  def new(path, before_content, after_content)
      when is_binary(path) and is_binary(before_content) and is_binary(after_content) do
    before_lines = String.split(before_content, "\n")
    after_lines = String.split(after_content, "\n")
    hunks = before_lines |> Git.diff_lines(after_lines) |> detach_hunk_old_lines()

    build(path, after_lines, hunks)
  end

  @doc "Creates a DiffReview from authoritative precomputed cumulative hunks."
  @spec from_hunks(String.t(), String.t(), [Diff.hunk()]) :: t() | nil
  def from_hunks(path, after_content, hunks)
      when is_binary(path) and is_binary(after_content) and is_list(hunks) do
    build(path, String.split(after_content, "\n"), hunks)
  end

  @doc "Builds a review with exactly one decision per authoritative merge conflict."
  @spec from_merge_conflicts(String.t(), [Diff.merge_hunk()]) :: t() | nil
  def from_merge_conflicts(path, merge_hunks) when is_binary(path) and is_list(merge_hunks) do
    {lines, hunks, _current, _base} =
      Enum.reduce(merge_hunks, {[], [], 0, 0}, &merge_review_hunk/2)

    build(path, Enum.reverse(lines), Enum.reverse(hunks))
  end

  @doc "Builds a fork review bound to the exact source revisions."
  @spec from_fork_snapshot(String.t(), Minga.Buffer.Fork.review_revision(), [Diff.merge_region()]) ::
          t() | nil
  def from_fork_snapshot(path, revision, regions) do
    hunks =
      Enum.map(regions, fn
        {:fork, lines, _edit} -> {:resolved, lines}
        {:conflict, fork, parent, _edits} -> {:conflict, fork, parent}
        {:resolved, _lines} = region -> region
      end)

    case from_merge_conflicts(path, hunks) do
      nil -> nil
      review -> %{review | fork_revision: revision}
    end
  end

  @doc "Returns ordered decisions only when every conflict is resolved."
  @spec fork_decisions(t()) :: {:ok, [resolution()]} | :pending
  def fork_decisions(%__MODULE__{hunks: hunks, resolutions: resolutions}) do
    if map_size(resolutions) == length(hunks) do
      {:ok, Enum.map(0..(length(hunks) - 1)//1, &Map.fetch!(resolutions, &1))}
    else
      :pending
    end
  end

  @spec merge_review_hunk(
          Diff.merge_hunk(),
          {[String.t()], [Diff.hunk()], non_neg_integer(), non_neg_integer()}
        ) ::
          {[String.t()], [Diff.hunk()], non_neg_integer(), non_neg_integer()}
  defp merge_review_hunk({:resolved, lines}, {after_lines, hunks, current, base}) do
    count = length(lines)
    {Enum.reverse(lines, after_lines), hunks, current + count, base + count}
  end

  defp merge_review_hunk({:conflict, lines, lines}, acc),
    do: merge_review_hunk({:resolved, lines}, acc)

  defp merge_review_hunk({:conflict, fork, parent}, {after_lines, hunks, current, base}) do
    count = length(fork)
    old_count = length(parent)

    hunk = %{
      type: merge_hunk_type(count, old_count),
      start_line: current,
      count: count,
      old_start: base,
      old_count: old_count,
      old_lines: parent
    }

    {Enum.reverse(fork, after_lines), [hunk | hunks], current + count, base + old_count}
  end

  @spec merge_hunk_type(non_neg_integer(), non_neg_integer()) :: Diff.hunk_type()
  defp merge_hunk_type(0, _old_count), do: :deleted
  defp merge_hunk_type(_count, 0), do: :added
  defp merge_hunk_type(_count, _old_count), do: :modified

  @doc """
  Updates the diff review with new after-content and authoritative cumulative hunks while preserving resolutions for hunks that have not changed.
  """
  @spec update_after(t(), String.t(), [Diff.hunk()]) :: t() | nil
  def update_after(%__MODULE__{} = review, new_after_content, new_hunks)
      when is_binary(new_after_content) and is_list(new_hunks) do
    update_after_lines(review, String.split(new_after_content, "\n"), new_hunks)
  end

  @doc "Updates the diff review from already split after-lines and authoritative cumulative hunks."
  @spec update_after_lines(t(), [String.t()], [Diff.hunk()]) :: t() | nil
  def update_after_lines(%__MODULE__{path: path} = review, new_after_lines, new_hunks)
      when is_list(new_after_lines) and is_list(new_hunks) do
    case new_hunks do
      [] -> nil
      _ -> build_updated_review(review, path, new_after_lines, new_hunks)
    end
  end

  @doc "Reconstructs the original pre-agent lines by reverting every review hunk."
  @spec original_lines(t()) :: [String.t()]
  def original_lines(%__MODULE__{after_lines: after_lines, hunks: hunks}) do
    revert_hunks(after_lines, hunks)
  end

  @doc "Returns the materialized post-resolution lines, reverting only rejected hunks."
  @spec materialized_lines(t()) :: [String.t()]
  def materialized_lines(%__MODULE__{
        after_lines: after_lines,
        hunks: hunks,
        resolutions: resolutions
      }) do
    revert_hunks(after_lines, rejected_hunks(hunks, resolutions, 0))
  end

  @doc "Moves to the next unresolved hunk. Wraps around to the first."
  @spec next_hunk(t()) :: t()
  def next_hunk(%__MODULE__{hunks: hunks} = review), do: move_hunk(review, length(hunks), 1)

  @doc "Moves to the previous unresolved hunk. Wraps around to the last."
  @spec prev_hunk(t()) :: t()
  def prev_hunk(%__MODULE__{hunks: hunks} = review), do: move_hunk(review, length(hunks), -1)

  @doc "Marks the current hunk as accepted and advances to the next unresolved."
  @spec accept_current(t()) :: t()
  def accept_current(%__MODULE__{current_hunk_index: idx} = review) do
    review
    |> put_resolution(idx, :accepted)
    |> advance_after_resolve()
  end

  @doc "Marks the current hunk as rejected and advances to the next unresolved."
  @spec reject_current(t()) :: t()
  def reject_current(%__MODULE__{current_hunk_index: idx} = review) do
    review
    |> put_resolution(idx, :rejected)
    |> advance_after_resolve()
  end

  @doc "Accepts all unresolved hunks."
  @spec accept_all(t()) :: t()
  def accept_all(%__MODULE__{hunks: hunks} = review) do
    resolutions =
      hunks
      |> Enum.with_index()
      |> Enum.reduce(review.resolutions, fn {_hunk, idx}, acc ->
        Map.put_new(acc, idx, :accepted)
      end)

    %{review | resolutions: resolutions}
  end

  @doc "Rejects all unresolved hunks."
  @spec reject_all(t()) :: t()
  def reject_all(%__MODULE__{hunks: hunks} = review) do
    resolutions =
      hunks
      |> Enum.with_index()
      |> Enum.reduce(review.resolutions, fn {_hunk, idx}, acc ->
        Map.put_new(acc, idx, :rejected)
      end)

    %{review | resolutions: resolutions}
  end

  @doc "Returns true when every hunk has been accepted or rejected."
  @spec resolved?(t()) :: boolean()
  def resolved?(%__MODULE__{hunks: [], resolutions: _}), do: false

  def resolved?(%__MODULE__{hunks: hunks, resolutions: resolutions}) do
    hunk_count = Enum.count(hunks)
    map_size(resolutions) == hunk_count
  end

  @doc """
  Returns `{added_count, removed_count}` summarizing the diff.

  Counts lines added and removed across all hunks.
  """
  @spec summary(t()) :: {non_neg_integer(), non_neg_integer()}
  def summary(%__MODULE__{hunks: hunks}) do
    Enum.reduce(hunks, {0, 0}, fn hunk, {added, removed} ->
      case hunk.type do
        :added -> {added + hunk.count, removed}
        :deleted -> {added, removed + hunk.old_count}
        :modified -> {added + hunk.count, removed + hunk.old_count}
      end
    end)
  end

  @doc "Returns the resolution for a given hunk index, or nil if unresolved."
  @spec resolution_at(t(), non_neg_integer()) :: resolution() | nil
  def resolution_at(%__MODULE__{resolutions: resolutions}, index) do
    Map.get(resolutions, index)
  end

  @doc "Returns the current hunk, or nil if no hunks exist."
  @spec current_hunk(t()) :: Diff.hunk() | nil
  def current_hunk(%__MODULE__{hunks: [], current_hunk_index: _}), do: nil

  def current_hunk(%__MODULE__{hunks: hunks, current_hunk_index: idx}) do
    Enum.at(hunks, idx)
  end

  @doc """
  Returns the start line of the current hunk in the after-content,
  suitable for scrolling the viewer to show it.
  """
  @spec current_hunk_line(t()) :: non_neg_integer()
  def current_hunk_line(%__MODULE__{} = review) do
    case current_hunk(review) do
      nil -> 0
      hunk -> hunk.start_line
    end
  end

  @doc """
  Builds the list of lines to display in unified diff format.

  Returns typed display lines with source coordinates and hunk references. Baseline coordinates remain stable when agent edits move after-content; hunk references can be matched across revisions with `matching_hunks/2` before allocating render identities.
  """
  @type diff_line :: DisplayLine.t()

  @spec to_display_lines(t()) :: [diff_line()]
  @spec to_display_lines(t(), non_neg_integer()) :: [diff_line()]
  def to_display_lines(%__MODULE__{} = review, context_lines \\ @default_context_lines)
      when is_integer(context_lines) and context_lines >= 0 do
    %__MODULE__{after_lines: after_lines, hunks: hunks} = review
    build_display(after_lines, hunks, context_lines)
  end

  @doc "Matches unchanged hunks by baseline location and content, preserving duplicate occurrence order."
  @spec matching_hunks(t(), t()) :: %{non_neg_integer() => non_neg_integer()}
  def matching_hunks(%__MODULE__{path: path} = previous, %__MODULE__{path: path} = current) do
    available =
      previous.hunks
      |> hunk_signatures(previous.after_lines)
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {signature, index}, queues ->
        Map.update(queues, signature, [index], &[index | &1])
      end)
      |> Map.new(fn {signature, indices} -> {signature, Enum.reverse(indices)} end)

    {matches, _available} =
      current.hunks
      |> hunk_signatures(current.after_lines)
      |> Enum.with_index()
      |> Enum.reduce({%{}, available}, fn {signature, current_index}, {matches, queues} ->
        case Map.get(queues, signature, []) do
          [previous_index | remaining] ->
            {Map.put(matches, current_index, previous_index),
             Map.put(queues, signature, remaining)}

          [] ->
            {matches, queues}
        end
      end)

    matches
  end

  def matching_hunks(%__MODULE__{}, %__MODULE__{}), do: %{}

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec build(String.t(), [String.t()], [Diff.hunk()]) :: t() | nil
  defp build(_path, _after_lines, []), do: nil

  defp build(path, after_lines, hunks) do
    %__MODULE__{
      path: path,
      after_lines: after_lines,
      hunks: hunks
    }
  end

  @spec revert_hunks([String.t()], [Diff.hunk()]) :: [String.t()]
  defp revert_hunks(lines, hunks) do
    case splice_hunks(lines, hunks, 0, []) do
      :unspliceable ->
        # Supplied coordinates can depend on the result of reverting later hunks.
        hunks
        |> Enum.reverse()
        |> Enum.reduce(lines, &Git.revert_hunk(&2, &1))

      restored ->
        restored
    end
  end

  @spec rejected_hunks([Diff.hunk()], %{non_neg_integer() => resolution()}, non_neg_integer()) ::
          [Diff.hunk()]
  defp rejected_hunks([], _resolutions, _index), do: []

  defp rejected_hunks([hunk | rest], resolutions, index) do
    if Map.get(resolutions, index) == :rejected do
      [hunk | rejected_hunks(rest, resolutions, index + 1)]
    else
      rejected_hunks(rest, resolutions, index + 1)
    end
  end

  @spec splice_hunks([String.t()], [Diff.hunk()], non_neg_integer(), [String.t()]) ::
          [String.t()] | :unspliceable
  defp splice_hunks(lines, [], _offset, acc), do: Enum.reverse(acc, lines)

  defp splice_hunks(lines, [%{start_line: offset} = hunk | rest], offset, acc) do
    {count, replacement} = revert_span(hunk)

    case skip_splice_span(lines, count) do
      :unspliceable -> :unspliceable
      tail -> splice_hunks(tail, rest, offset + count, Enum.reverse(replacement, acc))
    end
  end

  defp splice_hunks([line | tail], [%{start_line: start} | _] = hunks, offset, acc)
       when start > offset do
    splice_hunks(tail, hunks, offset + 1, [line | acc])
  end

  defp splice_hunks(_lines, _hunks, _offset, _acc), do: :unspliceable

  @spec revert_span(Diff.hunk()) :: {non_neg_integer(), [String.t()]}
  defp revert_span(%{type: :added, count: count}), do: {count, []}
  defp revert_span(%{type: :modified, count: count, old_lines: old_lines}), do: {count, old_lines}
  defp revert_span(%{type: :deleted, old_lines: old_lines}), do: {0, old_lines}

  @spec skip_splice_span([String.t()], non_neg_integer()) :: [String.t()] | :unspliceable
  defp skip_splice_span(lines, 0), do: lines

  defp skip_splice_span([_line | tail], count) when count > 0,
    do: skip_splice_span(tail, count - 1)

  defp skip_splice_span(_lines, _count), do: :unspliceable

  @spec detach_hunk_old_lines([Diff.hunk()]) :: [Diff.hunk()]
  defp detach_hunk_old_lines(hunks) do
    Enum.map(hunks, fn hunk ->
      %{hunk | old_lines: Enum.map(hunk.old_lines, &detach_binary/1)}
    end)
  end

  @spec detach_binary(String.t()) :: String.t()
  defp detach_binary(line) do
    if byte_size(line) < :binary.referenced_byte_size(line), do: :binary.copy(line), else: line
  end

  @spec build_updated_review(
          t(),
          String.t(),
          [String.t()],
          [Diff.hunk()]
        ) :: t()
  defp build_updated_review(review, path, new_after_lines, new_hunks) do
    old_hunk_sigs = hunk_signatures(review.hunks, review.after_lines)
    new_hunk_sigs = hunk_signatures(new_hunks, new_after_lines)

    new_resolutions =
      preserve_matching_resolutions(old_hunk_sigs, new_hunk_sigs, review.resolutions)

    current_idx =
      reproject_current_hunk_index(old_hunk_sigs, new_hunk_sigs, review.current_hunk_index)

    %__MODULE__{
      path: path,
      after_lines: new_after_lines,
      hunks: new_hunks,
      current_hunk_index: current_idx,
      resolutions: new_resolutions
    }
  end

  @typep hunk_signature :: {atom(), non_neg_integer(), [String.t()], [String.t()]}
  @typep resolution_queues :: %{hunk_signature() => [resolution()]}

  @spec preserve_matching_resolutions(
          [hunk_signature()],
          [hunk_signature()],
          %{non_neg_integer() => resolution()}
        ) :: %{non_neg_integer() => resolution()}
  defp preserve_matching_resolutions(old_sigs, new_sigs, old_resolutions) do
    queues = resolved_signature_queues(old_sigs, old_resolutions)

    {resolutions, _queues} =
      new_sigs
      |> Enum.with_index()
      |> Enum.reduce({%{}, queues}, fn {sig, new_idx}, {acc, available} ->
        case pop_resolution(available, sig) do
          {{:ok, resolution}, updated_available} ->
            {Map.put(acc, new_idx, resolution), updated_available}

          {:error, updated_available} ->
            {acc, updated_available}
        end
      end)

    resolutions
  end

  @spec reproject_current_hunk_index(
          [hunk_signature()],
          [hunk_signature()],
          non_neg_integer()
        ) :: non_neg_integer()
  defp reproject_current_hunk_index(_old_sigs, [], _current_idx), do: 0

  defp reproject_current_hunk_index(old_sigs, new_sigs, current_idx) do
    max_idx = Enum.count(new_sigs) - 1

    case Enum.at(old_sigs, current_idx) do
      nil ->
        min(current_idx, max_idx)

      signature ->
        occurrence =
          old_sigs
          |> Enum.take(current_idx + 1)
          |> Enum.count(&(&1 == signature))

        find_signature_occurrence(new_sigs, signature, occurrence) || min(current_idx, max_idx)
    end
  end

  @spec find_signature_occurrence([hunk_signature()], hunk_signature(), pos_integer()) ::
          non_neg_integer() | nil
  defp find_signature_occurrence(sigs, signature, occurrence) do
    sigs
    |> Enum.with_index()
    |> Enum.reduce_while(0, fn {candidate, idx}, seen ->
      if candidate == signature do
        find_signature_occurrence_step(idx, seen + 1, occurrence)
      else
        {:cont, seen}
      end
    end)
    |> case do
      {:found, idx} -> idx
      _seen -> nil
    end
  end

  defp find_signature_occurrence_step(idx, occurrence, occurrence), do: {:halt, {:found, idx}}
  defp find_signature_occurrence_step(_idx, seen, _occurrence), do: {:cont, seen}

  @spec resolved_signature_queues([hunk_signature()], %{non_neg_integer() => resolution()}) ::
          resolution_queues()
  defp resolved_signature_queues(old_sigs, old_resolutions) do
    old_sigs
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {sig, idx}, acc ->
      case Map.fetch(old_resolutions, idx) do
        {:ok, resolution} ->
          Map.update(acc, sig, [resolution], fn queue -> [resolution | queue] end)

        :error ->
          acc
      end
    end)
    |> Map.new(fn {sig, queue} -> {sig, Enum.reverse(queue)} end)
  end

  @spec pop_resolution(resolution_queues(), hunk_signature()) ::
          {{:ok, resolution()}, resolution_queues()} | {:error, resolution_queues()}
  defp pop_resolution(queues, sig) do
    case Map.get(queues, sig, []) do
      [resolution | rest] -> {{:ok, resolution}, Map.put(queues, sig, rest)}
      [] -> {:error, queues}
    end
  end

  # A hunk signature captures the changed content and baseline location for matching across re-diffs.
  # After-content line numbers are intentionally excluded so resolved hunks survive edits above them.
  @spec hunk_signatures([Diff.hunk()], [String.t()]) :: [hunk_signature()]
  defp hunk_signatures(hunks, after_lines) do
    {signatures, _cursor} =
      Enum.map_reduce(hunks, {after_lines, 0}, fn hunk, cursor ->
        {changed, cursor} = signature_after_lines(hunk, cursor, after_lines)
        {{hunk.type, hunk.old_start, hunk.old_lines, changed}, cursor}
      end)

    signatures
  end

  @spec signature_after_lines(
          Diff.hunk(),
          {[String.t()], non_neg_integer()},
          [String.t()]
        ) :: {[String.t()], {[String.t()], non_neg_integer()}}
  defp signature_after_lines(%{type: :deleted}, cursor, _after_lines), do: {[], cursor}

  defp signature_after_lines(%{start_line: start, count: count}, cursor, after_lines)
       when start < 0 or count < 0 do
    {Enum.slice(after_lines, start, count), cursor}
  end

  defp signature_after_lines(%{start_line: start, count: count}, {tail, offset}, after_lines) do
    start_tail =
      if start >= offset do
        Enum.drop(tail, start - offset)
      else
        Enum.drop(after_lines, start)
      end

    {changed, tail} = Enum.split(start_tail, count)
    {changed, {tail, start + count}}
  end

  @spec put_resolution(t(), non_neg_integer(), resolution()) :: t()
  defp put_resolution(%__MODULE__{resolutions: resolutions} = review, index, status) do
    %{review | resolutions: Map.put(resolutions, index, status)}
  end

  @spec advance_after_resolve(t()) :: t()
  defp advance_after_resolve(%__MODULE__{hunks: hunks, resolutions: resolutions} = review) do
    count = length(hunks)

    if map_size(resolutions) == count do
      review
    else
      move_hunk(review, count, 1)
    end
  end

  @spec move_hunk(t(), non_neg_integer(), -1 | 1) :: t()
  defp move_hunk(review, 0, _step), do: review

  defp move_hunk(review, count, step) do
    %{current_hunk_index: index, resolutions: resolutions} = review
    neighbor = Integer.mod(index + step, count)

    next =
      Enum.find_value(0..(count - 1), neighbor, fn offset ->
        candidate = Integer.mod(neighbor + step * offset, count)
        unless Map.has_key?(resolutions, candidate), do: candidate
      end)

    %{review | current_hunk_index: next}
  end

  @spec build_display([String.t()], [Diff.hunk()], non_neg_integer()) :: [
          diff_line()
        ]
  defp build_display(_after, [], _ctx), do: []

  defp build_display(after_lines, hunks, ctx) do
    hunks
    |> do_build_display({after_lines, 0}, {after_lines, length(after_lines)}, ctx, 0, [])
    |> Enum.reverse()
  end

  @spec do_build_display(
          [Diff.hunk()],
          {[String.t()], non_neg_integer()},
          {[String.t()], non_neg_integer()},
          non_neg_integer(),
          non_neg_integer(),
          [diff_line()]
        ) :: [diff_line()]
  defp do_build_display([], _cursor, _source, _ctx, _idx, acc), do: acc

  defp do_build_display(
         [hunk | rest],
         {tail, offset},
         {lines, file_length} = source,
         ctx,
         idx,
         acc
       ) do
    {added, removed} = hunk_counts(hunk)

    header =
      DisplayLine.new(
        {:hunk_header, idx},
        "@@ -#{hunk.old_start + 1},#{hunk.old_count} +#{hunk.start_line + 1},#{hunk.count} @@ (+#{added}, -#{removed})",
        :hunk_header,
        idx
      )

    before_start = max(offset, max(0, hunk.start_line - ctx))
    before_count = hunk.start_line - before_start
    tail = Enum.drop(tail, before_start - offset)
    before_baseline = hunk.old_start - before_count
    {tail, acc} = prepend_context(tail, before_count, before_baseline, [header | acc])
    {tail, acc} = prepend_changed(tail, hunk, idx, acc)

    after_start = hunk.start_line + hunk.count

    after_end =
      (after_start + ctx)
      |> min(file_length)
      |> cap_context_before_next_hunk(List.first(rest))

    {tail, offset, acc} = prepend_trailing_context(tail, hunk, after_start, after_end, lines, acc)
    do_build_display(rest, {tail, offset}, source, ctx, idx + 1, acc)
  end

  @spec prepend_trailing_context(
          [String.t()],
          Diff.hunk(),
          integer(),
          integer(),
          [String.t()],
          [diff_line()]
        ) :: {[String.t()], non_neg_integer(), [diff_line()]}
  defp prepend_trailing_context(_tail, %{count: count} = hunk, start, stop, lines, acc)
       when count < 0 do
    # A signed deletion can move the context backward or address it from EOF.
    amount = stop - start
    context = Enum.slice(lines, start, amount)
    {_rest, acc} = prepend_context(context, amount, hunk.old_start + hunk.old_count, acc)
    offset = max(stop, 0)
    {Enum.drop(lines, offset), offset, acc}
  end

  defp prepend_trailing_context(tail, hunk, start, stop, _lines, acc) when stop >= 0 do
    {tail, acc} = prepend_context(tail, stop - start, hunk.old_start + hunk.old_count, acc)
    {tail, stop, acc}
  end

  @spec cap_context_before_next_hunk(integer(), Diff.hunk() | nil) :: integer()
  defp cap_context_before_next_hunk(after_end, nil), do: after_end

  defp cap_context_before_next_hunk(after_end, next_hunk),
    do: min(after_end, next_hunk.start_line)

  # A negative span still raises for a changed interval crossing the next hunk or EOF.
  @spec prepend_context([String.t()], integer(), integer(), [diff_line()]) ::
          {[String.t()], [diff_line()]}
  defp prepend_context(lines, 0, _baseline, acc), do: {lines, acc}
  defp prepend_context([], count, _baseline, acc) when count > 0, do: {[], acc}

  defp prepend_context([line | tail], count, baseline, acc) when count > 0 do
    row = DisplayLine.new({:baseline, baseline}, line, :context)
    prepend_context(tail, count - 1, baseline + 1, [row | acc])
  end

  @spec prepend_changed([String.t()], Diff.hunk(), non_neg_integer(), [diff_line()]) ::
          {[String.t()], [diff_line()]}
  defp prepend_changed(lines, %{type: :added, count: count}, idx, acc) do
    prepend_added(lines, count, idx, 0, acc)
  end

  defp prepend_changed(lines, %{type: :deleted} = hunk, idx, acc) do
    {Enum.drop(lines, max(hunk.count, 0)),
     prepend_removed(hunk.old_lines, hunk.old_start, idx, acc)}
  end

  defp prepend_changed(lines, %{type: :modified} = hunk, idx, acc) do
    acc = prepend_removed(hunk.old_lines, hunk.old_start, idx, acc)
    prepend_added(lines, hunk.count, idx, 0, acc)
  end

  @spec prepend_removed([String.t()], non_neg_integer(), non_neg_integer(), [diff_line()]) ::
          [diff_line()]
  defp prepend_removed([], _baseline, _idx, acc), do: acc

  defp prepend_removed([line | tail], baseline, idx, acc) do
    row = DisplayLine.new({:baseline, baseline}, line, :removed, idx)
    prepend_removed(tail, baseline + 1, idx, [row | acc])
  end

  @spec prepend_added(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [diff_line()]
        ) :: {[String.t()], [diff_line()]}
  defp prepend_added(lines, 0, _idx, _offset, acc), do: {lines, acc}
  defp prepend_added([], count, _idx, _offset, acc) when count > 0, do: {[], acc}

  defp prepend_added([line | tail], count, idx, offset, acc) when count > 0 do
    row = DisplayLine.new({:added, idx, offset}, line, :added, idx)
    prepend_added(tail, count - 1, idx, offset + 1, [row | acc])
  end

  @spec hunk_counts(Diff.hunk()) :: {non_neg_integer(), non_neg_integer()}
  defp hunk_counts(%{type: :added, count: count}), do: {count, 0}
  defp hunk_counts(%{type: :deleted, old_count: count}), do: {0, count}
  defp hunk_counts(%{type: :modified, count: added, old_count: removed}), do: {added, removed}
end
