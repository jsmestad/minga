defmodule Minga.Editor.FoldMap do
  @moduledoc """
  Tracks which buffer ranges are currently folded (collapsed) in a window.

  Pure data structure, no GenServer. Owned by each `Window`, so different
  windows viewing the same buffer can have independent fold states (like
  Neovim's per-window folds).

  Internally stores a sorted list of non-overlapping `FoldRange` structs.
  Lookups are linear scans over the sorted list. When the list is empty,
  all translation functions are O(1) via guard clauses (zero overhead
  for buffers without folds). This is adequate for typical fold counts
  (tens, not thousands). The planned `DisplayMap` (#522) will replace
  this module with an interval-tree-backed unified coordinate mapping.

  ## Coordinate translation

  The fold map translates between two coordinate systems:

  - **Buffer lines**: the actual line numbers in the document (0-indexed).
  - **Visible lines**: the line numbers as displayed on screen, with folded
    regions collapsed to a single summary line.

  A folded range `{start_line, end_line}` contributes exactly one visible
  line (the start/summary line). The `end_line - start_line` hidden lines
  are skipped.

  ## Design

  Mirrors `WrapMap` in philosophy: a rendering concern, not a buffer
  concern. Pure functions, stateless computation, per-window ownership.
  """

  alias Minga.Editor.FoldRange

  @enforce_keys [:folds]
  defstruct folds: []

  @typedoc """
  The fold map: a sorted list of non-overlapping, currently-folded ranges.
  """
  @type t :: %__MODULE__{
          folds: [FoldRange.t()]
        }

  @doc "Creates an empty fold map."
  @spec new() :: t()
  def new, do: %__MODULE__{folds: []}

  @doc "Creates a fold map from a list of fold ranges. Removes overlaps by keeping earlier ranges."
  @spec from_ranges([FoldRange.t()]) :: t()
  def from_ranges(ranges) when is_list(ranges) do
    folds =
      ranges
      |> Enum.sort_by(& &1.start_line)
      |> remove_overlaps()

    %__MODULE__{folds: folds}
  end

  @doc "Returns true if the fold map has no folds."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{folds: []}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc "Returns the number of active folds."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{folds: folds}), do: length(folds)

  @doc "Returns the list of active fold ranges."
  @spec folds(t()) :: [FoldRange.t()]
  def folds(%__MODULE__{folds: folds}), do: folds

  # ── Fold/Unfold operations ───────────────────────────────────────────────

  @doc """
  Adds a fold range. Returns the updated fold map, or the original if the
  range overlaps with an existing fold.
  """
  @spec fold(t(), FoldRange.t()) :: t()
  def fold(%__MODULE__{folds: folds} = fm, %FoldRange{} = range) do
    if Enum.any?(folds, &FoldRange.overlaps?(&1, range)) do
      fm
    else
      new_folds = insert_sorted(folds, range)
      %__MODULE__{fm | folds: new_folds}
    end
  end

  @doc """
  Removes the fold containing the given buffer line. Returns the updated
  fold map. No-op if the line isn't in any fold.
  """
  @spec unfold_at(t(), non_neg_integer()) :: t()
  def unfold_at(%__MODULE__{folds: []} = fm, _line), do: fm

  def unfold_at(%__MODULE__{folds: folds} = fm, line) do
    new_folds = Enum.reject(folds, &FoldRange.contains?(&1, line))

    if length(new_folds) == length(folds) do
      fm
    else
      %__MODULE__{fm | folds: new_folds}
    end
  end

  @doc """
  Toggles the fold at the given buffer line. If the line is inside a fold,
  removes it. If the line is the start of a foldable range in the provided
  available ranges, adds the fold.
  """
  @spec toggle(t(), non_neg_integer(), [FoldRange.t()]) :: t()
  def toggle(%__MODULE__{} = fm, line, available_ranges) do
    case fold_at(fm, line) do
      {:ok, _range} ->
        unfold_at(fm, line)

      :none ->
        case Enum.find(available_ranges, &FoldRange.contains?(&1, line)) do
          nil -> fm
          range -> fold(fm, range)
        end
    end
  end

  @doc "Removes all folds."
  @spec unfold_all(t()) :: t()
  def unfold_all(%__MODULE__{} = _fm), do: new()

  @doc "Folds all provided ranges (non-overlapping only)."
  @spec fold_all(t(), [FoldRange.t()]) :: t()
  def fold_all(%__MODULE__{}, ranges), do: from_ranges(ranges)

  # ── Query operations ─────────────────────────────────────────────────────

  @doc "Returns true if the given buffer line is hidden by a fold (inside but not the start line)."
  @spec folded?(t(), non_neg_integer()) :: boolean()
  def folded?(%__MODULE__{folds: []}, _line), do: false

  def folded?(%__MODULE__{folds: folds}, line) do
    Enum.any?(folds, &FoldRange.hides?(&1, line))
  end

  @doc "Returns the fold range containing the given line, or :none."
  @spec fold_at(t(), non_neg_integer()) :: {:ok, FoldRange.t()} | :none
  def fold_at(%__MODULE__{folds: []}, _line), do: :none

  def fold_at(%__MODULE__{folds: folds}, line) do
    case Enum.find(folds, &FoldRange.contains?(&1, line)) do
      nil -> :none
      range -> {:ok, range}
    end
  end

  @doc "Returns true if the given buffer line is the start (summary) line of a fold."
  @spec fold_start?(t(), non_neg_integer()) :: boolean()
  def fold_start?(%__MODULE__{folds: []}, _line), do: false

  def fold_start?(%__MODULE__{folds: folds}, line) do
    Enum.any?(folds, fn %FoldRange{start_line: s} -> s == line end)
  end

  # ── Coordinate translation ──────────────────────────────────────────────

  @doc """
  Translates a buffer line number to a visible line number.

  Each folded range hides `end_line - start_line` lines (the start line
  remains visible as the summary). Lines before the first fold are
  unchanged. Returns the buffer line number minus the total hidden lines
  from folds that end before or contain this line.

  For hidden lines (inside a fold), returns the visible line of the fold's
  start line.
  """
  @spec buffer_to_visible(t(), non_neg_integer()) :: non_neg_integer()
  def buffer_to_visible(%__MODULE__{folds: []}, line), do: line

  def buffer_to_visible(%__MODULE__{folds: folds}, line) do
    hidden =
      Enum.reduce(folds, 0, fn %FoldRange{start_line: s, end_line: e}, acc ->
        cond do
          # Fold is entirely before this line: all its hidden lines are subtracted
          e < line -> acc + (e - s)
          # Line is inside this fold (hidden): count lines hidden before it
          line > s and line <= e -> acc + (line - s)
          # Fold starts at or after this line: doesn't affect it
          true -> acc
        end
      end)

    line - hidden
  end

  @doc """
  Translates a visible line number to a buffer line number.

  Inverse of `buffer_to_visible/2`. Walks through folds, adding back
  the hidden lines to map from visible coordinates to buffer coordinates.
  """
  @spec visible_to_buffer(t(), non_neg_integer()) :: non_neg_integer()
  def visible_to_buffer(%__MODULE__{folds: []}, visible), do: visible

  def visible_to_buffer(%__MODULE__{folds: folds}, visible) do
    do_visible_to_buffer(folds, visible, 0)
  end

  @spec do_visible_to_buffer([FoldRange.t()], non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_visible_to_buffer([], visible, offset), do: visible + offset

  defp do_visible_to_buffer(
         [%FoldRange{start_line: s, end_line: e} | rest],
         visible,
         offset
       ) do
    # The fold's start line appears at visible position (s - offset)
    fold_visible = s - offset

    if visible <= fold_visible do
      # The visible line is before this fold
      visible + offset
    else
      # Skip past this fold's hidden lines
      hidden = e - s
      do_visible_to_buffer(rest, visible, offset + hidden)
    end
  end

  @doc """
  Returns the total number of visible lines given the buffer's total line count.
  """
  @spec visible_line_count(t(), non_neg_integer()) :: non_neg_integer()
  def visible_line_count(%__MODULE__{folds: []}, total), do: total

  def visible_line_count(%__MODULE__{folds: folds}, total) do
    hidden =
      Enum.reduce(folds, 0, fn %FoldRange{start_line: s, end_line: e}, acc -> acc + (e - s) end)

    max(total - hidden, 0)
  end

  @doc """
  Returns the next visible buffer line after the given buffer line.

  Skips over folded regions. If the line is inside a fold, jumps to
  the line after the fold's end.
  """
  @spec next_visible(t(), non_neg_integer()) :: non_neg_integer()
  def next_visible(%__MODULE__{folds: []}, line), do: line + 1

  def next_visible(%__MODULE__{folds: folds}, line) do
    next = line + 1

    case Enum.find(folds, fn %FoldRange{start_line: s, end_line: e} -> next > s and next <= e end) do
      nil -> next
      %FoldRange{end_line: e} -> e + 1
    end
  end

  @doc """
  Returns the previous visible buffer line before the given buffer line.

  Skips over folded regions. If the previous line is inside a fold,
  jumps to the fold's start line.
  """
  @spec prev_visible(t(), non_neg_integer()) :: non_neg_integer()
  def prev_visible(%__MODULE__{folds: []}, line), do: max(line - 1, 0)

  def prev_visible(%__MODULE__{folds: folds}, line) do
    prev = max(line - 1, 0)

    case Enum.find(folds, fn %FoldRange{start_line: s, end_line: e} -> prev > s and prev <= e end) do
      nil -> prev
      %FoldRange{start_line: s} -> s
    end
  end

  @doc """
  Unfolds any fold that contains a line in the given list.

  Used by search to auto-unfold matches.
  """
  @spec unfold_containing(t(), [non_neg_integer()]) :: t()
  def unfold_containing(%__MODULE__{folds: []} = fm, _lines), do: fm

  def unfold_containing(%__MODULE__{folds: folds} = fm, lines) do
    new_folds =
      Enum.reject(folds, fn range ->
        Enum.any?(lines, &FoldRange.hides?(range, &1))
      end)

    %__MODULE__{fm | folds: new_folds}
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  @spec insert_sorted([FoldRange.t()], FoldRange.t()) :: [FoldRange.t()]
  defp insert_sorted([], range), do: [range]

  defp insert_sorted([head | tail] = list, range) do
    if range.start_line <= head.start_line do
      [range | list]
    else
      [head | insert_sorted(tail, range)]
    end
  end

  @spec remove_overlaps([FoldRange.t()]) :: [FoldRange.t()]
  defp remove_overlaps([]), do: []
  defp remove_overlaps([single]), do: [single]

  defp remove_overlaps([first, second | rest]) do
    if FoldRange.overlaps?(first, second) do
      # Keep the earlier range, skip the overlapping one
      remove_overlaps([first | rest])
    else
      [first | remove_overlaps([second | rest])]
    end
  end
end
