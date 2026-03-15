defmodule Minga.Editor.DisplayMap do
  @moduledoc """
  Unified buffer-line-to-display-row mapping.

  Merges per-window folds (`FoldMap`), per-buffer decoration folds
  (`Decorations.FoldRegion`), and virtual lines (`Decorations.VirtualText`
  with `:above`/`:below` placement) into a single authoritative mapping.

  The DisplayMap is the single source of truth for translating between
  buffer line numbers and screen row positions. It replaces
  `FoldMap.VisibleLines.compute/4` in the render pipeline.

  ## Design

  The DisplayMap is a pure data structure built once per frame from:
  1. Per-window `FoldMap` folds (code folds, per-window)
  2. Per-buffer decoration folds (closed fold regions from `Decorations`)
  3. Virtual lines from decorations (`:above`/`:below`)

  Block decoration heights (#523) will be added in a future PR.

  The map produces a list of `entry()` tuples describing what to render
  at each display row, compatible with the existing content rendering
  pipeline.
  """

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Decorations.FoldRegion
  alias Minga.Buffer.Decorations.VirtualText
  alias Minga.Editor.FoldMap
  alias Minga.Editor.FoldRange

  @typedoc """
  What to render at a display row.

  - `{buf_line, :normal}` — render the buffer line normally
  - `{buf_line, {:fold_start, hidden_count}}` — render with fold summary
  - `{buf_line, {:decoration_fold, fold_region}}` — render with custom placeholder
  - `{buf_line, {:virtual_line, virtual_text}}` — render a virtual line (no buffer line)
  """
  @type entry ::
          {non_neg_integer(), :normal}
          | {non_neg_integer(), {:fold_start, pos_integer()}}
          | {non_neg_integer(), {:decoration_fold, FoldRegion.t()}}
          | {non_neg_integer(), {:virtual_line, VirtualText.t()}}

  @typedoc "The computed display map for a viewport."
  @type t :: %__MODULE__{
          entries: [entry()],
          total_display_lines: non_neg_integer()
        }

  @enforce_keys [:entries]
  defstruct entries: [],
            total_display_lines: 0

  @doc """
  Computes the display map for a viewport.

  Merges per-window folds, decoration folds, and virtual lines into a
  unified list of display entries.

  Returns `nil` when there are no folds, decoration folds, or virtual
  lines, signaling the caller to use the faster sequential path.

  ## Arguments

  - `fold_map` — per-window `FoldMap` (code folds)
  - `decorations` — per-buffer `Decorations` (decoration folds + virtual lines)
  - `first_buf_line` — first buffer line to display (from viewport scroll)
  - `visible_rows` — number of screen rows available
  - `total_lines` — total lines in the buffer
  """
  @spec compute(FoldMap.t(), Decorations.t(), non_neg_integer(), pos_integer(), non_neg_integer()) ::
          t() | nil
  def compute(fold_map, decorations, first_buf_line, visible_rows, total_lines) do
    has_window_folds = not FoldMap.empty?(fold_map)
    has_closed_dec_folds = Decorations.closed_fold_regions(decorations) != []
    has_virtual_lines = has_virtual_lines?(decorations)

    if not has_window_folds and not has_closed_dec_folds and not has_virtual_lines do
      nil
    else
      closed_dec_folds = Decorations.closed_fold_regions(decorations)

      entries =
        build_entries(
          fold_map,
          closed_dec_folds,
          decorations,
          first_buf_line,
          visible_rows,
          total_lines,
          []
        )

      %__MODULE__{
        entries: entries,
        total_display_lines: length(entries)
      }
    end
  end

  @doc """
  Returns the buffer line range needed to fetch all visible lines.

  Used to request the right slice from the buffer.
  """
  @spec buffer_range(t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def buffer_range(%__MODULE__{entries: []}), do: nil

  def buffer_range(%__MODULE__{entries: entries}) do
    buf_lines =
      entries
      |> Enum.map(fn {line, _} -> line end)
      |> Enum.uniq()

    {Enum.min(buf_lines), Enum.max(buf_lines)}
  end

  @doc """
  Converts the display map entries to the format expected by
  `ContentHelpers.render_lines_nowrap_folded/3`.

  Returns a list compatible with `FoldMap.VisibleLines.line_entry()`.
  Virtual lines and decoration folds are included as additional entry types.
  """
  @spec to_visible_line_map(t()) :: [entry()]
  def to_visible_line_map(%__MODULE__{entries: entries}), do: entries

  @doc """
  Returns the display row for a given buffer line, or nil if the line
  is hidden by a fold.
  """
  @spec display_row_for_buf_line(t(), non_neg_integer()) :: non_neg_integer() | nil
  def display_row_for_buf_line(%__MODULE__{entries: entries}, buf_line) do
    Enum.find_index(entries, fn
      {line, :normal} -> line == buf_line
      {line, {:fold_start, _}} -> line == buf_line
      {line, {:decoration_fold, _}} -> line == buf_line
      _ -> false
    end)
  end

  @doc """
  Returns the buffer line at the given display row.
  """
  @spec buf_line_for_display_row(t(), non_neg_integer()) :: non_neg_integer() | nil
  def buf_line_for_display_row(%__MODULE__{entries: entries}, display_row) do
    case Enum.at(entries, display_row) do
      nil -> nil
      {line, _} -> line
    end
  end

  @doc """
  Computes the total number of display lines for the entire buffer
  (not just the viewport). Used for scrollbar calculations.
  """
  @spec total_display_lines(
          FoldMap.t(),
          Decorations.t(),
          non_neg_integer()
        ) :: non_neg_integer()
  def total_display_lines(fold_map, decorations, total_buf_lines) do
    window_hidden =
      FoldMap.folds(fold_map)
      |> Enum.reduce(0, fn f, acc -> acc + (f.end_line - f.start_line) end)

    dec_hidden =
      Decorations.closed_fold_regions(decorations)
      |> Enum.reduce(0, fn f, acc -> acc + FoldRegion.hidden_count(f) end)

    virt_lines = Decorations.virtual_line_count(decorations, 0, total_buf_lines)

    max(total_buf_lines - window_hidden - dec_hidden + virt_lines, 0)
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @spec has_virtual_lines?(Decorations.t()) :: boolean()
  defp has_virtual_lines?(%Decorations{virtual_texts: vts}) do
    Enum.any?(vts, fn %VirtualText{placement: p} -> p in [:above, :below] end)
  end

  @spec build_entries(
          FoldMap.t(),
          [FoldRegion.t()],
          Decorations.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [entry()]
        ) :: [entry()]
  defp build_entries(_fm, _dec_folds, _decs, _buf_line, 0, _total, acc) do
    Enum.reverse(acc)
  end

  defp build_entries(_fm, _dec_folds, _decs, buf_line, _remaining, total, acc)
       when buf_line >= total do
    Enum.reverse(acc)
  end

  defp build_entries(fm, dec_folds, decs, buf_line, remaining, total, acc) do
    # Query virtual lines once for this buffer line
    {above_vts, below_vts} = Decorations.virtual_lines_for_line(decs, buf_line)

    {acc, remaining} =
      Enum.reduce(above_vts, {acc, remaining}, fn vt, {a, r} ->
        if r > 0 do
          {[{buf_line, {:virtual_line, vt}} | a], r - 1}
        else
          {a, r}
        end
      end)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      # Classify what's at this buffer line and handle it
      handle_buf_line(fm, dec_folds, decs, buf_line, below_vts, remaining, total, acc)
    end
  end

  # Classifies and handles a single buffer line: window fold, decoration fold, or normal.
  @spec handle_buf_line(
          FoldMap.t(),
          [FoldRegion.t()],
          Decorations.t(),
          non_neg_integer(),
          [VirtualText.t()],
          non_neg_integer(),
          non_neg_integer(),
          [entry()]
        ) :: [entry()]
  defp handle_buf_line(fm, dec_folds, decs, buf_line, below_vts, remaining, total, acc) do
    case FoldMap.fold_at(fm, buf_line) do
      {:ok, %FoldRange{start_line: ^buf_line, end_line: end_line}} ->
        # Window fold start: emit fold entry, append below virtual lines, skip to after fold
        hidden = end_line - buf_line
        entry = {buf_line, {:fold_start, hidden}}
        {acc, remaining} = append_vt_entries([entry | acc], below_vts, buf_line, remaining - 1)
        build_entries(fm, dec_folds, decs, end_line + 1, remaining, total, acc)

      {:ok, %FoldRange{end_line: end_line}} ->
        build_entries(fm, dec_folds, decs, end_line + 1, remaining, total, acc)

      :none ->
        handle_no_window_fold(fm, dec_folds, decs, buf_line, below_vts, remaining, total, acc)
    end
  end

  defp handle_no_window_fold(fm, dec_folds, decs, buf_line, below_vts, remaining, total, acc) do
    case find_dec_fold(dec_folds, buf_line) do
      %FoldRegion{start_line: ^buf_line} = fold ->
        entry = {buf_line, {:decoration_fold, fold}}
        {acc, remaining} = append_vt_entries([entry | acc], below_vts, buf_line, remaining - 1)
        build_entries(fm, dec_folds, decs, fold.end_line + 1, remaining, total, acc)

      _ ->
        handle_normal_line(fm, dec_folds, decs, buf_line, below_vts, remaining, total, acc)
    end
  end

  defp handle_normal_line(fm, dec_folds, decs, buf_line, below_vts, remaining, total, acc) do
    entry = {buf_line, :normal}
    {acc, remaining} = append_vt_entries([entry | acc], below_vts, buf_line, remaining - 1)
    build_entries(fm, dec_folds, decs, buf_line + 1, remaining, total, acc)
  end

  @spec append_vt_entries([entry()], [VirtualText.t()], non_neg_integer(), non_neg_integer()) ::
          {[entry()], non_neg_integer()}
  defp append_vt_entries(acc, [], _buf_line, remaining), do: {acc, remaining}

  defp append_vt_entries(acc, below_vts, buf_line, remaining) do
    Enum.reduce(below_vts, {acc, remaining}, fn vt, {a, r} ->
      if r > 0 do
        {[{buf_line, {:virtual_line, vt}} | a], r - 1}
      else
        {a, r}
      end
    end)
  end

  @spec find_dec_fold([FoldRegion.t()], non_neg_integer()) :: FoldRegion.t() | nil
  defp find_dec_fold(dec_folds, line) do
    Enum.find(dec_folds, fn fold -> fold.start_line == line end)
  end
end
