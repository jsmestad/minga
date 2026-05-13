defmodule MingaEditor.Agent.DiffReview do
  @moduledoc """
  Pure data structure for reviewing agent file edits.

  Wraps the hunks produced by `Git.Diff.diff_lines/2` with navigation
  state and per-hunk resolution tracking. The file viewer renders in
  "diff mode" when a `DiffReview` is present, and the user can accept
  or reject individual hunks without leaving the agentic view.
  """

  alias Minga.Core.Diff
  alias Minga.Git

  @default_context_lines 3

  @typedoc "Resolution status for a single hunk."
  @type resolution :: :accepted | :rejected

  @typedoc "Diff review state."
  @type t :: %__MODULE__{
          path: String.t(),
          before_lines: [String.t()],
          after_lines: [String.t()],
          hunks: [Diff.hunk()],
          current_hunk_index: non_neg_integer(),
          resolutions: %{non_neg_integer() => resolution()}
        }

  @enforce_keys [:path, :before_lines, :after_lines, :hunks]
  defstruct [
    :path,
    :before_lines,
    :after_lines,
    hunks: [],
    current_hunk_index: 0,
    resolutions: %{}
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
    hunks = Git.diff_lines(before_lines, after_lines)

    case hunks do
      [] ->
        nil

      _ ->
        %__MODULE__{
          path: path,
          before_lines: before_lines,
          after_lines: after_lines,
          hunks: hunks
        }
    end
  end

  @doc """
  Updates the diff review with new after-content while preserving
  resolutions for hunks that have not changed.

  Used for accumulated diffs: when the agent edits the same file again,
  the baseline stays the same but the after-content changes. Hunks are
  re-computed and resolutions from the previous review are carried forward
  for hunks that still match.
  """
  @spec update_after(t(), String.t()) :: t() | nil
  def update_after(
        %__MODULE__{path: path, before_lines: before_lines} = review,
        new_after_content
      )
      when is_binary(new_after_content) do
    new_after_lines = String.split(new_after_content, "\n")
    new_hunks = Git.diff_lines(before_lines, new_after_lines)

    case new_hunks do
      [] -> nil
      _ -> build_updated_review(review, path, before_lines, new_after_lines, new_hunks)
    end
  end

  @doc "Moves to the next unresolved hunk. Wraps around to the first."
  @spec next_hunk(t()) :: t()
  def next_hunk(%__MODULE__{hunks: hunks, current_hunk_index: idx} = review) do
    count = length(hunks)

    case count do
      0 ->
        review

      _ ->
        next = find_next_unresolved(review, idx + 1, count)
        %{review | current_hunk_index: next}
    end
  end

  @doc "Moves to the previous unresolved hunk. Wraps around to the last."
  @spec prev_hunk(t()) :: t()
  def prev_hunk(%__MODULE__{hunks: hunks, current_hunk_index: idx} = review) do
    count = length(hunks)

    case count do
      0 ->
        review

      _ ->
        prev = find_prev_unresolved(review, idx - 1, count)
        %{review | current_hunk_index: prev}
    end
  end

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
    hunk_count = length(hunks)
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

  Returns a list of `{text, type, hunk_index_or_nil}` tuples where
  `type` is `:context`, `:added`, `:removed`, or `:hunk_header`.
  `hunk_index_or_nil` links display lines back to their hunk for
  resolution marker rendering.
  """
  @type diff_line ::
          {String.t(), :context | :added | :removed | :hunk_header, non_neg_integer() | nil}

  @spec to_display_lines(t()) :: [diff_line()]
  @spec to_display_lines(t(), non_neg_integer()) :: [diff_line()]
  def to_display_lines(%__MODULE__{} = review, context_lines \\ @default_context_lines)
      when is_integer(context_lines) and context_lines >= 0 do
    %__MODULE__{before_lines: before, after_lines: after_lines, hunks: hunks} = review
    build_display(before, after_lines, hunks, context_lines)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec build_updated_review(
          t(),
          String.t(),
          [String.t()],
          [String.t()],
          [Diff.hunk()]
        ) :: t()
  defp build_updated_review(review, path, before_lines, new_after_lines, new_hunks) do
    old_hunk_sigs = hunk_signatures(review.hunks, review.after_lines)
    new_hunk_sigs = hunk_signatures(new_hunks, new_after_lines)

    new_resolutions =
      preserve_matching_resolutions(old_hunk_sigs, new_hunk_sigs, review.resolutions)

    max_idx = max(length(new_hunks) - 1, 0)
    clamped_idx = min(review.current_hunk_index, max_idx)

    %__MODULE__{
      path: path,
      before_lines: before_lines,
      after_lines: new_after_lines,
      hunks: new_hunks,
      current_hunk_index: clamped_idx,
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
    Enum.map(hunks, fn hunk ->
      {hunk.type, hunk.old_start, hunk.old_lines, after_hunk_lines(hunk, after_lines)}
    end)
  end

  @spec after_hunk_lines(Diff.hunk(), [String.t()]) :: [String.t()]
  defp after_hunk_lines(%{type: :deleted}, _after_lines), do: []

  defp after_hunk_lines(hunk, after_lines) do
    Enum.slice(after_lines, hunk.start_line, hunk.count)
  end

  @spec put_resolution(t(), non_neg_integer(), resolution()) :: t()
  defp put_resolution(%__MODULE__{resolutions: resolutions} = review, index, status) do
    %{review | resolutions: Map.put(resolutions, index, status)}
  end

  @spec advance_after_resolve(t()) :: t()
  defp advance_after_resolve(%__MODULE__{} = review) do
    if resolved?(review) do
      review
    else
      next_hunk(review)
    end
  end

  @spec find_next_unresolved(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp find_next_unresolved(%__MODULE__{resolutions: resolutions}, start, count) do
    0..(count - 1)
    |> Enum.map(fn offset -> rem(start + offset, count) end)
    |> Enum.find(start, fn idx -> not Map.has_key?(resolutions, idx) end)
    |> then(fn idx -> rem(idx, count) end)
  end

  @spec find_prev_unresolved(t(), integer(), non_neg_integer()) :: non_neg_integer()
  defp find_prev_unresolved(%__MODULE__{resolutions: resolutions}, start, count) do
    normalized = rem(start + count, count)

    0..(count - 1)
    |> Enum.map(fn offset -> rem(normalized - offset + count, count) end)
    |> Enum.find(normalized, fn idx -> not Map.has_key?(resolutions, idx) end)
  end

  # Build unified diff display lines with context around each hunk.
  @spec build_display([String.t()], [String.t()], [Diff.hunk()], non_neg_integer()) :: [
          diff_line()
        ]
  defp build_display(_before, _after, [], _ctx), do: []

  defp build_display(before, after_lines, hunks, ctx) do
    before
    |> do_build_display(after_lines, hunks, ctx, 0, 0, [])
    |> Enum.reverse()
  end

  @spec do_build_display(
          [String.t()],
          [String.t()],
          [Diff.hunk()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [diff_line()]
        ) :: [diff_line()]
  defp do_build_display(_before, _after_lines, [], _ctx, _idx, _displayed_until, acc), do: acc

  defp do_build_display(before, after_lines, [hunk | rest], ctx, idx, displayed_until, acc) do
    next_hunk = List.first(rest)

    {lines, new_displayed_until} =
      hunk_display_lines(before, after_lines, hunk, idx, ctx, displayed_until, next_hunk)

    do_build_display(
      before,
      after_lines,
      rest,
      ctx,
      idx + 1,
      new_displayed_until,
      Enum.reverse(lines, acc)
    )
  end

  @spec hunk_display_lines(
          [String.t()],
          [String.t()],
          Diff.hunk(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Diff.hunk() | nil
        ) :: {[diff_line()], non_neg_integer()}
  defp hunk_display_lines(before, after_lines, hunk, hunk_idx, ctx, displayed_until, next_hunk) do
    before_ctx_start = max(max(0, hunk.start_line - ctx), displayed_until)

    before_ctx_lines =
      Enum.slice(after_lines, before_ctx_start, hunk.start_line - before_ctx_start)

    before_ctx = Enum.map(before_ctx_lines, fn line -> {line, :context, nil} end)
    hunk_lines = render_hunk_lines(before, after_lines, hunk, hunk_idx)

    after_start = hunk.start_line + hunk.count

    after_end =
      (after_start + ctx) |> min(length(after_lines)) |> cap_context_before_next_hunk(next_hunk)

    after_ctx_lines = Enum.slice(after_lines, after_start, after_end - after_start)
    after_ctx = Enum.map(after_ctx_lines, fn line -> {line, :context, nil} end)

    {added, removed} = hunk_counts(hunk)

    header =
      {"@@ -#{hunk.old_start + 1},#{hunk.old_count} +#{hunk.start_line + 1},#{hunk.count} @@ (+#{added}, -#{removed})",
       :hunk_header, hunk_idx}

    {[header | before_ctx] ++ hunk_lines ++ after_ctx, after_end}
  end

  @spec cap_context_before_next_hunk(non_neg_integer(), Diff.hunk() | nil) :: non_neg_integer()
  defp cap_context_before_next_hunk(after_end, nil), do: after_end

  defp cap_context_before_next_hunk(after_end, next_hunk),
    do: min(after_end, next_hunk.start_line)

  @spec render_hunk_lines([String.t()], [String.t()], Diff.hunk(), non_neg_integer()) :: [
          diff_line()
        ]
  defp render_hunk_lines(_before, after_lines, %{type: :added} = hunk, hunk_idx) do
    after_lines
    |> Enum.slice(hunk.start_line, hunk.count)
    |> Enum.map(fn line -> {line, :added, hunk_idx} end)
  end

  defp render_hunk_lines(_before, _after, %{type: :deleted} = hunk, hunk_idx) do
    hunk.old_lines
    |> Enum.map(fn line -> {line, :removed, hunk_idx} end)
  end

  defp render_hunk_lines(_before, after_lines, %{type: :modified} = hunk, hunk_idx) do
    removed = Enum.map(hunk.old_lines, fn line -> {line, :removed, hunk_idx} end)

    added =
      after_lines
      |> Enum.slice(hunk.start_line, hunk.count)
      |> Enum.map(fn line -> {line, :added, hunk_idx} end)

    removed ++ added
  end

  @spec hunk_counts(Diff.hunk()) :: {non_neg_integer(), non_neg_integer()}
  defp hunk_counts(%{type: :added, count: count}), do: {count, 0}
  defp hunk_counts(%{type: :deleted, old_count: count}), do: {0, count}
  defp hunk_counts(%{type: :modified, count: added, old_count: removed}), do: {added, removed}
end
