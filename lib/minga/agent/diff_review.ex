defmodule Minga.Agent.DiffReview do
  @moduledoc """
  Pure data structure for reviewing agent file edits.

  Wraps the hunks produced by `Git.Diff.diff_lines/2` with navigation
  state and per-hunk resolution tracking. The file viewer renders in
  "diff mode" when a `DiffReview` is present, and the user can accept
  or reject individual hunks without leaving the agentic view.
  """

  alias Minga.Git.Diff

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
    hunks = Diff.diff_lines(before_lines, after_lines)

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
  def to_display_lines(%__MODULE__{before_lines: before, after_lines: after_lines, hunks: hunks}) do
    context_lines = 3
    build_display(before, after_lines, hunks, 0, context_lines)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

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

  # Build unified diff display lines with context around each hunk
  @spec build_display(
          [String.t()],
          [String.t()],
          [Diff.hunk()],
          non_neg_integer(),
          non_neg_integer()
        ) :: [diff_line()]
  defp build_display(_before, _after, [], _hunk_idx, _ctx), do: []

  defp build_display(before, after_lines, hunks, _hunk_idx, ctx) do
    # Compute ranges: for each hunk, show context before/after + the hunk itself
    hunks
    |> Enum.with_index()
    |> Enum.flat_map(fn {hunk, idx} ->
      hunk_display_lines(before, after_lines, hunk, idx, ctx)
    end)
  end

  @spec hunk_display_lines(
          [String.t()],
          [String.t()],
          Diff.hunk(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [diff_line()]
  defp hunk_display_lines(before, after_lines, hunk, hunk_idx, ctx) do
    # Context lines before the hunk (from the after-content for added/modified, from before for deleted)
    before_ctx_start = max(0, hunk.start_line - ctx)

    before_ctx_lines =
      Enum.slice(after_lines, before_ctx_start, hunk.start_line - before_ctx_start)

    before_ctx = Enum.map(before_ctx_lines, fn line -> {line, :context, nil} end)

    # The hunk itself
    hunk_lines = render_hunk_lines(before, after_lines, hunk, hunk_idx)

    # Context lines after the hunk
    after_start = hunk.start_line + hunk.count
    after_end = min(after_start + ctx, length(after_lines))
    after_ctx_lines = Enum.slice(after_lines, after_start, after_end - after_start)
    after_ctx = Enum.map(after_ctx_lines, fn line -> {line, :context, nil} end)

    # Separator header
    {added, removed} = hunk_counts(hunk)

    header =
      {"@@ -#{hunk.old_start + 1},#{hunk.old_count} +#{hunk.start_line + 1},#{hunk.count} @@ (+#{added}, -#{removed})",
       :hunk_header, hunk_idx}

    [header | before_ctx] ++ hunk_lines ++ after_ctx
  end

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
