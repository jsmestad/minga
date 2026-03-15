defmodule Minga.Editor.DisplayMap do
  @moduledoc """
  Unified buffer-line-to-display-row mapping.

  Merges per-window folds (`FoldMap`), per-buffer decoration folds
  (`Decorations.FoldRegion`), virtual lines (`Decorations.VirtualText`
  with `:above`/`:below` placement), and block decorations into a single
  authoritative mapping.

  The DisplayMap is the single source of truth for translating between
  buffer line numbers and screen row positions. It replaces
  `FoldMap.VisibleLines.compute/4` in the render pipeline.

  ## Design

  The DisplayMap is a pure data structure built once per frame from:
  1. Per-window `FoldMap` folds (code folds, per-window)
  2. Per-buffer decoration folds (closed fold regions from `Decorations`)
  3. Virtual lines from decorations (`:above`/`:below`)
  4. Block decorations (custom-rendered lines between buffer lines)

  The map produces a list of `entry()` tuples describing what to render
  at each display row, compatible with the existing content rendering
  pipeline.
  """

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Decorations.BlockDecoration
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
  - `{buf_line, {:block, block_decoration, line_index}}` — render a block decoration row
  """
  @type entry ::
          {non_neg_integer(), :normal}
          | {non_neg_integer(), {:fold_start, pos_integer()}}
          | {non_neg_integer(), {:decoration_fold, FoldRegion.t()}}
          | {non_neg_integer(), {:virtual_line, VirtualText.t()}}
          | {non_neg_integer(), {:block, BlockDecoration.t(), non_neg_integer()}}

  @typedoc "The computed display map for a viewport."
  @type t :: %__MODULE__{
          entries: [entry()],
          total_display_lines: non_neg_integer()
        }

  @enforce_keys [:entries]
  defstruct entries: [],
            total_display_lines: 0

  # Frame-level constants bundled to avoid threading 5+ args through every
  # recursive call. Only `buf_line`, `remaining`, and `acc` change per step.
  @typep build_ctx :: %{
           fold_map: FoldMap.t(),
           dec_folds: [FoldRegion.t()],
           decorations: Decorations.t(),
           total_lines: non_neg_integer(),
           content_width: pos_integer()
         }

  @doc """
  Computes the display map for a viewport.

  Returns `nil` when there are no folds, decoration folds, virtual lines,
  or block decorations, signaling the caller to use the faster sequential path.

  ## Arguments

  - `fold_map` — per-window `FoldMap` (code folds)
  - `decorations` — per-buffer `Decorations`
  - `first_buf_line` — first buffer line to display (from viewport scroll)
  - `visible_rows` — number of screen rows available
  - `total_lines` — total lines in the buffer
  - `content_width` — available width for block decoration render callbacks (default 80)
  """
  @spec compute(
          FoldMap.t(),
          Decorations.t(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          pos_integer()
        ) :: t() | nil
  def compute(
        fold_map,
        decorations,
        first_buf_line,
        visible_rows,
        total_lines,
        content_width \\ 80
      ) do
    has_window_folds = not FoldMap.empty?(fold_map)
    closed_dec_folds = Decorations.closed_fold_regions(decorations)
    has_virtual_lines = has_virtual_lines?(decorations)
    has_blocks = Decorations.has_block_decorations?(decorations)

    if not has_window_folds and closed_dec_folds == [] and not has_virtual_lines and
         not has_blocks do
      nil
    else
      ctx = %{
        fold_map: fold_map,
        dec_folds: closed_dec_folds,
        decorations: decorations,
        total_lines: total_lines,
        content_width: content_width
      }

      entries = build_entries(ctx, first_buf_line, visible_rows, [])

      %__MODULE__{
        entries: entries,
        total_display_lines: length(entries)
      }
    end
  end

  # ── Public query API ─────────────────────────────────────────────────────

  @doc "Returns the buffer line range needed to fetch all visible lines."
  @spec buffer_range(t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def buffer_range(%__MODULE__{entries: []}), do: nil

  def buffer_range(%__MODULE__{entries: entries}) do
    buf_lines = entries |> Enum.map(fn {line, _} -> line end) |> Enum.uniq()
    {Enum.min(buf_lines), Enum.max(buf_lines)}
  end

  @doc "Returns the entry list for the content renderer."
  @spec to_visible_line_map(t()) :: [entry()]
  def to_visible_line_map(%__MODULE__{entries: entries}), do: entries

  @doc "Returns the display row for a buffer line, or nil if hidden."
  @spec display_row_for_buf_line(t(), non_neg_integer()) :: non_neg_integer() | nil
  def display_row_for_buf_line(%__MODULE__{entries: entries}, buf_line) do
    Enum.find_index(entries, fn {line, type} -> line == buf_line and buffer_line_entry?(type) end)
  end

  @doc "Returns the buffer line at the given display row."
  @spec buf_line_for_display_row(t(), non_neg_integer()) :: non_neg_integer() | nil
  def buf_line_for_display_row(%__MODULE__{entries: entries}, display_row) do
    case Enum.at(entries, display_row) do
      nil -> nil
      {line, _} -> line
    end
  end

  @doc "Returns the next visible buffer line after the given line."
  @spec next_visible_line(t(), non_neg_integer()) :: non_neg_integer()
  def next_visible_line(%__MODULE__{entries: entries}, line) do
    idx = Enum.find_index(entries, fn {l, type} -> l == line and buffer_line_entry?(type) end)

    case idx do
      nil ->
        line + 1

      i ->
        entries
        |> Enum.drop(i + 1)
        |> Enum.find(fn {_l, type} -> buffer_line_entry?(type) end)
        |> case do
          nil -> line + 1
          {next_line, _} -> next_line
        end
    end
  end

  @doc "Returns the previous visible buffer line before the given line."
  @spec prev_visible_line(t(), non_neg_integer()) :: non_neg_integer()
  def prev_visible_line(%__MODULE__{entries: entries}, line) do
    idx = Enum.find_index(entries, fn {l, type} -> l == line and buffer_line_entry?(type) end)

    case idx do
      nil ->
        max(line - 1, 0)

      0 ->
        max(line - 1, 0)

      i ->
        entries
        |> Enum.take(i)
        |> Enum.reverse()
        |> Enum.find(fn {_l, type} -> buffer_line_entry?(type) end)
        |> case do
          nil -> max(line - 1, 0)
          {prev_line, _} -> prev_line
        end
    end
  end

  @doc "Total display lines for the entire buffer (scrollbar calculations)."
  @spec total_display_lines(FoldMap.t(), Decorations.t(), non_neg_integer(), pos_integer()) ::
          non_neg_integer()
  def total_display_lines(fold_map, decorations, total_buf_lines, content_width \\ 80) do
    window_hidden =
      FoldMap.folds(fold_map)
      |> Enum.reduce(0, fn f, acc -> acc + (f.end_line - f.start_line) end)

    dec_hidden =
      Decorations.closed_fold_regions(decorations)
      |> Enum.reduce(0, fn f, acc -> acc + FoldRegion.hidden_count(f) end)

    virt_lines = Decorations.virtual_line_count(decorations, 0, total_buf_lines)

    all_folds = FoldMap.folds(fold_map) ++ Decorations.closed_fold_regions(decorations)

    block_rows =
      decorations.block_decorations
      |> Enum.reject(fn b -> line_inside_fold?(b.anchor_line, all_folds) end)
      |> Enum.reduce(0, fn b, acc -> acc + BlockDecoration.resolve_height(b, content_width) end)

    max(total_buf_lines - window_hidden - dec_hidden + virt_lines + block_rows, 0)
  end

  # ── Private: entry classification ────────────────────────────────────────

  # Returns true for entry types that represent real buffer lines (cursor targets).
  # Virtual lines and block decorations are not cursor targets.
  @spec buffer_line_entry?(term()) :: boolean()
  defp buffer_line_entry?(:normal), do: true
  defp buffer_line_entry?({:fold_start, _}), do: true
  defp buffer_line_entry?({:decoration_fold, _}), do: true
  defp buffer_line_entry?(_), do: false

  @spec has_virtual_lines?(Decorations.t()) :: boolean()
  defp has_virtual_lines?(%Decorations{virtual_texts: vts}) do
    Enum.any?(vts, fn %VirtualText{placement: p} -> p in [:above, :below] end)
  end

  # ── Private: entry building ──────────────────────────────────────────────

  @spec build_entries(build_ctx(), non_neg_integer(), non_neg_integer(), [entry()]) :: [entry()]
  defp build_entries(_ctx, _buf_line, 0, acc), do: Enum.reverse(acc)

  defp build_entries(%{total_lines: total}, buf_line, _remaining, acc)
       when buf_line >= total do
    Enum.reverse(acc)
  end

  defp build_entries(ctx, buf_line, remaining, acc) do
    {above_vts, below_vts} = Decorations.virtual_lines_for_line(ctx.decorations, buf_line)
    {above_blocks, below_blocks} = Decorations.blocks_for_line(ctx.decorations, buf_line)

    {acc, remaining} = append_block_entries(acc, above_blocks, buf_line, remaining, ctx)
    {acc, remaining} = append_vt_entries(acc, above_vts, buf_line, remaining)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      below = {below_vts, below_blocks}
      classify_line(ctx, buf_line, below, remaining, acc)
    end
  end

  # Classify what's at a buffer line: window fold, decoration fold, or normal.
  @spec classify_line(
          build_ctx(),
          non_neg_integer(),
          {[VirtualText.t()], [BlockDecoration.t()]},
          non_neg_integer(),
          [entry()]
        ) :: [entry()]
  defp classify_line(ctx, buf_line, below, remaining, acc) do
    case FoldMap.fold_at(ctx.fold_map, buf_line) do
      {:ok, %FoldRange{start_line: ^buf_line, end_line: end_line}} ->
        entry = {buf_line, {:fold_start, end_line - buf_line}}
        {acc, remaining} = append_below([entry | acc], below, buf_line, remaining - 1, ctx)
        build_entries(ctx, end_line + 1, remaining, acc)

      {:ok, %FoldRange{end_line: end_line}} ->
        build_entries(ctx, end_line + 1, remaining, acc)

      :none ->
        classify_no_window_fold(ctx, buf_line, below, remaining, acc)
    end
  end

  defp classify_no_window_fold(ctx, buf_line, below, remaining, acc) do
    case find_dec_fold(ctx.dec_folds, buf_line) do
      %FoldRegion{start_line: ^buf_line} = fold ->
        entry = {buf_line, {:decoration_fold, fold}}
        {acc, remaining} = append_below([entry | acc], below, buf_line, remaining - 1, ctx)
        build_entries(ctx, fold.end_line + 1, remaining, acc)

      _ ->
        entry = {buf_line, :normal}
        {acc, remaining} = append_below([entry | acc], below, buf_line, remaining - 1, ctx)
        build_entries(ctx, buf_line + 1, remaining, acc)
    end
  end

  # ── Private: append helpers ──────────────────────────────────────────────

  defp append_below(acc, {below_vts, below_blocks}, buf_line, remaining, ctx) do
    {acc, remaining} = append_vt_entries(acc, below_vts, buf_line, remaining)
    append_block_entries(acc, below_blocks, buf_line, remaining, ctx)
  end

  defp append_vt_entries(acc, [], _buf_line, remaining), do: {acc, remaining}

  defp append_vt_entries(acc, vts, buf_line, remaining) do
    Enum.reduce(vts, {acc, remaining}, fn vt, {a, r} ->
      if r > 0, do: {[{buf_line, {:virtual_line, vt}} | a], r - 1}, else: {a, r}
    end)
  end

  defp append_block_entries(acc, [], _buf_line, remaining, _ctx), do: {acc, remaining}

  defp append_block_entries(acc, blocks, buf_line, remaining, ctx) do
    Enum.reduce(blocks, {acc, remaining}, fn block, {a, r} ->
      append_single_block(a, block, buf_line, r, ctx.content_width)
    end)
  end

  defp append_single_block(acc, block, buf_line, remaining, content_width) do
    height = BlockDecoration.resolve_height(block, content_width)

    Enum.reduce(0..(height - 1), {acc, remaining}, fn line_idx, {a, r} ->
      if r > 0, do: {[{buf_line, {:block, block, line_idx}} | a], r - 1}, else: {a, r}
    end)
  end

  # ── Private: lookups ─────────────────────────────────────────────────────

  defp find_dec_fold(dec_folds, line) do
    Enum.find(dec_folds, fn fold -> fold.start_line == line end)
  end

  defp line_inside_fold?(line, folds) do
    Enum.any?(folds, fn
      %FoldRange{start_line: s, end_line: e} -> line > s and line <= e
      %FoldRegion{start_line: s, end_line: e} -> line > s and line <= e
    end)
  end
end
