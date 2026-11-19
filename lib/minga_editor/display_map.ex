defmodule MingaEditor.DisplayMap do
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

  In a wrapped page, group order stays the same. Only ordinary source lines
  expand; the viewport can start on any row of a group.
  """

  alias Minga.Core.Decorations
  alias Minga.Core.Decorations.BlockDecoration
  alias Minga.Core.Decorations.FoldRegion
  alias Minga.Core.Decorations.VirtualText
  alias Minga.Core.WrapMap
  alias MingaEditor.FoldMap
  alias MingaEditor.Viewport
  alias Minga.Editing.Fold.Range, as: FoldRange

  @typedoc """
  What to render at a display row.

  - `{buf_line, :normal}` — render the buffer line normally
  - `{buf_line, {:fold_start, hidden_count}}` — render with fold summary
  - `{buf_line, {:decoration_fold, fold_region}}` — render with custom placeholder
  - `{buf_line, {:virtual_line, virtual_text}}` — render a virtual line (no buffer line)
  - `{buf_line, {:block, block_decoration, line_index}}` — render a block decoration row
  - `{buf_line, {:wrapped, index}}` — render one segment of an ordinary wrapped line
  """
  @type entry ::
          {non_neg_integer(), :normal}
          | {non_neg_integer(), {:wrapped, non_neg_integer()}}
          | {non_neg_integer(), {:fold_start, pos_integer()}}
          | {non_neg_integer(), {:decoration_fold, FoldRegion.t()}}
          | {non_neg_integer(), {:virtual_line, VirtualText.t()}}
          | {non_neg_integer(), {:block, BlockDecoration.t(), non_neg_integer()}}

  @type segments :: WrapMap.wrap_entry() | tuple()

  @typedoc "Source text, absolute byte offset, composed text, wrap segments and their count."
  @type source ::
          {String.t(), non_neg_integer(), String.t(), segments(), non_neg_integer()}
  @type sources :: %{non_neg_integer() => source()}

  @typedoc "The computed display map for a viewport."
  @type t :: %__MODULE__{
          entries: [entry()],
          sources: sources(),
          wrap_basis: tuple() | nil,
          source_fetch_count: non_neg_integer()
        }

  @enforce_keys [:entries]
  defstruct entries: [], sources: %{}, wrap_basis: nil, source_fetch_count: 0

  @typep source_kind ::
           :normal | {:fold_start, pos_integer()} | {:decoration_fold, FoldRegion.t()}
  @typep special ::
           {:virtual_line, VirtualText.t()} | {:block, BlockDecoration.t(), non_neg_integer()}
  @type group :: {non_neg_integer(), source_kind(), [special()], [special()]}
  @typep fold :: {non_neg_integer(), non_neg_integer(), source_kind()}
  @opaque projection :: %{
            folds: tuple(),
            decorations: Decorations.t(),
            total: pos_integer(),
            width: pos_integer()
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
    if required?(fold_map, decorations) do
      entries =
        if first_buf_line < total_lines do
          projection = project(fold_map, decorations, total_lines, content_width)

          unwrapped_entries(
            projection,
            visible_source(projection, first_buf_line),
            visible_rows,
            []
          )
        else
          []
        end

      %__MODULE__{entries: entries}
    end
  end

  @doc "Returns true when folds, virtual lines, or block decorations require a display map."
  @spec required?(FoldMap.t(), Decorations.t()) :: boolean()
  def required?(%FoldMap{folds: []}, %Decorations{
        fold_regions: [],
        virtual_texts: [],
        block_decorations: []
      }),
      do: false

  def required?(fold_map, decorations) do
    required?(fold_map, decorations, Decorations.closed_fold_regions(decorations))
  end

  @spec required?(FoldMap.t(), Decorations.t(), [FoldRegion.t()]) :: boolean()
  defp required?(fold_map, decorations, closed_dec_folds) do
    has_window_folds = not FoldMap.empty?(fold_map)
    has_virtual_lines = has_virtual_lines?(decorations)
    has_blocks = Decorations.has_block_decorations?(decorations)
    has_window_folds or closed_dec_folds != [] or has_virtual_lines or has_blocks
  end

  # ── Public live API ─────────────────────────────────────────────────────

  @doc "Returns the entry list for the content renderer."
  @spec to_visible_line_map(t()) :: [entry()]
  def to_visible_line_map(%__MODULE__{entries: entries}), do: entries

  @doc "Returns the display row for a buffer line, or nil if hidden."
  @spec display_row_for_buf_line(t(), non_neg_integer()) :: non_neg_integer() | nil
  def display_row_for_buf_line(%__MODULE__{entries: entries}, buf_line) do
    Enum.find_index(entries, fn {line, type} -> line == buf_line and buffer_line_entry?(type) end)
  end

  @doc "Returns measured text and its absolute byte position for a source-backed entry."
  @spec source(t(), non_neg_integer()) :: source()
  def source(%__MODULE__{sources: sources}, line), do: Map.fetch!(sources, line)

  @doc "Returns just the requested segment range of a measured source line."
  @spec segments(source(), non_neg_integer(), pos_integer()) :: WrapMap.wrap_entry()
  def segments({_, _, _, rows, _}, 0, count) when is_tuple(rows) and tuple_size(rows) == count,
    do: Tuple.to_list(rows)

  def segments({_, _, _, rows, _}, first, count) when is_tuple(rows),
    do: for(index <- first..(first + count - 1), do: elem(rows, index))

  def segments({_, _, _, rows, _}, first, count), do: Enum.slice(rows, first, count)

  @doc "Attaches the basis and source-fetch count for a measured mixed page."
  @spec with_measurement_metadata(t(), tuple() | nil, non_neg_integer()) :: t()
  def with_measurement_metadata(%__MODULE__{} = map, basis, fetched),
    do: %{map | wrap_basis: basis, source_fetch_count: fetched}

  @doc "Returns exact wrap counts of normal source groups; folds and decoration rows are excluded."
  @spec wrap_counts(sources()) :: %{non_neg_integer() => pos_integer()}
  def wrap_counts(sources) do
    Map.new(for {line, {_, _, _, _, count}} <- sources, count > 0, do: {line, count})
  end

  @doc "Returns the measured text for a source line, or an empty string outside the page."
  @spec source_text(t(), non_neg_integer()) :: String.t()
  def source_text(%__MODULE__{sources: sources}, line) do
    case Map.fetch(sources, line) do
      {:ok, {text, _, _, _, _}} -> text
      :error -> ""
    end
  end

  @doc "Returns consecutive runs of visible source lines for range-based consumers."
  @spec source_runs(t()) :: [{non_neg_integer(), [String.t()]}]
  def source_runs(%__MODULE__{entries: entries} = page) do
    entries
    |> Enum.reduce([], fn {line, kind}, runs ->
      if buffer_line_entry?(kind), do: add_source_line(runs, page, line), else: runs
    end)
    |> Enum.reverse()
    |> Enum.map(fn {first, _last, lines} -> {first, Enum.reverse(lines)} end)
  end

  defp add_source_line([{_, line, _} | _] = runs, _page, line), do: runs

  defp add_source_line([{first, last, lines} | rest], page, line) when line == last + 1,
    do: [{first, line, [source_text(page, line) | lines]} | rest]

  defp add_source_line(runs, page, line), do: [{line, line, [source_text(page, line)]} | runs]

  # ── Private: entry classification ────────────────────────────────────────

  # Returns true for entry types that represent real buffer lines (cursor targets).
  # Virtual lines and block decorations are not cursor targets.
  @spec buffer_line_entry?(term()) :: boolean()
  defp buffer_line_entry?(:normal), do: true
  defp buffer_line_entry?({:wrapped, _}), do: true
  defp buffer_line_entry?({:fold_start, _}), do: true
  defp buffer_line_entry?({:decoration_fold, _}), do: true
  defp buffer_line_entry?(_), do: false

  @spec has_virtual_lines?(Decorations.t()) :: boolean()
  defp has_virtual_lines?(%Decorations{virtual_texts: vts}) do
    Enum.any?(vts, fn %VirtualText{placement: p} -> p in [:above, :below] end)
  end

  @doc "Prepares fold visibility and decoration order without reading any source text."
  @spec project(FoldMap.t(), Decorations.t(), pos_integer(), pos_integer()) :: projection()
  def project(fold_map, decorations, total_lines, text_width) do
    window_folds =
      Enum.map(FoldMap.visible_folds(fold_map), fn %FoldRange{start_line: start, end_line: last} ->
        {start, last, {:fold_start, last - start}}
      end)

    decoration_folds =
      Enum.map(Decorations.closed_fold_regions(decorations), fn fold ->
        {fold.start_line, fold.end_line, {:decoration_fold, fold}}
      end)

    folds =
      (window_folds ++ decoration_folds)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce([], &insert_fold/2)
      |> Enum.reverse()
      |> List.to_tuple()

    %{folds: folds, decorations: decorations, total: total_lines, width: text_width}
  end

  @spec insert_fold(fold(), [fold()]) :: [fold()]
  defp insert_fold({start, last, {:fold_start, _}}, [{first, stop, kind} | rest])
       when start <= stop and last > stop,
       do: [{first, last, kind} | rest]

  defp insert_fold({start, _, _}, [{_, stop, _} | _] = folds) when start <= stop, do: folds
  defp insert_fold(fold, folds), do: [fold | folds]

  @doc "Finds the visible source group at or containing a buffer line."
  @spec visible_source(projection(), non_neg_integer()) :: non_neg_integer()
  def visible_source(projection, line) do
    line = min(line, projection.total - 1)

    case fold_containing(projection.folds, line, 0, tuple_size(projection.folds) - 1) do
      nil -> line
      {first, _, _} -> first
    end
  end

  @doc "Returns a bounded window of source groups, skipping the interiors of closed folds."
  @spec source_window(projection(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          [group()]
  def source_window(projection, line, before, after_count) do
    line = visible_source(projection, line)
    preceding = previous_groups(projection, line, before, [])
    acc = next_groups(projection, line, after_count + 1, Enum.reverse(preceding))
    Enum.reverse(acc)
  end

  defp previous_groups(_projection, _line, 0, acc), do: acc
  defp previous_groups(_projection, 0, _count, acc), do: acc

  defp previous_groups(projection, line, count, acc) do
    previous = visible_source(projection, line - 1)
    {group, _next} = group_at(projection, previous)
    previous_groups(projection, previous, count - 1, [group | acc])
  end

  defp next_groups(_projection, _line, 0, acc), do: acc
  defp next_groups(%{total: total}, line, _count, acc) when line >= total, do: acc

  defp next_groups(projection, line, count, acc) do
    {group, next} = group_at(projection, line)
    next_groups(projection, next, count - 1, [group | acc])
  end

  @doc "Resolves a page, optionally moving by visual rows or following a source cursor."
  @spec visual_page(
          [group()],
          FoldMap.t(),
          Viewport.t(),
          sources(),
          integer() | {non_neg_integer(), non_neg_integer(), non_neg_integer()}
        ) :: {t(), Viewport.t(), boolean()}
  def visual_page(groups, fold_map, viewport, sources, motion) do
    wrap_count = fn line -> sources |> Map.fetch!(line) |> elem(4) end

    {groups, indexed, viewport, at_bottom?} =
      visual_anchor(groups, fold_map, viewport, wrap_count, motion)

    entries =
      visual_entries(
        groups,
        indexed.top,
        indexed.visual_row_offset,
        Viewport.content_rows(viewport),
        wrap_count,
        []
      )

    {%__MODULE__{entries: entries, sources: sources}, viewport, at_bottom?}
  end

  @doc "Resolves wheel bounds from exact counts without constructing render entries."
  @spec visual_scroll(
          [group()],
          FoldMap.t(),
          Viewport.t(),
          %{non_neg_integer() => pos_integer()},
          integer()
        ) :: {Viewport.t(), boolean()}
  def visual_scroll(groups, fold_map, viewport, counts, delta) do
    {_, _, viewport, at_bottom?} =
      visual_anchor(groups, fold_map, viewport, &Map.fetch!(counts, &1), delta)

    {viewport, at_bottom?}
  end

  defp visual_anchor(groups, fold_map, viewport, wrap_count, motion) do
    top = FoldMap.visible_to_buffer(fold_map, viewport.top)
    top_index = Enum.find_index(groups, fn {line, _, _, _} -> line > top end)
    top_index = if top_index, do: max(top_index - 1, 0), else: length(groups) - 1
    groups = List.to_tuple(groups)

    count = fn index ->
      {line, kind, above, below} = elem(groups, index)
      length(above) + source_count(kind, line, wrap_count) + length(below)
    end

    {line, kind, above, below} = elem(groups, top_index)

    offset =
      if line == top,
        do: display_offset(viewport, length(above), source_count(kind, line, wrap_count), below),
        else: 0

    indexed = Viewport.put_top_visual(viewport, top_index, offset, count.(top_index))
    delta = visual_delta(motion, indexed, groups, count)
    {indexed, at_bottom?} = Viewport.scroll_visual_rows(indexed, delta, tuple_size(groups), count)
    {line, kind, above, _below} = elem(groups, indexed.top)
    start = indexed.visual_row_offset
    top = FoldMap.buffer_to_visible(fold_map, line)

    viewport =
      store_anchor(viewport, top, start, length(above), source_count(kind, line, wrap_count))

    {groups, indexed, viewport, at_bottom?}
  end

  defp display_offset(%Viewport{mixed_row_anchor: :source_head}, above, _wraps, _below),
    do: above

  defp display_offset(%Viewport{mixed_row_anchor: {:above, row}}, above, _wraps, _below),
    do: min(row, above)

  defp display_offset(%Viewport{mixed_row_anchor: {:below, row}}, above, wraps, below),
    do: above + wraps + min(row, length(below) - 1)

  defp display_offset(%Viewport{visual_row_offset: 0}, _above, _wraps, _below), do: 0

  defp display_offset(%Viewport{visual_row_offset: offset}, above, wraps, _below),
    do: above + min(offset, wraps - 1)

  # Keep the numeric projection for scroll and cache consumers. Only the tagged address
  # is used to recover special rows after the group's decoration or wrap counts change.
  defp store_anchor(viewport, top, 0, _above, _wraps), do: Viewport.put_top(viewport, top)

  defp store_anchor(viewport, top, row, above, wraps) when row < above,
    do: Viewport.put_top_mixed(viewport, top, {:above, row}, wraps + row - 1)

  defp store_anchor(viewport, top, row, above, wraps) when row == above,
    do: Viewport.put_top_mixed(viewport, top, :source_head, wraps + row - 1)

  defp store_anchor(viewport, top, row, above, wraps) when row < above + wraps,
    do: Viewport.put_top_visual(viewport, top, row - above, wraps)

  defp store_anchor(viewport, top, row, above, wraps),
    do: Viewport.put_top_mixed(viewport, top, {:below, row - above - wraps}, row)

  defp visual_delta(delta, _viewport, _groups, _count) when is_integer(delta), do: delta

  defp visual_delta({cursor_line, segment, margin}, viewport, groups, count) do
    cursor = cursor_rank(groups, cursor_line, segment, count, 0, 0)
    current = row_rank(viewport.top, count, viewport.visual_row_offset)
    rows = Viewport.content_rows(viewport)
    margin = min(margin, div(rows - 1, 2))

    case cursor - current do
      relative when relative < margin -> relative - margin
      relative when relative >= rows - margin -> relative - rows + margin + 1
      _ -> 0
    end
  end

  defp cursor_rank(groups, line, segment, count, index, rank) do
    {source, kind, above, _below} = elem(groups, index)

    if source == line do
      rank + length(above) + if(kind == :normal, do: segment, else: 0)
    else
      cursor_rank(groups, line, segment, count, index + 1, rank + count.(index))
    end
  end

  defp row_rank(0, _count, acc), do: acc
  defp row_rank(index, count, acc), do: row_rank(index - 1, count, acc + count.(index - 1))

  defp visual_entries(_groups, _index, _skip, 0, _count, acc), do: Enum.reverse(acc)

  defp visual_entries(groups, index, _skip, _rows, _count, acc) when index == tuple_size(groups),
    do: Enum.reverse(acc)

  defp visual_entries(groups, index, skip, rows, count, acc) do
    {line, kind, above, below} = elem(groups, index)
    {acc, skip, rows} = take_special(above, line, skip, rows, acc)
    {acc, skip, rows} = take_source(line, kind, source_count(kind, line, count), skip, rows, acc)
    {acc, _skip, rows} = take_special(below, line, skip, rows, acc)
    visual_entries(groups, index + 1, 0, rows, count, acc)
  end

  defp source_count(:normal, line, count), do: count.(line)
  defp source_count(_fold, _line, _count), do: 1

  defp take_source(_line, _kind, count, skip, rows, acc) when skip >= count,
    do: {acc, skip - count, rows}

  defp take_source(_line, _kind, _count, skip, 0, acc), do: {acc, skip, 0}

  defp take_source(line, :normal, count, skip, rows, acc) do
    take = min(count - skip, rows)
    acc = Enum.reduce(skip..(skip + take - 1), acc, &[{line, {:wrapped, &1}} | &2])
    {acc, 0, rows - take}
  end

  defp take_source(line, fold, 1, 0, rows, acc), do: {[{line, fold} | acc], 0, rows - 1}

  defp take_special([], _line, skip, rows, acc), do: {acc, skip, rows}
  defp take_special(_special, _line, skip, 0, acc), do: {acc, skip, 0}

  defp take_special([_ | rest], line, skip, rows, acc) when skip > 0,
    do: take_special(rest, line, skip - 1, rows, acc)

  defp take_special([entry | rest], line, 0, rows, acc),
    do: take_special(rest, line, 0, rows - 1, [{line, entry} | acc])

  defp unwrapped_entries(_projection, _line, 0, acc), do: Enum.reverse(acc)

  defp unwrapped_entries(%{total: total}, line, _rows, acc) when line >= total,
    do: Enum.reverse(acc)

  defp unwrapped_entries(projection, line, rows, acc) do
    {{^line, kind, above, below}, next} = group_at(projection, line)
    {acc, _, rows} = take_special(above, line, 0, rows, acc)

    if rows == 0 do
      Enum.reverse(acc)
    else
      {acc, _, rows} = take_special(below, line, 0, rows - 1, [{line, kind} | acc])
      unwrapped_entries(projection, next, rows, acc)
    end
  end

  @spec group_at(projection(), non_neg_integer()) :: {group(), pos_integer()}
  defp group_at(projection, line) do
    {above_vts, below_vts} = Decorations.virtual_lines_for_line(projection.decorations, line)
    {above_blocks, below_blocks} = Decorations.blocks_for_line(projection.decorations, line)

    above = block_rows(above_blocks, projection.width) ++ virtual_rows(above_vts)
    below = virtual_rows(below_vts) ++ block_rows(below_blocks, projection.width)

    {kind, next} =
      case fold_containing(projection.folds, line, 0, tuple_size(projection.folds) - 1) do
        {^line, last, fold} -> {fold, last + 1}
        nil -> {:normal, line + 1}
      end

    {{line, kind, above, below}, next}
  end

  defp virtual_rows(virtual_texts), do: Enum.map(virtual_texts, &{:virtual_line, &1})

  defp block_rows(blocks, width) do
    for block <- blocks, index <- 0..(BlockDecoration.resolve_height(block, width) - 1) do
      {:block, block, index}
    end
  end

  defp fold_containing(_folds, _line, low, high) when low > high, do: nil

  defp fold_containing(folds, line, low, high) do
    index = div(low + high, 2)

    case elem(folds, index) do
      {start, _, _} when line < start -> fold_containing(folds, line, low, index - 1)
      {_, last, _} when line > last -> fold_containing(folds, line, index + 1, high)
      fold -> fold
    end
  end
end
