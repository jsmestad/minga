defmodule Minga.Buffer.Decorations do
  @moduledoc """
  Buffer decoration storage and API.

  Stores highlight ranges (and later, virtual text, fold regions, and block
  decorations) for a single buffer. Decorations are visual overlays that do
  not modify the buffer's text content. They are stored per-buffer and
  consumed by the render pipeline during the content rendering stage.

  ## Highlight ranges

  Highlight ranges apply custom styling (fg, bg, bold, italic, underline,
  strikethrough) to arbitrary spans of buffer text. They compose with
  tree-sitter syntax highlighting: a highlight range that sets `bg` but
  not `fg` preserves the syntax foreground color.

  Multiple highlight ranges can overlap on the same character. When they
  do, higher-priority ranges override lower-priority ranges per-property.

  ## Anchor adjustment

  Decorations are anchor-based: their positions shift when the buffer is
  edited. Insertions before a range shift it right. Insertions within a
  range expand it. Deletions within a range shrink it. Deleting all text
  in a range removes it.

  ## Performance

  Ranges are backed by an interval tree (`Minga.Buffer.IntervalTree`)
  providing O(log n + k) range queries. This handles 10,000+ decorations
  per buffer (LSP diagnostics scale) without measurable frame-time impact.

  ## Batch updates

  The `batch/2` function defers tree rebuilding until the batch is
  committed, preventing frame stutter when replacing many decorations
  at once (e.g., agent chat sync or LSP diagnostic refresh).
  """

  alias Minga.Buffer.Decorations.HighlightRange
  alias Minga.Buffer.IntervalTree

  @typedoc "A position used in highlight range start/end."
  @type highlight_range_pos :: IntervalTree.position()

  @typedoc "A color value: 24-bit RGB integer."
  @type color :: non_neg_integer()

  @typedoc """
  Style properties for a highlight range. Each key is optional;
  only specified keys override the underlying syntax style.
  """
  @type style :: keyword()

  @typedoc """
  A highlight range decoration.

  - `id`: unique reference for removal
  - `start`: inclusive start position `{line, col}`
  - `end_`: exclusive end position `{line, col}`
  - `style`: keyword list of style overrides (fg, bg, bold, italic, underline, strikethrough)
  - `priority`: higher values win per-property on overlap (default 0)
  - `group`: optional atom for bulk removal by group (e.g., `:search`, `:diagnostics`, `:agent`)
  """
  @type highlight_range :: HighlightRange.t()

  @typedoc """
  The decorations state for a buffer.

  - `highlights`: interval tree of highlight ranges
  - `pending`: list of pending operations during a batch (nil when not batching)
  - `version`: monotonically increasing version for change detection by the render pipeline
  """
  @type t :: %__MODULE__{
          highlights: IntervalTree.t(),
          pending:
            [{:add, highlight_range()} | {:remove, reference()} | {:remove_group, atom()}] | nil,
          version: non_neg_integer()
        }

  @enforce_keys []
  defstruct highlights: nil,
            pending: nil,
            version: 0

  # ── Construction ─────────────────────────────────────────────────────────

  @doc "Creates an empty decorations store."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # ── Highlight range API ──────────────────────────────────────────────────

  @doc """
  Adds a highlight range. Returns `{id, updated_decorations}`.

  ## Options

  - `:style` (required) - keyword list of style properties (e.g., `[bg: 0x3E4452, bold: true]`)
  - `:priority` (optional, default 0) - higher values win per-property on overlap
  - `:group` (optional) - atom for bulk removal (e.g., `:search`, `:diagnostics`)

  ## Examples

      {id, decs} = Decorations.add_highlight(decs, {0, 0}, {0, 10}, style: [bg: 0x3E4452])
      {id, decs} = Decorations.add_highlight(decs, {5, 0}, {10, 0},
        style: [underline: true, fg: 0xFF6C6B],
        priority: 10,
        group: :diagnostics
      )
  """
  @spec add_highlight(t(), IntervalTree.position(), IntervalTree.position(), keyword()) ::
          {reference(), t()}
  def add_highlight(%__MODULE__{} = decs, start_pos, end_pos, opts) do
    id = make_ref()

    range = %HighlightRange{
      id: id,
      start: start_pos,
      end_: end_pos,
      style: Keyword.fetch!(opts, :style),
      priority: Keyword.get(opts, :priority, 0),
      group: Keyword.get(opts, :group)
    }

    case decs.pending do
      nil ->
        interval = range_to_interval(range)
        new_highlights = IntervalTree.insert(decs.highlights, interval)
        {id, %{decs | highlights: new_highlights, version: decs.version + 1}}

      pending ->
        {id, %{decs | pending: [{:add, range} | pending]}}
    end
  end

  @doc """
  Removes a highlight range by ID. No-op if the ID doesn't exist.
  """
  @spec remove_highlight(t(), reference()) :: t()
  def remove_highlight(%__MODULE__{} = decs, id) do
    case decs.pending do
      nil ->
        new_highlights = IntervalTree.delete(decs.highlights, id)
        %{decs | highlights: new_highlights, version: decs.version + 1}

      pending ->
        %{decs | pending: [{:remove, id} | pending]}
    end
  end

  @doc """
  Removes all highlight ranges belonging to a group.

  This is the efficient way to clear and re-apply decorations for a
  specific feature (e.g., clearing all `:search` highlights before
  adding new ones, or clearing all `:diagnostics` on a refresh).
  """
  @spec remove_group(t(), atom()) :: t()
  def remove_group(%__MODULE__{pending: nil} = decs, group) when is_atom(group) do
    new_highlights =
      IntervalTree.map_filter(decs.highlights, &filter_group(&1, group))

    %{decs | highlights: new_highlights, version: decs.version + 1}
  end

  def remove_group(%__MODULE__{pending: pending} = decs, group) when is_atom(group) do
    %{decs | pending: [{:remove_group, group} | pending]}
  end

  @spec filter_group(IntervalTree.interval(), atom()) ::
          {:keep, IntervalTree.interval()} | :remove
  defp filter_group(interval, group) do
    if interval.value.group == group, do: :remove, else: {:keep, interval}
  end

  @doc """
  Removes all decorations. Returns a fresh empty store with bumped version.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = decs) do
    %__MODULE__{version: decs.version + 1}
  end

  # ── Batch operations ─────────────────────────────────────────────────────

  @doc """
  Executes a batch of operations, deferring tree rebuilding until the end.

  The function receives the decorations struct and should call `add_highlight`,
  `remove_highlight`, and `remove_group` as needed. All operations are
  collected and applied at once, with a single tree rebuild.

  ## Example

      decs = Decorations.batch(decs, fn decs ->
        decs = Decorations.remove_group(decs, :search)
        {_id1, decs} = Decorations.add_highlight(decs, {0, 0}, {0, 5}, style: [bg: 0xECBE7B], group: :search)
        {_id2, decs} = Decorations.add_highlight(decs, {3, 0}, {3, 5}, style: [bg: 0xECBE7B], group: :search)
        decs
      end)
  """
  @spec batch(t(), (t() -> t())) :: t()
  def batch(%__MODULE__{} = decs, fun) when is_function(fun, 1) do
    # Enter batch mode
    batching = %{decs | pending: []}

    # Execute the function, collecting operations
    result = fun.(batching)

    # Apply all pending operations and rebuild the tree
    apply_pending(result)
  end

  @spec apply_pending(t()) :: t()
  defp apply_pending(%__MODULE__{pending: nil} = decs), do: decs

  defp apply_pending(%__MODULE__{pending: pending} = decs) do
    # Reverse to apply in order
    operations = Enum.reverse(pending)

    # Start with the current tree's intervals
    current_intervals = IntervalTree.to_list(decs.highlights)

    # Apply all operations to build the final interval list
    final_intervals =
      Enum.reduce(operations, current_intervals, &apply_batch_op/2)

    # Rebuild tree once
    new_highlights = IntervalTree.from_list(final_intervals)
    %{decs | highlights: new_highlights, pending: nil, version: decs.version + 1}
  end

  @spec apply_batch_op(
          {:add, highlight_range()} | {:remove, reference()} | {:remove_group, atom()},
          [IntervalTree.interval()]
        ) :: [IntervalTree.interval()]
  defp apply_batch_op({:add, range}, intervals), do: [range_to_interval(range) | intervals]

  defp apply_batch_op({:remove, id}, intervals),
    do: Enum.reject(intervals, fn i -> i.id == id end)

  defp apply_batch_op({:remove_group, group}, intervals),
    do: Enum.reject(intervals, fn i -> i.value.group == group end)

  # ── Query ────────────────────────────────────────────────────────────────

  @doc """
  Returns all highlight ranges that intersect the given line range.

  This is the primary query for the render pipeline. Returns highlight
  range structs (not raw intervals) sorted by priority (lowest first,
  so higher priority ranges are applied last and win on overlap).
  """
  @spec highlights_for_lines(t(), non_neg_integer(), non_neg_integer()) :: [highlight_range()]
  def highlights_for_lines(%__MODULE__{highlights: nil}, _start_line, _end_line), do: []

  def highlights_for_lines(%__MODULE__{highlights: highlights}, start_line, end_line) do
    highlights
    |> IntervalTree.query_lines(start_line, end_line)
    |> Enum.map(& &1.value)
    |> Enum.sort_by(& &1.priority)
  end

  @doc """
  Returns all highlight ranges that intersect a specific line.

  Convenience wrapper around `highlights_for_lines/3` for single-line queries.
  """
  @spec highlights_for_line(t(), non_neg_integer()) :: [highlight_range()]
  def highlights_for_line(decs, line), do: highlights_for_lines(decs, line, line)

  @doc """
  Returns the number of highlight ranges.
  """
  @spec highlight_count(t()) :: non_neg_integer()
  def highlight_count(%__MODULE__{highlights: nil}), do: 0
  def highlight_count(%__MODULE__{highlights: hl}), do: IntervalTree.size(hl)

  @doc """
  Returns true if there are no decorations of any kind.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{highlights: nil}), do: true
  def empty?(%__MODULE__{highlights: hl}), do: IntervalTree.empty?(hl)

  # ── Anchor adjustment ───────────────────────────────────────────────────

  @doc """
  Adjusts all decoration anchors after a buffer edit.

  Handles the three cases:
  1. **Insert before range**: shift range right
  2. **Insert within range**: expand range
  3. **Delete within range**: shrink range (remove if fully deleted)
  4. **Delete spanning range**: remove range

  `edit_start` and `edit_end` are the pre-edit positions of the changed region.
  `new_end` is the post-edit position where the change ends (for insertions,
  this is after the inserted text; for deletions, this equals `edit_start`).

  This is called by `Buffer.Server` after each edit, passing the positions
  from the `EditDelta`.
  """
  @spec adjust_for_edit(
          t(),
          IntervalTree.position(),
          IntervalTree.position(),
          IntervalTree.position()
        ) :: t()
  def adjust_for_edit(%__MODULE__{highlights: nil} = decs, _edit_start, _edit_end, _new_end),
    do: decs

  def adjust_for_edit(%__MODULE__{} = decs, edit_start, edit_end, new_end) do
    {edit_end_line, edit_end_col} = edit_end
    {new_end_line, new_end_col} = new_end

    line_delta = new_end_line - edit_end_line
    col_delta = new_end_col - edit_end_col
    ctx = build_edit_ctx(edit_start, edit_end, new_end, line_delta, col_delta)

    new_highlights =
      IntervalTree.map_filter(decs.highlights, fn interval ->
        adjust_range(interval.value, interval, ctx)
      end)

    %{decs | highlights: new_highlights, version: decs.version + 1}
  end

  @typep edit_ctx :: %{
           edit_start: IntervalTree.position(),
           edit_end: IntervalTree.position(),
           new_end: IntervalTree.position(),
           line_delta: integer(),
           col_delta: integer(),
           is_insert: boolean(),
           is_delete: boolean()
         }

  @spec build_edit_ctx(
          IntervalTree.position(),
          IntervalTree.position(),
          IntervalTree.position(),
          integer(),
          integer()
        ) :: edit_ctx()
  defp build_edit_ctx(edit_start, edit_end, new_end, line_delta, col_delta) do
    %{
      edit_start: edit_start,
      edit_end: edit_end,
      new_end: new_end,
      line_delta: line_delta,
      col_delta: col_delta,
      is_insert: edit_end == edit_start,
      is_delete: new_end == edit_start
    }
  end

  @spec adjust_range(highlight_range(), IntervalTree.interval(), edit_ctx()) ::
          {:keep, IntervalTree.interval()} | :remove

  # Range is entirely before the edit: no change
  defp adjust_range(range, interval, %{edit_start: edit_start})
       when range.end_ <= edit_start do
    {:keep, interval}
  end

  # Range is entirely after the edit: shift by delta
  defp adjust_range(range, interval, %{edit_end: edit_end} = ctx)
       when range.start >= edit_end do
    shift_range(range, interval, edit_end, ctx.line_delta, ctx.col_delta)
  end

  defp adjust_range(range, interval, ctx) do
    classify_and_adjust(range, interval, ctx)
  end

  # Handles insertion and deletion cases after the simple before/after checks
  @spec classify_and_adjust(highlight_range(), IntervalTree.interval(), edit_ctx()) ::
          {:keep, IntervalTree.interval()} | :remove
  defp classify_and_adjust(range, interval, %{is_insert: true} = ctx) do
    adjust_insertion(range, interval, ctx)
  end

  defp classify_and_adjust(range, interval, %{is_delete: true} = ctx) do
    adjust_deletion(range, interval, ctx)
  end

  defp classify_and_adjust(range, interval, ctx) do
    adjust_replacement(range, interval, ctx)
  end

  # Insertion within the range: expand. Insertion at start: shift.
  @spec adjust_insertion(highlight_range(), IntervalTree.interval(), edit_ctx()) ::
          {:keep, IntervalTree.interval()} | :remove
  defp adjust_insertion(range, interval, ctx)
       when range.start <= ctx.edit_start and range.end_ > ctx.edit_start do
    new_end_pos = shift_position(range.end_, ctx.edit_start, ctx.line_delta, ctx.col_delta)
    update_interval(range, interval, range.start, new_end_pos)
  end

  defp adjust_insertion(range, interval, ctx) when range.start == ctx.edit_start do
    new_end_pos = shift_position(range.end_, ctx.edit_start, ctx.line_delta, ctx.col_delta)
    update_interval(range, interval, ctx.new_end, new_end_pos)
  end

  defp adjust_insertion(_range, interval, _ctx), do: {:keep, interval}

  # Deletion cases
  @spec adjust_deletion(highlight_range(), IntervalTree.interval(), edit_ctx()) ::
          {:keep, IntervalTree.interval()} | :remove

  # Deletion spans entire range
  defp adjust_deletion(range, _interval, ctx)
       when ctx.edit_start <= range.start and ctx.edit_end >= range.end_ do
    :remove
  end

  # Deletion overlaps start of range
  defp adjust_deletion(range, interval, ctx)
       when ctx.edit_start <= range.start and ctx.edit_end > range.start and
              ctx.edit_end < range.end_ do
    new_end_pos = shift_position(range.end_, ctx.edit_end, ctx.line_delta, ctx.col_delta)
    update_interval_or_remove(range, interval, ctx.edit_start, new_end_pos)
  end

  # Deletion overlaps end of range
  defp adjust_deletion(range, interval, ctx)
       when ctx.edit_start > range.start and ctx.edit_start < range.end_ and
              ctx.edit_end >= range.end_ do
    update_interval_or_remove(range, interval, range.start, ctx.edit_start)
  end

  # Deletion entirely within range: shrink
  defp adjust_deletion(range, interval, ctx)
       when ctx.edit_start > range.start and ctx.edit_end < range.end_ do
    new_end_pos = shift_position(range.end_, ctx.edit_end, ctx.line_delta, ctx.col_delta)
    update_interval(range, interval, range.start, new_end_pos)
  end

  defp adjust_deletion(_range, interval, _ctx), do: {:keep, interval}

  # General replacement: delete + insert
  @spec adjust_replacement(highlight_range(), IntervalTree.interval(), edit_ctx()) ::
          {:keep, IntervalTree.interval()} | :remove
  defp adjust_replacement(range, interval, ctx) do
    new_start = if range.start < ctx.edit_start, do: range.start, else: ctx.new_end

    new_end_pos =
      if range.end_ <= ctx.edit_end do
        ctx.new_end
      else
        shift_position(range.end_, ctx.edit_end, ctx.line_delta, ctx.col_delta)
      end

    update_interval_or_remove(range, interval, new_start, new_end_pos)
  end

  # Shared helpers for building updated intervals
  @spec shift_range(
          highlight_range(),
          IntervalTree.interval(),
          IntervalTree.position(),
          integer(),
          integer()
        ) ::
          {:keep, IntervalTree.interval()}
  defp shift_range(range, interval, ref_pos, line_delta, col_delta) do
    new_start = shift_position(range.start, ref_pos, line_delta, col_delta)
    new_end_pos = shift_position(range.end_, ref_pos, line_delta, col_delta)
    update_interval(range, interval, new_start, new_end_pos)
  end

  @spec update_interval(
          highlight_range(),
          IntervalTree.interval(),
          IntervalTree.position(),
          IntervalTree.position()
        ) ::
          {:keep, IntervalTree.interval()}
  defp update_interval(range, interval, new_start, new_end_pos) do
    updated = %{range | start: new_start, end_: new_end_pos}
    {:keep, %{interval | start: new_start, end_: new_end_pos, value: updated}}
  end

  @spec update_interval_or_remove(
          highlight_range(),
          IntervalTree.interval(),
          IntervalTree.position(),
          IntervalTree.position()
        ) ::
          {:keep, IntervalTree.interval()} | :remove
  defp update_interval_or_remove(range, interval, new_start, new_end_pos) do
    if new_start >= new_end_pos do
      :remove
    else
      update_interval(range, interval, new_start, new_end_pos)
    end
  end

  @spec shift_position(IntervalTree.position(), IntervalTree.position(), integer(), integer()) ::
          IntervalTree.position()
  defp shift_position({pos_line, pos_col}, {ref_line, _ref_col}, line_delta, col_delta) do
    if pos_line == ref_line do
      {pos_line + line_delta, max(0, pos_col + col_delta)}
    else
      {pos_line + line_delta, pos_col}
    end
  end

  # ── Style merging ───────────────────────────────────────────────────────

  @doc """
  Merges highlight range styles onto syntax-highlighted segments for a line.

  Takes the tree-sitter segments (list of `{text, style}` tuples) and the
  highlight ranges intersecting this line, and produces a merged segment
  list where decoration styles override syntax styles per-property.

  This is the shared merge function used by both highlight range decorations
  and (in the future) visual selection. It splits segments at range
  boundaries and applies style overrides from highest-priority matching
  ranges.

  ## Arguments

  - `segments`: list of `{text, style_keyword}` from tree-sitter or plain rendering
  - `ranges`: highlight ranges for this line, sorted by priority (lowest first)
  - `line`: the buffer line number (0-indexed)

  ## Returns

  A list of `{text, merged_style}` tuples with finer granularity where
  ranges split syntax segments.
  """
  @spec merge_highlights([{String.t(), keyword()}], [highlight_range()], non_neg_integer()) ::
          [{String.t(), keyword()}]
  def merge_highlights(segments, [], _line), do: segments

  def merge_highlights(segments, ranges, line) do
    # Build a list of column-indexed style overlays for this line
    overlays = ranges_to_line_overlays(ranges, line)

    if overlays == [] do
      segments
    else
      split_and_merge_segments(segments, overlays)
    end
  end

  @typedoc "A column-indexed style overlay: applies from start_col (inclusive) to end_col (exclusive)."
  @type overlay ::
          {start_col :: non_neg_integer(), end_col :: non_neg_integer() | :infinity,
           style :: keyword(), priority :: integer()}

  @spec ranges_to_line_overlays([highlight_range()], non_neg_integer()) :: [overlay()]
  defp ranges_to_line_overlays(ranges, line) do
    Enum.map(ranges, fn range ->
      {_rs_line, rs_col} = range.start
      {re_line, re_col} = range.end_
      {rs_line, _} = range.start

      start_col = if rs_line < line, do: 0, else: rs_col
      end_col = if re_line > line, do: :infinity, else: re_col

      {start_col, end_col, range.style, range.priority}
    end)
    |> Enum.sort_by(fn {sc, _, _, priority} -> {sc, priority} end)
  end

  @spec split_and_merge_segments([{String.t(), keyword()}], [overlay()]) ::
          [{String.t(), keyword()}]
  defp split_and_merge_segments(segments, overlays) do
    # Walk through segments tracking the current column position.
    # At each column, determine which overlays are active and merge styles.
    {result, _col} =
      Enum.reduce(segments, {[], 0}, fn {text, base_style}, {acc, col} ->
        seg_width = String.length(text)
        seg_end = col + seg_width

        # Find all overlays that intersect this segment
        active = active_overlays(overlays, col, seg_end)

        if active == [] do
          {[{text, base_style} | acc], seg_end}
        else
          # Split this segment at overlay boundaries
          sub_segments = split_segment_at_boundaries(text, base_style, col, active)
          {Enum.reverse(sub_segments) ++ acc, seg_end}
        end
      end)

    Enum.reverse(result)
  end

  @spec active_overlays([overlay()], non_neg_integer(), non_neg_integer()) :: [overlay()]
  defp active_overlays(overlays, seg_start, seg_end) do
    Enum.filter(overlays, fn {ov_start, ov_end, _style, _priority} ->
      ov_end_val = if ov_end == :infinity, do: seg_end + 1, else: ov_end
      ov_start < seg_end and ov_end_val > seg_start
    end)
  end

  @spec split_segment_at_boundaries(String.t(), keyword(), non_neg_integer(), [overlay()]) ::
          [{String.t(), keyword()}]
  defp split_segment_at_boundaries(text, base_style, seg_start, overlays) do
    seg_end = seg_start + String.length(text)

    # Collect all boundary points within this segment
    boundaries =
      overlays
      |> Enum.flat_map(fn {ov_start, ov_end, _style, _priority} ->
        points = []

        points =
          if ov_start > seg_start and ov_start < seg_end, do: [ov_start | points], else: points

        ov_end_val = if ov_end == :infinity, do: seg_end, else: ov_end

        if ov_end_val > seg_start and ov_end_val < seg_end,
          do: [ov_end_val | points],
          else: points
      end)
      |> Enum.uniq()
      |> Enum.sort()

    # Build sub-segments between boundaries
    split_points = [seg_start | boundaries] ++ [seg_end]

    split_points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(&render_sub_segment(&1, text, seg_start, base_style, overlays))
    |> Enum.reject(fn {t, _} -> t == "" end)
  end

  @spec render_sub_segment([non_neg_integer()], String.t(), non_neg_integer(), keyword(), [
          overlay()
        ]) ::
          {String.t(), keyword()}
  defp render_sub_segment([sub_start, sub_end], text, seg_start, base_style, overlays) do
    sub_text = String.slice(text, (sub_start - seg_start)..(sub_end - seg_start - 1)//1)

    active_here =
      Enum.filter(overlays, fn {ov_start, ov_end, _style, _priority} ->
        ov_end_val = if ov_end == :infinity, do: sub_end + 1, else: ov_end
        ov_start <= sub_start and ov_end_val > sub_start
      end)

    merged_style =
      active_here
      |> Enum.sort_by(fn {_, _, _, priority} -> priority end)
      |> Enum.reduce(base_style, fn {_, _, overlay_style, _}, acc ->
        merge_style_props(acc, overlay_style)
      end)

    {sub_text, merged_style}
  end

  @doc """
  Merges overlay style properties onto a base style.

  Only properties present in the overlay override the base. This preserves
  tree-sitter syntax colors when a decoration only specifies background.

  ## Examples

      merge_style_props([fg: 0xFF0000], [bg: 0x3E4452])
      #=> [fg: 0xFF0000, bg: 0x3E4452]

      merge_style_props([fg: 0xFF0000, bold: true], [fg: 0x00FF00])
      #=> [fg: 0x00FF00, bold: true]
  """
  @spec merge_style_props(keyword(), keyword()) :: keyword()
  def merge_style_props(base, overlay) do
    Keyword.merge(base, overlay)
  end

  # ── Internal helpers ─────────────────────────────────────────────────────

  @spec range_to_interval(highlight_range()) :: IntervalTree.interval()
  defp range_to_interval(range) do
    %{
      id: range.id,
      start: range.start,
      end_: range.end_,
      value: range
    }
  end
end
