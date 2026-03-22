defmodule Minga.Buffer.Decorations do
  @moduledoc """
  Buffer decoration storage and API.

  Stores highlight ranges and virtual text (and later, fold regions and block
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

  alias Minga.Buffer.Decorations.BlockDecoration
  alias Minga.Buffer.Decorations.ConcealRange
  alias Minga.Buffer.Decorations.FoldRegion
  alias Minga.Buffer.Decorations.HighlightRange
  alias Minga.Buffer.Decorations.LineAnnotation
  alias Minga.Buffer.Decorations.VirtualText
  alias Minga.Buffer.IntervalTree
  alias Minga.Face

  @mergeable_style_fields [
    :fg,
    :bg,
    :bold,
    :italic,
    :underline,
    :underline_style,
    :underline_color,
    :strikethrough,
    :reverse,
    :blend
  ]

  @typedoc "A position used in highlight range start/end."
  @type highlight_range_pos :: IntervalTree.position()

  @typedoc "A color value: 24-bit RGB integer."
  @type color :: non_neg_integer()

  @typedoc """
  Style for a highlight range: a Face struct where nil fields
  inherit from the underlying syntax style.
  """
  @type style :: Face.t()

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
  - `virtual_texts`: list of virtual text decorations (queried by line, not range)
  - `annotations`: list of line annotations (pill badges, inline text, gutter icons)
  - `fold_regions`: list of buffer-level fold regions (per-buffer, not per-window)
  - `block_decorations`: list of block decorations (custom-rendered lines between buffer lines)
  - `conceal_ranges`: list of conceal ranges (hidden buffer text with optional replacement)
  - `pending`: list of pending operations during a batch (nil when not batching)
  - `version`: monotonically increasing version for change detection by the render pipeline
  """
  @type t :: %__MODULE__{
          highlights: IntervalTree.t(),
          virtual_texts: [VirtualText.t()],
          annotations: [LineAnnotation.t()],
          fold_regions: [FoldRegion.t()],
          block_decorations: [BlockDecoration.t()],
          conceal_ranges: [ConcealRange.t()],
          pending:
            [{:add, highlight_range()} | {:remove, reference()} | {:remove_group, term()}] | nil,
          version: non_neg_integer(),
          vt_line_cache: %{non_neg_integer() => [VirtualText.t()]} | nil,
          ann_line_cache: %{non_neg_integer() => [LineAnnotation.t()]} | nil
        }

  @enforce_keys []
  defstruct highlights: nil,
            virtual_texts: [],
            annotations: [],
            fold_regions: [],
            block_decorations: [],
            conceal_ranges: [],
            pending: nil,
            version: 0,
            vt_line_cache: nil,
            ann_line_cache: nil

  # ── Construction ─────────────────────────────────────────────────────────

  @doc "Creates an empty decorations store."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # ── Highlight range API ──────────────────────────────────────────────────

  @doc """
  Adds a highlight range. Returns `{id, updated_decorations}`.

  ## Options

  - `:style` (required) - a `Face.t()` struct with the properties to apply (e.g., `Face.new(bg: 0x3E4452, bold: true)`)
  - `:priority` (optional, default 0) - higher values win per-property on overlap
  - `:group` (optional) - atom for bulk removal (e.g., `:search`, `:diagnostics`)

  ## Examples

      {id, decs} = Decorations.add_highlight(decs, {0, 0}, {0, 10}, style: Face.new(bg: 0x3E4452))
      {id, decs} = Decorations.add_highlight(decs, {5, 0}, {10, 0},
        style: Face.new(underline: true, fg: 0xFF6C6B),
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
  Removes all decorations belonging to the given group across all types.

  Clears highlight ranges, virtual texts, block decorations, fold regions,
  and conceal ranges that have a matching `:group` field. This is the
  correct way for a decoration consumer (e.g., agent chat, search, LSP)
  to clear its own decorations without affecting other consumers.

  The `group` parameter is typed as `term()` to support structured keys
  like `{:lsp, server_id}` in the future.
  """
  @spec remove_group(t(), term()) :: t()
  def remove_group(%__MODULE__{pending: pending} = decs, group) when pending != nil do
    # During a batch, defer highlight removal to pending (processed by apply_pending).
    # But immediately remove non-highlight types since they don't participate
    # in the pending queue system.
    %{
      decs
      | pending: [{:remove_group, group} | pending],
        virtual_texts: Enum.reject(decs.virtual_texts, &(&1.group == group)),
        annotations: Enum.reject(decs.annotations, &(&1.group == group)),
        block_decorations: Enum.reject(decs.block_decorations, &(&1.group == group)),
        fold_regions: Enum.reject(decs.fold_regions, &(&1.group == group)),
        conceal_ranges: Enum.reject(decs.conceal_ranges, &(&1.group == group)),
        vt_line_cache: nil,
        ann_line_cache: nil
    }
  end

  def remove_group(%__MODULE__{} = decs, group) do
    new_highlights =
      IntervalTree.map_filter(decs.highlights, &filter_group(&1, group))

    new_virtual_texts = Enum.reject(decs.virtual_texts, &(&1.group == group))
    new_annotations = Enum.reject(decs.annotations, &(&1.group == group))
    new_blocks = Enum.reject(decs.block_decorations, &(&1.group == group))
    new_folds = Enum.reject(decs.fold_regions, &(&1.group == group))
    new_conceals = Enum.reject(decs.conceal_ranges, &(&1.group == group))

    %{
      decs
      | highlights: new_highlights,
        virtual_texts: new_virtual_texts,
        annotations: new_annotations,
        block_decorations: new_blocks,
        fold_regions: new_folds,
        conceal_ranges: new_conceals,
        version: decs.version + 1,
        vt_line_cache: nil,
        ann_line_cache: nil
    }
  end

  @spec filter_group(IntervalTree.interval(), term()) ::
          {:keep, IntervalTree.interval()} | :remove
  defp filter_group(interval, group) do
    if interval.value.group == group, do: :remove, else: {:keep, interval}
  end

  @doc """
  Removes all decorations. Returns a fresh empty store with bumped version.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = decs) do
    %__MODULE__{version: decs.version + 1, pending: decs.pending}
  end

  # ── Virtual text API ──────────────────────────────────────────────────────

  @doc """
  Adds a virtual text decoration to the buffer. Returns `{id, updated_decorations}`.

  ## Options

  - `:segments` (required) - list of `{text, Face.t()}` tuples
  - `:placement` (required) - `:inline`, `:eol`, `:above`, or `:below`
  - `:priority` (optional, default 0) - determines ordering when multiple
    virtual texts share the same anchor

  ## Examples

      {id, decs} = Decorations.add_virtual_text(decs, {5, 10},
        segments: [{"← error here", Face.new(fg: 0xFF6C6B, italic: true)}],
        placement: :eol
      )

      {id, decs} = Decorations.add_virtual_text(decs, {0, 0},
        segments: [{"▎ Agent", Face.new(fg: 0x51AFEF, bold: true)}],
        placement: :above
      )
  """
  @spec add_virtual_text(t(), IntervalTree.position(), keyword()) :: {reference(), t()}
  def add_virtual_text(%__MODULE__{} = decs, anchor, opts) do
    id = make_ref()

    vt = %VirtualText{
      id: id,
      anchor: anchor,
      segments: Keyword.fetch!(opts, :segments),
      placement: Keyword.fetch!(opts, :placement),
      priority: Keyword.get(opts, :priority, 0),
      group: Keyword.get(opts, :group)
    }

    new_vts = [vt | decs.virtual_texts]
    {id, %{decs | virtual_texts: new_vts, version: decs.version + 1, vt_line_cache: nil}}
  end

  @doc "Removes a virtual text decoration by ID."
  @spec remove_virtual_text(t(), reference()) :: t()
  def remove_virtual_text(%__MODULE__{} = decs, id) do
    new_vts = Enum.reject(decs.virtual_texts, fn vt -> vt.id == id end)

    if length(new_vts) == length(decs.virtual_texts) do
      decs
    else
      %{decs | virtual_texts: new_vts, version: decs.version + 1, vt_line_cache: nil}
    end
  end

  # ── Virtual text queries ─────────────────────────────────────────────────

  @doc """
  Returns all virtual text decorations anchored to a specific line,
  sorted by column then priority.
  """
  @spec virtual_texts_for_line(t(), non_neg_integer()) :: [VirtualText.t()]
  def virtual_texts_for_line(%__MODULE__{vt_line_cache: cache}, line) when cache != nil do
    Map.get(cache, line, [])
  end

  def virtual_texts_for_line(%__MODULE__{virtual_texts: vts}, line) do
    vts
    |> Enum.filter(fn %VirtualText{anchor: {l, _c}} -> l == line end)
    |> Enum.sort_by(fn %VirtualText{anchor: {_l, c}, priority: p} -> {c, p} end)
  end

  @doc """
  Builds the virtual text line cache.

  Call this once before a render pass to get O(1) per-line lookups.
  Returns an updated Decorations struct with the cache populated.
  The cache is invalidated on any mutation (add, remove, adjust).
  """
  @spec build_vt_line_cache(t()) :: t()
  def build_vt_line_cache(%__MODULE__{vt_line_cache: cache} = decs) when cache != nil, do: decs

  def build_vt_line_cache(%__MODULE__{virtual_texts: []} = decs) do
    %{decs | vt_line_cache: %{}}
  end

  def build_vt_line_cache(%__MODULE__{virtual_texts: vts} = decs) do
    cache =
      vts
      |> Enum.group_by(fn %VirtualText{anchor: {l, _c}} -> l end)
      |> Map.new(fn {line, line_vts} ->
        sorted =
          Enum.sort_by(line_vts, fn %VirtualText{anchor: {_l, c}, priority: p} -> {c, p} end)

        {line, sorted}
      end)

    %{decs | vt_line_cache: cache}
  end

  @doc """
  Returns inline virtual texts for a specific line, sorted by column then priority.
  """
  @spec inline_virtual_texts_for_line(t(), non_neg_integer()) :: [VirtualText.t()]
  def inline_virtual_texts_for_line(%__MODULE__{} = decs, line) do
    decs
    |> virtual_texts_for_line(line)
    |> Enum.filter(fn %VirtualText{placement: p} -> p == :inline end)
  end

  @doc """
  Returns EOL virtual texts for a specific line, sorted by priority.
  """
  @spec eol_virtual_texts_for_line(t(), non_neg_integer()) :: [VirtualText.t()]
  def eol_virtual_texts_for_line(%__MODULE__{} = decs, line) do
    decs
    |> virtual_texts_for_line(line)
    |> Enum.filter(fn %VirtualText{placement: p} -> p == :eol end)
  end

  @doc """
  Returns virtual lines (`:above` or `:below`) anchored to a specific line.
  Returns `{above, below}` tuple, each sorted by priority.
  """
  @spec virtual_lines_for_line(t(), non_neg_integer()) ::
          {above :: [VirtualText.t()], below :: [VirtualText.t()]}
  def virtual_lines_for_line(%__MODULE__{} = decs, line) do
    line_vts = virtual_texts_for_line(decs, line)
    above = Enum.filter(line_vts, fn %VirtualText{placement: p} -> p == :above end)
    below = Enum.filter(line_vts, fn %VirtualText{placement: p} -> p == :below end)
    {above, below}
  end

  @doc """
  Returns true if there are any virtual texts of any placement.
  """
  @spec has_virtual_texts?(t()) :: boolean()
  def has_virtual_texts?(%__MODULE__{virtual_texts: []}), do: false
  def has_virtual_texts?(%__MODULE__{}), do: true

  @doc """
  Returns the count of virtual lines (`:above` and `:below`) in the given
  line range. Used by viewport scroll calculations.
  """
  @spec virtual_line_count(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def virtual_line_count(%__MODULE__{virtual_texts: []}, _start_line, _end_line), do: 0

  def virtual_line_count(%__MODULE__{virtual_texts: vts}, start_line, end_line) do
    Enum.count(vts, fn %VirtualText{anchor: {line, _}, placement: p} ->
      line >= start_line and line <= end_line and p in [:above, :below]
    end)
  end

  # ── Fold region API ──────────────────────────────────────────────────────

  @doc """
  Adds a buffer-level fold region. Returns `{id, updated_decorations}`.

  ## Options

  - `:closed` (optional, default true) - initial fold state
  - `:placeholder` (optional) - render callback `(start_line, end_line, width) -> [{text, style}]`

  ## Examples

      {id, decs} = Decorations.add_fold_region(decs, 10, 25,
        closed: true,
        placeholder: fn s, e, _w -> [{"💭 Thinking (\#{e - s} lines)...", [fg: 0x555555]}] end
      )
  """
  @spec add_fold_region(t(), non_neg_integer(), non_neg_integer(), keyword()) ::
          {reference(), t()}
  def add_fold_region(decs, start_line, end_line, opts \\ [])

  # Single-line range has nothing to fold; return unchanged.
  def add_fold_region(%__MODULE__{} = decs, line, line, _opts) when is_integer(line) do
    {make_ref(), decs}
  end

  def add_fold_region(%__MODULE__{} = decs, start_line, end_line, opts)
      when start_line < end_line do
    id = make_ref()

    fold = %FoldRegion{
      id: id,
      start_line: start_line,
      end_line: end_line,
      closed: Keyword.get(opts, :closed, true),
      placeholder: Keyword.get(opts, :placeholder),
      group: Keyword.get(opts, :group)
    }

    {id, %{decs | fold_regions: [fold | decs.fold_regions], version: decs.version + 1}}
  end

  @doc "Removes a fold region by ID."
  @spec remove_fold_region(t(), reference()) :: t()
  def remove_fold_region(%__MODULE__{} = decs, id) do
    new_folds = Enum.reject(decs.fold_regions, fn f -> f.id == id end)

    if length(new_folds) == length(decs.fold_regions) do
      decs
    else
      %{decs | fold_regions: new_folds, version: decs.version + 1}
    end
  end

  @doc "Toggles a fold region's open/closed state by ID."
  @spec toggle_fold_region(t(), reference()) :: t()
  def toggle_fold_region(%__MODULE__{} = decs, id) do
    new_folds =
      Enum.map(decs.fold_regions, fn fold ->
        if fold.id == id, do: %{fold | closed: not fold.closed}, else: fold
      end)

    %{decs | fold_regions: new_folds, version: decs.version + 1}
  end

  @doc "Returns the fold region containing the given line, or nil."
  @spec fold_region_at(t(), non_neg_integer()) :: FoldRegion.t() | nil
  def fold_region_at(%__MODULE__{fold_regions: folds}, line) do
    Enum.find(folds, fn fold -> FoldRegion.contains?(fold, line) end)
  end

  @doc "Returns all closed fold regions, sorted by start_line."
  @spec closed_fold_regions(t()) :: [FoldRegion.t()]
  def closed_fold_regions(%__MODULE__{fold_regions: folds}) do
    folds
    |> Enum.filter(fn f -> f.closed end)
    |> Enum.sort_by(fn f -> f.start_line end)
  end

  @doc "Returns true if there are any fold regions."
  @spec has_fold_regions?(t()) :: boolean()
  def has_fold_regions?(%__MODULE__{fold_regions: []}), do: false
  def has_fold_regions?(%__MODULE__{}), do: true

  # ── Block decoration API ─────────────────────────────────────────────────

  @doc """
  Adds a block decoration to the buffer. Returns `{id, updated_decorations}`.

  ## Options

  - `:placement` (required) - `:above` or `:below` the anchor line
  - `:render` (required) - callback `(width -> [{text, style}] | [[{text, style}]])`
  - `:height` (optional, default 1) - number of display lines, or `:dynamic`
  - `:on_click` (optional) - callback `(row, col) -> :ok` for interactive blocks
  - `:priority` (optional, default 0) - ordering when multiple blocks share an anchor
  """
  @spec add_block_decoration(t(), non_neg_integer(), keyword()) :: {reference(), t()}
  def add_block_decoration(%__MODULE__{} = decs, anchor_line, opts) do
    id = make_ref()

    block = %BlockDecoration{
      id: id,
      anchor_line: anchor_line,
      placement: Keyword.fetch!(opts, :placement),
      render: Keyword.fetch!(opts, :render),
      height: Keyword.get(opts, :height, 1),
      on_click: Keyword.get(opts, :on_click),
      priority: Keyword.get(opts, :priority, 0),
      group: Keyword.get(opts, :group)
    }

    new_blocks = [block | decs.block_decorations]
    {id, %{decs | block_decorations: new_blocks, version: decs.version + 1}}
  end

  @doc "Removes a block decoration by ID."
  @spec remove_block_decoration(t(), reference()) :: t()
  def remove_block_decoration(%__MODULE__{} = decs, id) do
    new_blocks = Enum.reject(decs.block_decorations, fn b -> b.id == id end)

    if length(new_blocks) == length(decs.block_decorations) do
      decs
    else
      %{decs | block_decorations: new_blocks, version: decs.version + 1}
    end
  end

  @doc """
  Returns block decorations for a specific anchor line, sorted by priority.
  Returns `{above, below}` tuple.
  """
  @spec blocks_for_line(t(), non_neg_integer()) ::
          {above :: [BlockDecoration.t()], below :: [BlockDecoration.t()]}
  def blocks_for_line(%__MODULE__{block_decorations: []}, _line), do: {[], []}

  def blocks_for_line(%__MODULE__{block_decorations: blocks}, line) do
    line_blocks =
      blocks
      |> Enum.filter(fn b -> b.anchor_line == line end)
      |> Enum.sort_by(fn b -> b.priority end)

    above = Enum.filter(line_blocks, fn b -> b.placement == :above end)
    below = Enum.filter(line_blocks, fn b -> b.placement == :below end)
    {above, below}
  end

  @doc "Returns true if there are any block decorations."
  @spec has_block_decorations?(t()) :: boolean()
  def has_block_decorations?(%__MODULE__{block_decorations: []}), do: false
  def has_block_decorations?(%__MODULE__{}), do: true

  @doc "Returns the block decoration with the given ID, or nil."
  @spec block_decoration_by_id(t(), reference()) :: BlockDecoration.t() | nil
  def block_decoration_by_id(%__MODULE__{block_decorations: blocks}, id) do
    Enum.find(blocks, fn b -> b.id == id end)
  end

  # ── Conceal range API ─────────────────────────────────────────────────────

  @doc """
  Adds a conceal range. Returns `{id, updated_decorations}`.

  Concealed text is hidden from the display without modifying the buffer.
  When a replacement string is provided, the entire concealed range is
  shown as that single replacement character.

  ## Options

  - `:replacement` (optional) - string to show in place of concealed text (nil = invisible)
  - `:replacement_style` (optional) - Face.t() struct for the replacement character
  - `:priority` (optional, default 0) - higher values take precedence on overlap
  - `:group` (optional) - atom for bulk removal (e.g., `:markdown`, `:agent`)

  ## Examples

      {id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2})
      {id, decs} = Decorations.add_conceal(decs, {0, 0}, {0, 2},
        replacement: "·",
        group: :markdown
      )
  """
  @spec add_conceal(t(), IntervalTree.position(), IntervalTree.position(), keyword()) ::
          {reference(), t()}
  def add_conceal(%__MODULE__{} = decs, start_pos, end_pos, opts \\ []) do
    id = make_ref()

    range = %ConcealRange{
      id: id,
      start_pos: start_pos,
      end_pos: end_pos,
      replacement: Keyword.get(opts, :replacement),
      replacement_style: Keyword.get(opts, :replacement_style, Face.new()),
      priority: Keyword.get(opts, :priority, 0),
      group: Keyword.get(opts, :group)
    }

    {id, %{decs | conceal_ranges: [range | decs.conceal_ranges], version: decs.version + 1}}
  end

  @doc "Removes a conceal range by ID."
  @spec remove_conceal(t(), reference()) :: t()
  def remove_conceal(%__MODULE__{} = decs, id) do
    new_conceals = Enum.reject(decs.conceal_ranges, fn c -> c.id == id end)

    if length(new_conceals) == length(decs.conceal_ranges) do
      decs
    else
      %{decs | conceal_ranges: new_conceals, version: decs.version + 1}
    end
  end

  @doc "Removes all conceal ranges belonging to a group."
  @spec remove_conceal_group(t(), atom()) :: t()
  def remove_conceal_group(%__MODULE__{} = decs, group) when is_atom(group) do
    new_conceals = Enum.reject(decs.conceal_ranges, fn c -> c.group == group end)

    if length(new_conceals) == length(decs.conceal_ranges) do
      decs
    else
      %{decs | conceal_ranges: new_conceals, version: decs.version + 1}
    end
  end

  @doc "Returns true if there are any conceal ranges."
  @spec has_conceal_ranges?(t()) :: boolean()
  def has_conceal_ranges?(%__MODULE__{conceal_ranges: []}), do: false
  def has_conceal_ranges?(%__MODULE__{}), do: true

  @doc """
  Returns conceal ranges that intersect the given line, sorted by start column.

  Used by the rendering pipeline to know which graphemes to skip during
  the line rendering walk.
  """
  @spec conceals_for_line(t(), non_neg_integer()) :: [ConcealRange.t()]
  def conceals_for_line(%__MODULE__{conceal_ranges: []}, _line), do: []

  def conceals_for_line(%__MODULE__{conceal_ranges: ranges}, line) do
    ranges
    |> Enum.filter(fn c -> ConcealRange.spans_line?(c, line) end)
    |> Enum.sort_by(fn %ConcealRange{start_pos: {sl, sc}} ->
      if sl < line, do: 0, else: sc
    end)
    |> merge_overlapping_conceals(line)
  end

  # Merges overlapping conceal ranges into non-overlapping output.
  # Ranges are already sorted by effective start column. When ranges overlap,
  # the higher-priority conceal's replacement wins. On tie, the first range wins.
  @spec merge_overlapping_conceals([ConcealRange.t()], non_neg_integer()) :: [ConcealRange.t()]
  defp merge_overlapping_conceals([], _line), do: []
  defp merge_overlapping_conceals([single], _line), do: [single]

  defp merge_overlapping_conceals([first | rest], line) do
    {merged, current} =
      Enum.reduce(rest, {[], first}, fn next, {acc, current} ->
        curr_end = effective_end_col(current, line)
        next_start = effective_start_col(next, line)

        if next_start < curr_end do
          # Overlap: merge into current, higher priority replacement wins
          merged = merge_two_conceals(current, next, line)
          {acc, merged}
        else
          # No overlap: emit current, advance to next
          {[current | acc], next}
        end
      end)

    Enum.reverse([current | merged])
  end

  defp merge_two_conceals(a, b, line) do
    # Union of the two ranges: min start, max end
    a_start = effective_start_col(a, line)
    b_start = effective_start_col(b, line)
    a_end = effective_end_col(a, line)
    b_end = effective_end_col(b, line)

    new_start_col = min(a_start, b_start)
    new_end_col = max(a_end, b_end)

    # Higher priority replacement wins; on tie, keep the earlier range's replacement
    winner = if b.priority > a.priority, do: b, else: a

    %ConcealRange{
      id: winner.id,
      start_pos: {line, new_start_col},
      end_pos: {line, new_end_col},
      replacement: winner.replacement,
      replacement_style: winner.replacement_style,
      priority: max(a.priority, b.priority),
      group: winner.group
    }
  end

  defp effective_start_col(%ConcealRange{start_pos: {sl, sc}}, line) do
    if sl < line, do: 0, else: sc
  end

  # For multi-line conceals extending past this line, use a large sentinel
  # value rather than :infinity to keep arithmetic safe in merge_two_conceals.
  @max_col 1_000_000
  defp effective_end_col(%ConcealRange{end_pos: {el, ec}}, line) do
    if el > line, do: @max_col, else: ec
  end

  # ── Line annotation API ────────────────────────────────────────────────────

  @doc """
  Adds a line annotation to the buffer. Returns `{id, updated_decorations}`.

  ## Options

  - `:kind` (optional, default `:inline_pill`) - `:inline_pill`, `:inline_text`, or `:gutter_icon`
  - `:fg` (optional, default `0xFFFFFF`) - foreground color (24-bit RGB)
  - `:bg` (optional, default `0x6366F1`) - background color (24-bit RGB)
  - `:group` (optional) - atom for bulk removal (e.g., `:org_tags`, `:agent`)
  - `:priority` (optional, default 0) - ordering when multiple annotations share a line

  ## Examples

      {id, decs} = Decorations.add_annotation(decs, 5, "work",
        kind: :inline_pill, fg: 0xFFFFFF, bg: 0x6366F1, group: :org_tags)

      {id, decs} = Decorations.add_annotation(decs, 10, "J. Smith, 2d ago",
        kind: :inline_text, fg: 0x888888, group: :git_blame)
  """
  @spec add_annotation(t(), non_neg_integer(), String.t(), keyword()) :: {reference(), t()}
  def add_annotation(%__MODULE__{} = decs, line, text, opts \\ [])
      when is_integer(line) and line >= 0 and is_binary(text) do
    id = make_ref()

    ann = %LineAnnotation{
      id: id,
      line: line,
      text: text,
      kind: Keyword.get(opts, :kind, :inline_pill),
      fg: Keyword.get(opts, :fg, 0xFFFFFF),
      bg: Keyword.get(opts, :bg, 0x6366F1),
      group: Keyword.get(opts, :group),
      priority: Keyword.get(opts, :priority, 0)
    }

    new_anns = [ann | decs.annotations]
    {id, %{decs | annotations: new_anns, version: decs.version + 1, ann_line_cache: nil}}
  end

  @doc "Removes a line annotation by ID."
  @spec remove_annotation(t(), reference()) :: t()
  def remove_annotation(%__MODULE__{} = decs, id) do
    case Enum.split_with(decs.annotations, fn ann -> ann.id == id end) do
      {[], _} ->
        decs

      {_, remaining} ->
        %{decs | annotations: remaining, version: decs.version + 1, ann_line_cache: nil}
    end
  end

  # ── Line annotation queries ──────────────────────────────────────────────

  @doc """
  Returns all annotations for a specific line, sorted by priority.
  """
  @spec annotations_for_line(t(), non_neg_integer()) :: [LineAnnotation.t()]
  def annotations_for_line(%__MODULE__{ann_line_cache: cache}, line) when cache != nil do
    Map.get(cache, line, [])
  end

  def annotations_for_line(%__MODULE__{annotations: anns}, line) do
    anns
    |> Enum.filter(fn %LineAnnotation{line: l} -> l == line end)
    |> Enum.sort_by(fn %LineAnnotation{priority: p} -> p end)
  end

  @doc """
  Builds the annotation line cache for O(1) per-line lookups.

  Call once before a render pass. The cache is invalidated on any
  annotation mutation.
  """
  @spec build_ann_line_cache(t()) :: t()
  def build_ann_line_cache(%__MODULE__{ann_line_cache: cache} = decs) when cache != nil, do: decs

  def build_ann_line_cache(%__MODULE__{annotations: []} = decs) do
    %{decs | ann_line_cache: %{}}
  end

  def build_ann_line_cache(%__MODULE__{annotations: anns} = decs) do
    cache =
      anns
      |> Enum.group_by(fn %LineAnnotation{line: l} -> l end)
      |> Map.new(fn {line, line_anns} ->
        sorted = Enum.sort_by(line_anns, fn %LineAnnotation{priority: p} -> p end)
        {line, sorted}
      end)

    %{decs | ann_line_cache: cache}
  end

  @doc "Returns true if there are any annotations."
  @spec has_annotations?(t()) :: boolean()
  def has_annotations?(%__MODULE__{annotations: []}), do: false
  def has_annotations?(%__MODULE__{}), do: true

  # ── Column mapping (inline virtual text + conceals) ──────────────────────

  @doc """
  Converts a buffer column to a display column on the given line,
  accounting for inline virtual text that shifts content rightward
  and conceal ranges that reduce display width.

  Virtual texts anchored at or before `buf_col` add their display width
  to the result. Conceal ranges before `buf_col` subtract their concealed
  width and add replacement width (0 or 1). Virtual texts after `buf_col`
  don't affect it.
  """
  @spec buf_col_to_display_col(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def buf_col_to_display_col(
        %__MODULE__{virtual_texts: [], conceal_ranges: []} = _decs,
        _line,
        buf_col
      ),
      do: buf_col

  def buf_col_to_display_col(%__MODULE__{} = decs, line, buf_col) do
    display_col = buf_col

    # Add virtual text widths
    inline_vts = inline_virtual_texts_for_line(decs, line)
    display_col = add_virtual_widths(inline_vts, display_col)

    # Subtract conceal widths
    conceals = conceals_for_line(decs, line)
    apply_conceal_offset_to_display(conceals, line, buf_col, display_col)
  end

  @doc """
  Converts a display column to a buffer column on the given line,
  accounting for inline virtual text.

  This is the inverse of `buf_col_to_display_col/3`. Used by mouse click
  position mapping to find the correct buffer column when clicking on a
  display column that may be offset by virtual text.
  """
  @spec display_col_to_buf_col(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def display_col_to_buf_col(
        %__MODULE__{virtual_texts: [], conceal_ranges: []},
        _line,
        display_col
      ),
      do: display_col

  def display_col_to_buf_col(%__MODULE__{} = decs, line, display_col) do
    inline_vts = inline_virtual_texts_for_line(decs, line)
    buf_col = subtract_virtual_widths(inline_vts, display_col)

    # Reverse the conceal offset: a display col maps to a higher buf col
    # because concealed characters don't appear on screen.
    conceals = conceals_for_line(decs, line)
    apply_conceal_offset_to_buf(conceals, line, buf_col)
  end

  @spec add_virtual_widths([VirtualText.t()], non_neg_integer()) :: non_neg_integer()
  defp add_virtual_widths([], buf_col), do: buf_col

  defp add_virtual_widths(inline_vts, buf_col) do
    Enum.reduce(inline_vts, buf_col, fn %VirtualText{anchor: {_l, anchor_col}} = vt,
                                        display_col ->
      if anchor_col <= buf_col do
        display_col + VirtualText.display_width(vt)
      else
        display_col
      end
    end)
  end

  @spec subtract_virtual_widths([VirtualText.t()], non_neg_integer()) :: non_neg_integer()
  defp subtract_virtual_widths([], display_col), do: display_col

  defp subtract_virtual_widths(inline_vts, display_col) do
    # Walk through inline virtual texts (sorted by anchor column).
    # Track the cumulative width of virtual texts seen so far.
    # Each virtual text shifts subsequent display columns right by its width.
    {total_vt_width, result} =
      Enum.reduce_while(inline_vts, {0, nil}, fn vt, {vt_width_sum, _} ->
        classify_display_col_vs_vt(vt, vt_width_sum, display_col)
      end)

    # If we didn't halt early, click is past all virtual texts
    result || display_col - total_vt_width
  end

  # Click is before this virtual text: subtract accumulated vt width
  @spec classify_display_col_vs_vt(VirtualText.t(), non_neg_integer(), non_neg_integer()) ::
          {:halt | :cont, {non_neg_integer(), non_neg_integer() | nil}}
  defp classify_display_col_vs_vt(
         %VirtualText{anchor: {_l, anchor_col}},
         vt_width_sum,
         display_col
       )
       when display_col < anchor_col + vt_width_sum do
    {:halt, {vt_width_sum, display_col - vt_width_sum}}
  end

  # Click is ON this virtual text: snap to anchor
  defp classify_display_col_vs_vt(
         %VirtualText{anchor: {_l, anchor_col}} = vt,
         vt_width_sum,
         display_col
       ) do
    vt_w = VirtualText.display_width(vt)
    display_anchor = anchor_col + vt_width_sum

    if display_col < display_anchor + vt_w do
      {:halt, {vt_width_sum + vt_w, anchor_col}}
    else
      # Click is past this virtual text: accumulate its width
      {:cont, {vt_width_sum + vt_w, nil}}
    end
  end

  # ── Conceal column offset helpers ──────────────────────────────────────────

  # Adjusts a display column by subtracting the width of concealed ranges
  # that fall before the given buffer column. Each conceal range reduces
  # display width by (concealed_width - replacement_width).
  @spec apply_conceal_offset_to_display(
          [ConcealRange.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp apply_conceal_offset_to_display([], _line, _buf_col, display_col), do: display_col

  defp apply_conceal_offset_to_display(conceals, line, buf_col, display_col) do
    Enum.reduce(conceals, display_col, fn conceal, acc ->
      {_sl, sc} = conceal.start_pos
      {el, ec} = conceal.end_pos
      conceal_start = if elem(conceal.start_pos, 0) < line, do: 0, else: sc
      conceal_end = if el > line, do: buf_col, else: ec

      if conceal_start < buf_col do
        # How much of this conceal is before our buf_col?
        effective_end = min(conceal_end, buf_col)
        concealed_width = max(effective_end - conceal_start, 0)
        replacement_width = ConcealRange.display_width(conceal)
        acc - concealed_width + replacement_width
      else
        acc
      end
    end)
  end

  # Inverse of apply_conceal_offset_to_display: given a buf_col that was
  # derived from a display_col (after removing VT offsets), add back the
  # concealed widths to find the true buffer column.
  @spec apply_conceal_offset_to_buf([ConcealRange.t()], non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp apply_conceal_offset_to_buf([], _line, buf_col), do: buf_col

  defp apply_conceal_offset_to_buf(conceals, line, buf_col) do
    # Walk through conceals in order. Each conceal at or before the current
    # position shifts the buffer column forward by the concealed width
    # minus the replacement width. We use <= because a display_col that
    # lands where a conceal starts means the first visible character after
    # the conceal.
    Enum.reduce(conceals, buf_col, fn conceal, acc ->
      {_sl, sc} = conceal.start_pos
      {el, ec} = conceal.end_pos
      conceal_start = if elem(conceal.start_pos, 0) < line, do: 0, else: sc
      conceal_end = if el > line, do: acc, else: ec

      if conceal_start <= acc do
        concealed_width = max(conceal_end - conceal_start, 0)
        replacement_width = ConcealRange.display_width(conceal)
        acc + concealed_width - replacement_width
      else
        acc
      end
    end)
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
        {_id1, decs} = Decorations.add_highlight(decs, {0, 0}, {0, 5}, style: Face.new(bg: 0xECBE7B), group: :search)
        {_id2, decs} = Decorations.add_highlight(decs, {3, 0}, {3, 5}, style: Face.new(bg: 0xECBE7B), group: :search)
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
          {:add, highlight_range()} | {:remove, reference()} | {:remove_group, term()},
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
  def empty?(%__MODULE__{
        highlights: nil,
        virtual_texts: [],
        annotations: [],
        fold_regions: [],
        block_decorations: [],
        conceal_ranges: []
      }),
      do: true

  def empty?(%__MODULE__{
        highlights: hl,
        virtual_texts: vts,
        annotations: anns,
        fold_regions: folds,
        block_decorations: blocks,
        conceal_ranges: conceals
      }) do
    (hl == nil or IntervalTree.empty?(hl)) and vts == [] and anns == [] and folds == [] and
      blocks == [] and conceals == []
  end

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
  def adjust_for_edit(%__MODULE__{} = decs, _edit_start, _edit_end, _new_end)
      when decs.highlights == nil and decs.virtual_texts == [] and decs.annotations == [] and
             decs.fold_regions == [] and decs.block_decorations == [] and
             decs.conceal_ranges == [],
      do: decs

  def adjust_for_edit(%__MODULE__{} = decs, edit_start, edit_end, new_end) do
    {edit_end_line, edit_end_col} = edit_end
    {new_end_line, new_end_col} = new_end

    line_delta = new_end_line - edit_end_line
    col_delta = new_end_col - edit_end_col
    ctx = build_edit_ctx(edit_start, edit_end, new_end, line_delta, col_delta)

    new_highlights =
      if decs.highlights == nil do
        nil
      else
        IntervalTree.map_filter(decs.highlights, fn interval ->
          adjust_range(interval.value, interval, ctx)
        end)
      end

    new_vts = adjust_virtual_texts(decs.virtual_texts, ctx)
    new_anns = adjust_annotations(decs.annotations, ctx)
    new_folds = adjust_fold_regions(decs.fold_regions, ctx)

    new_blocks = adjust_block_decorations(decs.block_decorations, ctx)
    new_conceals = adjust_conceal_ranges(decs.conceal_ranges, ctx)

    %{
      decs
      | highlights: new_highlights,
        virtual_texts: new_vts,
        annotations: new_anns,
        fold_regions: new_folds,
        block_decorations: new_blocks,
        conceal_ranges: new_conceals,
        version: decs.version + 1,
        vt_line_cache: nil,
        ann_line_cache: nil
    }
  end

  @spec adjust_virtual_texts([VirtualText.t()], edit_ctx()) :: [VirtualText.t()]
  defp adjust_virtual_texts([], _ctx), do: []

  defp adjust_virtual_texts(vts, ctx) do
    Enum.map(vts, fn vt -> adjust_virtual_text_anchor(vt, ctx) end)
  end

  @spec adjust_virtual_text_anchor(VirtualText.t(), edit_ctx()) :: VirtualText.t()
  defp adjust_virtual_text_anchor(%VirtualText{anchor: anchor} = vt, ctx) do
    # Virtual text has a single anchor point. Shift it like a range start.
    new_anchor = adjust_anchor_position(anchor, ctx)
    %{vt | anchor: new_anchor}
  end

  # ── Annotation edit adjustment ──────────────────────────────────────────

  # Annotations are line-anchored (no column). On deletion, annotations
  # whose line falls within the deleted range are removed (a deleted line's
  # annotation is semantically void). Survivors after the edit are shifted
  # by line_delta.
  @spec adjust_annotations([LineAnnotation.t()], edit_ctx()) :: [LineAnnotation.t()]
  defp adjust_annotations([], _ctx), do: []

  defp adjust_annotations(anns, ctx) do
    {edit_start_line, _} = ctx.edit_start
    {edit_end_line, _} = ctx.edit_end

    anns
    |> Enum.reject(fn ann ->
      # Remove annotations on lines entirely within a deleted range
      ctx.is_delete and ann.line >= edit_start_line and ann.line < edit_end_line
    end)
    |> Enum.map(&shift_ann_line(&1, edit_start_line, edit_end_line, ctx.line_delta))
  end

  # After the edit: shift by line delta
  @spec shift_ann_line(LineAnnotation.t(), non_neg_integer(), non_neg_integer(), integer()) ::
          LineAnnotation.t()
  defp shift_ann_line(%LineAnnotation{line: l} = ann, _start_line, end_line, delta)
       when l > end_line do
    %{ann | line: l + delta}
  end

  # Within the edit region but not deleted: clamp to edit start
  defp shift_ann_line(%LineAnnotation{line: l} = ann, start_line, _end_line, _delta)
       when l >= start_line do
    %{ann | line: start_line}
  end

  # Before the edit: no change
  defp shift_ann_line(ann, _start_line, _end_line, _delta), do: ann

  @spec adjust_anchor_position(IntervalTree.position(), edit_ctx()) :: IntervalTree.position()
  defp adjust_anchor_position(anchor, ctx) when anchor < ctx.edit_start, do: anchor

  defp adjust_anchor_position(anchor, ctx) when anchor >= ctx.edit_end do
    shift_position(anchor, ctx.edit_end, ctx.line_delta, ctx.col_delta)
  end

  defp adjust_anchor_position(_anchor, ctx), do: ctx.new_end

  @spec adjust_conceal_ranges([ConcealRange.t()], edit_ctx()) :: [ConcealRange.t()]
  defp adjust_conceal_ranges([], _ctx), do: []

  defp adjust_conceal_ranges(conceals, ctx) do
    Enum.reduce(conceals, [], fn conceal, acc ->
      case adjust_conceal_range(conceal, ctx) do
        nil -> acc
        adjusted -> [adjusted | acc]
      end
    end)
    |> Enum.reverse()
  end

  @spec adjust_conceal_range(ConcealRange.t(), edit_ctx()) :: ConcealRange.t() | nil
  defp adjust_conceal_range(%ConcealRange{start_pos: start_pos, end_pos: end_pos} = conceal, ctx) do
    # Entirely before the edit: no change
    if end_pos <= ctx.edit_start do
      conceal
    else
      if start_pos >= ctx.edit_end do
        # Entirely after the edit: shift both endpoints
        new_start = shift_position(start_pos, ctx.edit_end, ctx.line_delta, ctx.col_delta)
        new_end = shift_position(end_pos, ctx.edit_end, ctx.line_delta, ctx.col_delta)
        %{conceal | start_pos: new_start, end_pos: new_end}
      else
        adjust_conceal_overlap(conceal, ctx)
      end
    end
  end

  # Edit overlaps the conceal range: dispatch to multi-clause handler
  @spec adjust_conceal_overlap(ConcealRange.t(), edit_ctx()) :: ConcealRange.t() | nil

  # Edit spans entire range: remove
  defp adjust_conceal_overlap(%ConcealRange{start_pos: sp, end_pos: ep}, ctx)
       when ctx.edit_start <= sp and ctx.edit_end >= ep do
    nil
  end

  # Edit overlaps start: shrink from left
  defp adjust_conceal_overlap(%ConcealRange{start_pos: sp, end_pos: ep} = conceal, ctx)
       when ctx.edit_start <= sp do
    new_end = shift_position(ep, ctx.edit_end, ctx.line_delta, ctx.col_delta)

    if ctx.edit_start >= new_end,
      do: nil,
      else: %{conceal | start_pos: ctx.edit_start, end_pos: new_end}
  end

  # Edit overlaps end: shrink from right
  defp adjust_conceal_overlap(%ConcealRange{start_pos: sp, end_pos: ep} = conceal, ctx)
       when ctx.edit_end >= ep do
    if sp >= ctx.edit_start, do: nil, else: %{conceal | end_pos: ctx.edit_start}
  end

  # Edit entirely within range: adjust end
  defp adjust_conceal_overlap(%ConcealRange{end_pos: ep} = conceal, ctx) do
    new_end = shift_position(ep, ctx.edit_end, ctx.line_delta, ctx.col_delta)
    %{conceal | end_pos: new_end}
  end

  @spec adjust_fold_regions([FoldRegion.t()], edit_ctx()) :: [FoldRegion.t()]
  @spec adjust_block_decorations([BlockDecoration.t()], edit_ctx()) :: [BlockDecoration.t()]
  defp adjust_block_decorations([], _ctx), do: []

  defp adjust_block_decorations(blocks, ctx) do
    {edit_start_line, _} = ctx.edit_start
    {edit_end_line, _} = ctx.edit_end

    Enum.map(blocks, fn block ->
      adjust_block_anchor(block, edit_start_line, edit_end_line, ctx.line_delta)
    end)
  end

  @spec adjust_block_anchor(BlockDecoration.t(), non_neg_integer(), non_neg_integer(), integer()) ::
          BlockDecoration.t()
  defp adjust_block_anchor(block, _edit_start, edit_end, line_delta)
       when block.anchor_line > edit_end do
    %{block | anchor_line: block.anchor_line + line_delta}
  end

  defp adjust_block_anchor(block, edit_start, _edit_end, _line_delta)
       when block.anchor_line < edit_start do
    block
  end

  defp adjust_block_anchor(block, edit_start, _edit_end, _line_delta) do
    # Block anchor is within the edited region: clamp to edit start
    %{block | anchor_line: edit_start}
  end

  defp adjust_fold_regions([], _ctx), do: []

  defp adjust_fold_regions(folds, ctx) do
    {edit_start_line, _} = ctx.edit_start
    {edit_end_line, _} = ctx.edit_end

    Enum.filter(folds, fn fold ->
      # Remove folds that are entirely within the deleted region
      not (ctx.is_delete and edit_start_line <= fold.start_line and edit_end_line >= fold.end_line)
    end)
    |> Enum.map(fn fold ->
      adjust_fold_lines(fold, edit_start_line, edit_end_line, ctx.line_delta, ctx.is_delete)
    end)
  end

  @spec adjust_fold_lines(
          FoldRegion.t(),
          non_neg_integer(),
          non_neg_integer(),
          integer(),
          boolean()
        ) ::
          FoldRegion.t()
  defp adjust_fold_lines(fold, _edit_start_line, edit_end_line, line_delta, _is_delete)
       when fold.start_line > edit_end_line do
    # Fold is entirely after the edit: shift both lines
    %{fold | start_line: fold.start_line + line_delta, end_line: fold.end_line + line_delta}
  end

  defp adjust_fold_lines(fold, edit_start_line, _edit_end_line, _line_delta, _is_delete)
       when fold.end_line < edit_start_line do
    # Fold is entirely before the edit: no change
    fold
  end

  defp adjust_fold_lines(fold, _edit_start_line, _edit_end_line, line_delta, _is_delete) do
    # Fold overlaps the edit: adjust end_line, clamp to valid range
    new_end = max(fold.start_line + 1, fold.end_line + line_delta)
    %{fold | end_line: new_end}
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
  @spec merge_highlights([{String.t(), Face.t()}], [highlight_range()], non_neg_integer()) ::
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
           style :: Face.t(), priority :: integer()}

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

  @spec split_and_merge_segments([{String.t(), Face.t()}], [overlay()]) ::
          [{String.t(), Face.t()}]
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

  @spec split_segment_at_boundaries(String.t(), Face.t(), non_neg_integer(), [overlay()]) ::
          [{String.t(), Face.t()}]
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

  @spec render_sub_segment([non_neg_integer()], String.t(), non_neg_integer(), Face.t(), [
          overlay()
        ]) ::
          {String.t(), Face.t()}
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
  Merges overlay face properties onto a base face.

  Only non-nil properties in the overlay override the base. This preserves
  tree-sitter syntax colors when a decoration only specifies background.
  """
  @spec merge_style_props(Face.t(), Face.t()) :: Face.t()
  def merge_style_props(%Face{} = base, %Face{} = overlay) do
    @mergeable_style_fields
    |> Enum.reduce(base, fn field, acc ->
      case Map.get(overlay, field) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
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
