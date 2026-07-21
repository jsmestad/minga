defmodule MingaEditor.RenderModel.Window.Builder do
  @moduledoc """
  Builds a `RenderWindow` from the same data the Content stage uses.

  Called during `build_window_content/2` when the frontend has GUI
  capabilities. Captures the pre-resolved semantic data that the GUI
  needs, without duplicating the draw logic.

  The builder reads from:
  - `WindowScroll` (viewport, lines, cursor, fold map, visible_line_map)
  - `Context.t()` (visual selection, search matches, highlight, decorations)
  - Buffer diagnostics (for inline ranges)

  All positions are converted to display coordinates (relative to the
  window's content rect, with fold/wrap adjustments applied).
  """

  alias Minga.Config
  alias Minga.Core.Decorations
  alias Minga.Core.Decorations.BlockDecoration
  alias Minga.Core.Decorations.FoldRegion
  alias Minga.Core.Decorations.HighlightRange
  alias Minga.Core.HlTodo
  alias Minga.Core.IndentGuide
  alias Minga.Core.Unicode
  alias Minga.Core.WrapMap
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
  alias MingaEditor.Layout
  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.Renderer.Composition
  alias MingaEditor.Renderer.Context
  alias Minga.RenderModel.Window, as: RenderWindow
  alias Minga.RenderModel.Window.ContentDigest
  alias MingaEditor.RenderModel.Window.ResidentBuild
  alias Minga.RenderModel.Window.Annotation
  alias Minga.RenderModel.Window.Cursorline
  alias Minga.RenderModel.Window.DiagnosticRange
  alias Minga.RenderModel.Window.DocumentHighlight
  alias Minga.RenderModel.Window.Gutter
  alias Minga.RenderModel.Window.GutterEntry
  alias Minga.RenderModel.Window.GutterMetrics
  alias Minga.RenderModel.Window.HitRegion
  alias Minga.RenderModel.Window.IndentGuides
  alias Minga.RenderModel.Window.LineIdentity
  alias Minga.RenderModel.Window.PaneGeometry
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.RowSlotAllocator
  alias Minga.RenderModel.Window.RowSlotExhaustedError
  alias Minga.RenderModel.Window.SearchMatch
  alias Minga.RenderModel.Window.Selection
  alias Minga.RenderModel.Window.Span
  alias Minga.RenderModel.Window.Viewport, as: RenderViewport
  alias MingaEditor.Renderer.Gutter, as: EditorGutter
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport
  alias MingaEditor.WindowTree
  alias Minga.LSP.SyncServer
  alias MingaEditor.UI.Highlight
  alias MingaEditor.UI.FontRegistry

  @type state :: EditorState.t() | MingaEditor.RenderPipeline.Input.t()
  @typep visual_row_entry :: %{
           :row => Row.t(),
           :buf_line => non_neg_integer(),
           :visual_index => non_neg_integer(),
           :display_row => non_neg_integer(),
           :source_text => String.t(),
           :source_start_byte => non_neg_integer(),
           :source_end_byte => non_neg_integer(),
           :source_start_col => non_neg_integer(),
           :source_end_col => non_neg_integer(),
           :indent_width => non_neg_integer(),
           :row_width => non_neg_integer(),
           # Upstream row-retention metadata (#2287); absent on entries built
           # through the public click hit-testing path. `wrap_line_hash` is set
           # only on wrapped entries to key the per-logical-line reuse cache.
           optional(:input_hash) => non_neg_integer(),
           optional(:reused?) => boolean(),
           optional(:wrap_line_hash) => non_neg_integer()
         }

  @typedoc """
  Per-build retained-row statistics (#2287).

  * `rasterized` — rows whose text and spans were freshly composed this frame.
  * `retained_rows` — the `{row_id => {input_hash, Row.t()}}` map to carry into
    the next frame so unchanged rows can be reused without recomposing.
  * `retained_wrap_lines` — the `{buf_line => {input_hash, [entry]}}` map to
    carry into the next frame so unchanged wrapped logical lines can be reused
    without recomposing or re-wrapping.
  """
  @type build_stats :: %{
          rasterized: non_neg_integer(),
          retained_rows: %{optional(non_neg_integer()) => {non_neg_integer(), Row.t()}},
          retained_wrap_lines: %{optional(non_neg_integer()) => {non_neg_integer(), [map()]}},
          resident_build: ResidentBuild.t() | nil,
          resident_rows_spliced: non_neg_integer(),
          row_slot_allocator: RowSlotAllocator.t()
        }

  # Threaded through the visual-entry builders to drive upstream row reuse
  # (#2287). `prev` is the previous frame's per-visual-row retained-row map;
  # `prev_wrap` is the previous frame's per-logical-line wrapped-line cache;
  # `compose_fp` is a cheap fingerprint of the composition-relevant context
  # shared by every row.
  @typep retain_ctx :: %{
           prev: %{optional(non_neg_integer()) => {non_neg_integer(), Row.t()}},
           prev_wrap: %{optional(non_neg_integer()) => {non_neg_integer(), [visual_row_entry()]}},
           compose_fp: non_neg_integer(),
           line_identity: LineIdentity.t() | nil,
           decoration_slots: %{optional(term()) => Row.row_slot()}
         }

  @typep folded_source_ctx :: %{
           line_byte_offsets: %{non_neg_integer() => non_neg_integer()},
           highlight_segments_by_line: %{non_neg_integer() => [Highlight.styled_segment()]},
           line_identity: LineIdentity.t() | nil,
           decoration_slots: %{optional(term()) => Row.row_slot()}
         }

  @doc """
  Builds a `RenderWindow` for one editor window.

  Called from the Content stage with the same `WindowScroll` and
  `Context` that drive the draw-based rendering.
  """
  @spec build(state(), WindowScroll.t(), Context.t(), keyword()) :: RenderWindow.t()
  def build(state, scroll, ctx, opts \\ []) do
    {window, _stats} = build_with_stats(state, scroll, ctx, opts)
    window
  end

  @doc """
  Builds a `RenderWindow` and reports retained-row statistics (#2287).

  Identical output to `build/4` but also returns how many rows were freshly
  rasterized and the retained-row map to carry into the next frame. Pass the
  previous frame's retained rows via the `:retained_rows` option so unchanged
  rows are reused verbatim instead of being recomposed.
  """
  @spec build_with_stats(state(), WindowScroll.t(), Context.t(), keyword()) ::
          {RenderWindow.t(), build_stats()}
  def build_with_stats(state, scroll, ctx, opts \\ []) do
    %WindowScroll{
      win_id: win_id,
      is_active: is_active,
      viewport: viewport,
      cursor_line: cursor_line,
      cursor_byte_col: _cursor_byte_col,
      cursor_col: cursor_col,
      first_line: first_line,
      lines: lines,
      snapshot: snapshot,
      window: window,
      win_layout: win_layout,
      visible_line_map: visible_line_map,
      wrap_on: wrap_on
    } = scroll

    visible_row_count = Viewport.content_rows(viewport)
    content_kind = Keyword.get(opts, :content_kind, :buffer)
    rect = win_layout.content
    {content_row, _content_col, _content_width, _content_height} = rect

    {decoration_slots, row_slot_allocator} =
      allocate_decoration_slots(
        Keyword.get(opts, :row_slot_allocator, RowSlotAllocator.new()),
        scroll.content_epoch,
        scroll.line_identity,
        visible_line_map
      )

    retain_ctx =
      retain_ctx(
        ctx,
        Keyword.get(opts, :retained_rows, %{}),
        Keyword.get(opts, :retained_wrap_lines, %{}),
        scroll.line_identity,
        decoration_slots
      )

    # Build visual rows from the same data the draw path uses. Unchanged rows
    # are reused from the retained-row cache (no recompose) when their cheap
    # input fingerprint matches; only composed rows count as rasterized (#2287).
    #
    # Full-document residence (#2658) takes an incremental path: a persistent
    # ResidentBuild state splices only the rows whose text changed and maintains
    # the content digest in O(changed rows). A tree-sitter re-highlight still
    # triggers a full rebuild (the highlight fingerprint changes), but the common
    # case (in-place text edit) avoids the O(document) compose. Off residence this
    # is the unchanged windowed build and `resident_result` is nil, so behaviour
    # is byte identical.
    {all_visual_entries, resident_result} =
      if scroll.full_residence do
        materialize_full? =
          state.force_keyframe? or adapter_full_snapshot_pending?(state, win_id)

        resident_opts = Keyword.put(opts, :keyframe?, materialize_full?)

        build_resident_entries(
          scroll,
          lines,
          first_line,
          ctx,
          snapshot,
          retain_ctx,
          resident_opts
        )
      else
        {build_visual_entries(
           lines,
           first_line,
           visible_line_map,
           wrap_on,
           ctx,
           snapshot,
           retain_ctx
         ), nil}
      end

    visible_row_start_index = scroll.visible_row_start_index + viewport.visual_row_offset
    raw_overscan_before = max(scroll.visible_row_start_index - viewport.visual_row_offset, 0)
    # Under full residence, visible_row_start_index is the viewport's absolute
    # document offset, not a small overscan count. Cap the presentation overscan
    # so retained-row resolution stays viewport-windowed.
    payload_overscan_before =
      if scroll.full_residence,
        do: min(raw_overscan_before, visible_row_count),
        else: raw_overscan_before

    resident_context_start =
      if resident_result, do: Map.get(resident_result, :context_start, 0), else: 0

    local_visible_start = max(visible_row_start_index - resident_context_start, 0)

    visual_entries =
      trim_visual_entries(all_visual_entries, local_visible_start, visible_row_count)

    presentation_entries =
      presentation_visual_entries(
        all_visual_entries,
        local_visible_start,
        visible_row_count,
        payload_overscan_before
      )

    # Full-document residence (#2653): the window carries every laid-out row so the
    # frontend store is complete and a fast scroll can never outrun it. The gutter
    # (build_gutter below) uses the same entry set as the rows so the Go side can
    # index both by absolute row position; indent guides are independently
    # viewport-windowed off `scroll.lines`. Only the row set and its retained-row
    # cache become resident.
    #
    # The resident entries feed only `presentation_rows` (the `.row` of each),
    # which never carries the entry-level `display_row`, so the residence path
    # skips the whole-document re-index `trim_visual_entries/3` would do (#2658).
    resident_entries =
      resident_presentation_entries(
        scroll,
        resident_result,
        all_visual_entries,
        presentation_entries
      )

    {new_retained, rasterized, content_digest, resident_build_state, resident_rows_spliced} =
      resolve_retained_and_digest(resident_result, resident_entries, retain_ctx)

    new_retained_wrap =
      retained_wrap_lines(resident_entries, wrap_on and visible_line_map == nil)

    presentation_rows = Enum.map(resident_entries, & &1.row)
    committed_rows = Enum.map(visual_entries, & &1.row)
    wrapped_coordinates? = wrap_on and visible_line_map == nil

    # Cursor in display coordinates
    {display_cursor_row, display_cursor_col} =
      compute_display_cursor(
        cursor_line,
        cursor_col,
        viewport,
        window.fold_map,
        ctx.decorations,
        visual_entries,
        wrapped_coordinates?
      )

    cursor_shape =
      if is_active do
        Minga.Editing.cursor_shape(state)
      else
        :block
      end

    display_cursor_col =
      adjust_cursor_col_for_shape(
        display_cursor_row,
        display_cursor_col,
        cursor_shape,
        committed_rows
      )

    # Whether the cursor's line currently falls inside the visible viewport.
    # After VSCode-style wheel free-scroll (#2684) the cursor can leave the
    # viewport without moving; when it does, the caret and cursorline must
    # disappear rather than ghost at the edge row (the clamp in
    # `compute_display_cursor/7` and the encoder both pin a negative relative
    # row to 0). Cursor-follow re-anchors on the next cursor-moving key.
    cursor_on_screen? =
      cursor_on_screen?(
        cursor_line,
        viewport,
        window.fold_map,
        visual_entries,
        visible_row_count,
        wrapped_coordinates?
      )

    # Hide the editor cursor when the minibuffer has focus (command, search,
    # eval, search_prompt modes). The native SwiftUI minibuffer shows its
    # own cursor; having two cursors visible is confusing. Also hide it when the
    # cursor has scrolled off-viewport (#2684).
    cursor_visible =
      if is_active do
        cursor_on_screen? and not Minga.Editing.minibuffer_mode?(state)
      else
        false
      end

    # Selection in display coordinates
    selection =
      build_selection(
        ctx.visual_selection,
        viewport,
        visible_row_count,
        visual_entries,
        wrapped_coordinates?
      )

    # Search matches in display coordinates
    viewport_bottom = viewport.top + visible_row_count

    search_matches =
      build_search_matches(
        ctx.search_matches,
        ctx.confirm_match,
        viewport,
        viewport_bottom,
        visual_entries,
        wrapped_coordinates?
      )

    # Diagnostic inline ranges in display coordinates
    diagnostic_ranges =
      build_diagnostic_ranges(
        snapshot.file_path,
        viewport,
        visible_row_count,
        visual_entries,
        wrapped_coordinates?,
        lines,
        first_line
      )

    # Document highlights in display coordinates
    doc_highlights =
      build_document_highlights(
        state.workspace.document_highlights,
        viewport,
        viewport_bottom,
        visual_entries,
        wrapped_coordinates?
      )

    # Line annotations in display coordinates
    annotations =
      build_annotations(
        ctx.decorations,
        viewport.top,
        viewport_bottom,
        visual_entries,
        wrapped_coordinates?
      )

    geometry = build_geometry(state, scroll, content_kind)

    render_window = %RenderWindow{
      window_id: win_id,
      content_kind: content_kind,
      rect: rect,
      rows: presentation_rows,
      cursor_row: display_cursor_row,
      cursor_col: display_cursor_col,
      cursor_shape: cursor_shape,
      cursor_visible: cursor_visible,
      scroll_left: viewport.left,
      selection: selection,
      search_matches: search_matches,
      diagnostic_ranges: diagnostic_ranges,
      document_highlights: doc_highlights,
      annotations: annotations,
      gutter: build_gutter(scroll, ctx, content_kind, resident_entries),
      cursorline:
        build_cursorline(content_row, display_cursor_row, is_active, cursor_on_screen?, ctx),
      indent_guides: build_indent_guides(scroll, ctx, content_kind),
      geometry: geometry,
      content_epoch: scroll.content_epoch,
      full_refresh: scroll.full_refresh,
      scroll_seq: scroll.scroll_seq,
      # Non-wrapped, non-folded windows emit consecutive :normal buffer lines, so
      # ScrollPresentation can derive the resident line range arithmetically.
      contiguous_rows: is_nil(visible_line_map) and not wrap_on,
      # Set only on the residence path; the GUI adapter gates the content
      # frame-emit on it instead of hashing the full rows list (#2658).
      content_digest: content_digest,
      row_delta: if(resident_result, do: resident_result.row_delta, else: nil)
    }

    {render_window,
     %{
       rasterized: rasterized,
       retained_rows: new_retained,
       retained_wrap_lines: new_retained_wrap,
       resident_build: resident_build_state,
       resident_rows_spliced: resident_rows_spliced,
       row_slot_allocator: row_slot_allocator
     }}
  end

  @spec adapter_full_snapshot_pending?(map(), non_neg_integer()) :: boolean()
  defp adapter_full_snapshot_pending?(state, window_id) do
    state.caches.adapter_gui_caches.pending_window_delta_ids
    |> MapSet.member?(window_id)
  end

  @spec resident_presentation_entries(
          WindowScroll.t(),
          map() | nil,
          [visual_row_entry()],
          [visual_row_entry()]
        ) :: [visual_row_entry()]
  defp resident_presentation_entries(
         %{full_residence: true},
         %{row_delta: %Minga.RenderModel.Window.RowDelta{}, inserted_payloads: payloads},
         _all,
         _presentation
       ),
       do: payloads

  defp resident_presentation_entries(%{full_residence: true}, _result, all, _presentation),
    do: all

  defp resident_presentation_entries(_scroll, _result, _all, presentation), do: presentation

  # ── Full-document residence incremental build (#2658) ──────────────────────

  # Runs the persistent ResidentBuild for the residence path, returning the full
  # resident entry list and the frame's retained/digest result. The full build
  # and the dirty-line splice both compose through `compose_sequential_entry/6`,
  # so a spliced entry is byte identical to a freshly built one.
  @spec build_resident_entries(
          WindowScroll.t(),
          [String.t()],
          non_neg_integer(),
          Context.t(),
          map(),
          retain_ctx(),
          keyword()
        ) :: {[visual_row_entry()], map()}
  defp build_resident_entries(scroll, lines, first_line, ctx, snapshot, retain_ctx, opts) do
    inputs = %{
      line_texts: lines,
      line_count: snapshot.line_count,
      compose_fp: retain_ctx.compose_fp,
      highlight_fp: highlight_content_fingerprint(ctx.highlight),
      reset?: scroll.full_refresh,
      hydration_reason: Keyword.get(opts, :hydration_reason),
      keyframe?: Keyword.get(opts, :keyframe?, false),
      retained_rows: retain_ctx.prev,
      edit_deltas: Keyword.get(opts, :edit_deltas, []),
      build_all: fn ->
        # Hydration is the one path where BufferPrefetch explicitly supplied the
        # whole bounded line range. No retained Document is sliced here.
        build_visual_entries(lines, first_line, nil, false, ctx, snapshot, retain_ctx)
      end,
      build_dirty: fn dirty ->
        build_dirty_sequential_entries(dirty, lines, first_line, ctx, snapshot, retain_ctx)
      end
    }

    {state, result} = ResidentBuild.run(Keyword.get(opts, :resident_build), inputs)

    if result.row_delta == nil do
      {result.payloads, Map.put(result, :state, state)}
    else
      context_before = 8
      context_start = max(scroll.visible_row_start_index - context_before, 0)
      context_count = MingaEditor.Viewport.content_rows(scroll.viewport) + context_before * 2
      context_payloads = ResidentStore.payload_range(state.store, context_start, context_count)

      {context_payloads,
       result
       |> Map.put(:state, state)
       |> Map.put(:context_start, context_start)}
    end
  end

  # Composes entries for exactly the dirty sequential line indices, reusing the
  # masked highlight batch so only dirty rows produce styled segments (#2658).
  @spec build_dirty_sequential_entries(
          MapSet.t(non_neg_integer()),
          [String.t()],
          non_neg_integer(),
          Context.t(),
          map(),
          retain_ctx()
        ) :: %{non_neg_integer() => visual_row_entry()}
  defp build_dirty_sequential_entries(dirty, lines, first_line, ctx, snapshot, retain_ctx) do
    first_byte_off = snapshot.first_line_byte_offset
    local_dirty = MapSet.new(dirty, &(&1 - first_line))
    offsets = dirty_line_offsets(lines, first_byte_off, local_dirty)
    masked = masked_highlight_by_index(ctx.highlight, lines, first_byte_off, local_dirty)

    Enum.reduce(dirty, %{}, fn absolute_index, acc ->
      local_index = absolute_index - first_line
      {line_text, line_byte_offset} = Map.fetch!(offsets, local_index)

      entry =
        compose_sequential_entry(
          absolute_index,
          line_text,
          Map.get(masked, local_index),
          line_byte_offset,
          ctx,
          retain_ctx
        )

      Map.put(acc, absolute_index, entry)
    end)
  end

  @spec dirty_line_offsets([String.t()], non_neg_integer(), MapSet.t(non_neg_integer())) ::
          %{non_neg_integer() => {String.t(), non_neg_integer()}}
  defp dirty_line_offsets(lines, first_byte_off, dirty) do
    lines
    |> build_lines_with_offsets(first_byte_off)
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {{line, off}, index}, acc ->
      if MapSet.member?(dirty, index), do: Map.put(acc, index, {line, off}), else: acc
    end)
  end

  # Masked highlight segments for exactly the dirty lines, keyed by index. With no
  # tree-sitter highlight there is nothing to compute. With highlight, the batch
  # walk keeps byte-offset watermarks correct but only produces segments for the
  # dirty rows (#2658).
  @spec masked_highlight_by_index(
          Highlight.t() | nil,
          [String.t()],
          non_neg_integer(),
          MapSet.t(non_neg_integer())
        ) :: %{non_neg_integer() => [Highlight.styled_segment()]}
  defp masked_highlight_by_index(nil, _lines, _first_byte_off, _dirty), do: %{}

  defp masked_highlight_by_index(%Highlight{} = hl, lines, first_byte_off, dirty) do
    hl
    |> Highlight.styles_for_text_lines_masked(lines, first_byte_off, dirty)
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {segments, index}, acc ->
      if is_nil(segments), do: acc, else: Map.put(acc, index, segments)
    end)
  end

  @spec highlight_content_fingerprint(Highlight.t() | nil) :: integer() | nil
  defp highlight_content_fingerprint(nil), do: nil
  defp highlight_content_fingerprint(%Highlight{} = hl), do: :erlang.phash2(hl)

  @spec resolve_retained_and_digest(map() | nil, [visual_row_entry()], retain_ctx()) ::
          {%{optional(non_neg_integer()) => {non_neg_integer(), Row.t()}}, non_neg_integer(),
           ContentDigest.t() | nil, ResidentBuild.t() | nil, non_neg_integer()}
  defp resolve_retained_and_digest(nil, resident_entries, retain_ctx) do
    {new_retained, rasterized} = retained_stats(resident_entries, retain_ctx)
    {new_retained, rasterized, nil, nil, 0}
  end

  defp resolve_retained_and_digest(%{} = result, _resident_entries, _retain_ctx) do
    {result.retained_rows, result.rasterized, result.digest, result.state, result.spliced}
  end

  # ── Upstream row retention (#2287) ─────────────────────────────────────────

  # A row may be reused only when nothing the composition reads has changed.
  # `compose_fp` folds the composition-relevant context (decorations, invisible
  # rendering, tab width, todo faces, and — only when conceals exist — the
  # cursor line) into one hash. A retained row is reused when both its stored
  # input fingerprint AND this frame's compose_fp match, so any context change
  # conservatively forces a full recompose.
  @spec retain_ctx(
          Context.t(),
          %{optional(non_neg_integer()) => {non_neg_integer(), Row.t()}},
          %{optional(non_neg_integer()) => {non_neg_integer(), [visual_row_entry()]}},
          LineIdentity.t() | nil,
          map()
        ) :: retain_ctx()
  defp retain_ctx(%Context{} = ctx, prev, prev_wrap, line_identity, decoration_slots)
       when is_map(prev) and is_map(prev_wrap) and is_map(decoration_slots) do
    conceal_cursor =
      if Decorations.has_conceal_ranges?(ctx.decorations), do: ctx.cursor_line, else: nil

    compose_fp =
      :erlang.phash2({
        ctx.decorations,
        ctx.show_invisible,
        ctx.tab_width,
        ctx.whitespace_face,
        ctx.hl_todo_faces,
        ctx.highlight != nil,
        conceal_cursor
      })

    %{
      prev: prev,
      prev_wrap: prev_wrap,
      compose_fp: compose_fp,
      line_identity: line_identity,
      decoration_slots: decoration_slots
    }
  end

  # Cheap per-row input fingerprint: the line text, its highlight segments, and
  # the shared compose fingerprint. When this matches the retained row's stored
  # fingerprint, the previously composed Row is reused without recomposing.
  @spec row_input_hash(retain_ctx(), term()) :: non_neg_integer()
  defp row_input_hash(%{compose_fp: compose_fp}, key) do
    :erlang.phash2({key, compose_fp})
  end

  @spec durable_source_id(map(), non_neg_integer()) :: non_neg_integer()
  defp durable_source_id(%{line_identity: identity}, buf_line) when identity != nil do
    case LineIdentity.source_id(identity, buf_line) do
      {:ok, source_id} -> source_id
      :error -> raise ArgumentError, "missing durable identity for buffer line #{buf_line}"
    end
  end

  defp durable_source_id(_context, buf_line) do
    raise ArgumentError, "missing line identity for buffer line #{buf_line}"
  end

  @spec allocate_decoration_slots(
          RowSlotAllocator.t(),
          non_neg_integer(),
          LineIdentity.t() | nil,
          DisplayMap.t() | [DisplayMap.entry()] | nil
        ) :: {map(), RowSlotAllocator.t()}
  defp allocate_decoration_slots(allocator, _epoch, _identity, nil), do: {%{}, allocator}

  defp allocate_decoration_slots(
         allocator,
         epoch,
         identity,
         %DisplayMap{entries: entries}
       )
       when identity != nil do
    allocate_decoration_slots(allocator, epoch, identity, entries)
  end

  defp allocate_decoration_slots(allocator, epoch, identity, entries)
       when identity != nil and is_list(entries) do
    Enum.reduce(entries, {%{}, allocator}, fn entry, accumulator ->
      reserve_decoration_slot(decoration_slot_key(entry), accumulator, epoch, identity)
    end)
  end

  defp allocate_decoration_slots(_allocator, _epoch, nil, visible_line_map)
       when visible_line_map != nil do
    raise ArgumentError, "decoration rows require durable line identity"
  end

  @spec reserve_decoration_slot(
          {non_neg_integer(), atom(), term()} | nil,
          {map(), RowSlotAllocator.t()},
          non_neg_integer(),
          LineIdentity.t()
        ) :: {map(), RowSlotAllocator.t()}
  defp reserve_decoration_slot(nil, accumulator, _epoch, _identity), do: accumulator

  defp reserve_decoration_slot(
         {buf_line, kind, key},
         {slots, allocator},
         epoch,
         identity
       ) do
    source_id = durable_source_id(%{line_identity: identity}, buf_line)
    scope = {epoch, source_id, kind}

    put_allocated_decoration_slot(RowSlotAllocator.allocate(allocator, scope, key), slots, {
      buf_line,
      kind,
      key
    })
  end

  @spec put_allocated_decoration_slot(
          {:ok, Row.row_slot(), RowSlotAllocator.t()} | :reset_required,
          map(),
          term()
        ) :: {map(), RowSlotAllocator.t()}
  defp put_allocated_decoration_slot({:ok, slot, allocator}, slots, key),
    do: {Map.put(slots, key, slot), allocator}

  defp put_allocated_decoration_slot(:reset_required, _slots, _key),
    do: raise(RowSlotExhaustedError)

  @spec decoration_slot_key(DisplayMap.entry()) ::
          {non_neg_integer(), atom(), term()} | nil
  defp decoration_slot_key({buf_line, {:virtual_line, virtual_text}}),
    do: {buf_line, :virtual_line, virtual_text.id}

  defp decoration_slot_key({buf_line, {:block, block, line_index}}),
    do: {buf_line, :block, {block.id, line_index}}

  defp decoration_slot_key({buf_line, {:decoration_fold, fold}}),
    do: {buf_line, :decoration_fold, fold.id}

  defp decoration_slot_key(_entry), do: nil

  @spec decoration_slot(map(), non_neg_integer(), atom(), term()) :: Row.row_slot()
  defp decoration_slot(%{decoration_slots: slots}, buf_line, kind, key) do
    Map.fetch!(slots, {buf_line, kind, key})
  end

  # Returns the composed Row for a visual row, reusing the retained Row when the
  # input fingerprint is unchanged. The returned entry carries `:input_hash` and
  # `:reused?` so the build can report rasterized counts and refresh the cache.
  @spec compose_or_reuse(retain_ctx(), non_neg_integer(), term(), (-> Row.t())) ::
          {Row.t(), non_neg_integer(), boolean()}
  defp compose_or_reuse(%{prev: prev} = retain_ctx, row_id, key, compose_fun) do
    input_hash = row_input_hash(retain_ctx, key)

    case Map.get(prev, row_id) do
      {^input_hash, %Row{} = cached} -> {cached, input_hash, true}
      _ -> {compose_fun.(), input_hash, false}
    end
  end

  @spec presentation_visual_entries(
          [visual_row_entry()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [visual_row_entry()]
  defp presentation_visual_entries(entries, visible_start, visible_count, overscan_before) do
    before_count = min(visible_start, overscan_before)
    start = visible_start - before_count
    count = visible_count + before_count + 1

    trim_visual_entries(entries, start, count)
  end

  @spec retained_stats([visual_row_entry()], retain_ctx()) ::
          {%{optional(non_neg_integer()) => {non_neg_integer(), Row.t()}}, non_neg_integer()}
  defp retained_stats(visual_entries, _retain_ctx) do
    Enum.reduce(visual_entries, {%{}, 0}, fn entry, {map, rasterized} ->
      row = entry.row
      input_hash = Map.get(entry, :input_hash, row.content_hash)
      map = Map.put(map, row.row_id, {input_hash, row})
      rasterized = if Map.get(entry, :reused?, false), do: rasterized, else: rasterized + 1
      {map, rasterized}
    end)
  end

  # Rebuilds the per-logical-line wrapped-line cache from this frame's visual
  # entries so the next wrapped frame can reuse unchanged logical lines whole.
  # Only meaningful for the wrapped path; other modes carry an empty map (#2287).
  #
  # Entries are stored UNTRIMMED-shape but already trimmed to the visible set; we
  # reset each entry's `display_row` to 0 so a reused logical line is positioned
  # identically by `trim_visual_entries/3` regardless of where it landed this
  # frame. Trimming may drop a logical line's leading rows; such partial groups
  # are not cached so reuse only ever replays a complete logical line.
  @spec retained_wrap_lines([visual_row_entry()], boolean()) ::
          %{optional(non_neg_integer()) => {non_neg_integer(), [visual_row_entry()]}}
  defp retained_wrap_lines(_visual_entries, false), do: %{}

  defp retained_wrap_lines(visual_entries, true) do
    visual_entries
    |> Enum.group_by(& &1.buf_line)
    |> Enum.reduce(%{}, fn {_buf_line, entries}, acc ->
      case wrap_line_cache_entry(entries) do
        nil -> acc
        {row_id, cached} -> Map.put(acc, row_id, cached)
      end
    end)
  end

  # A logical line is cacheable only when its full visual-row set is present
  # (first row is visual_index 0) and every row shares one wrap-line fingerprint.
  @spec wrap_line_cache_entry([visual_row_entry()]) ::
          {non_neg_integer(), {non_neg_integer(), [visual_row_entry()]}} | nil
  defp wrap_line_cache_entry([%{visual_index: 0} = first | _] = entries) do
    case Map.get(first, :wrap_line_hash) do
      nil ->
        nil

      hash ->
        normalized = Enum.map(entries, fn entry -> %{entry | display_row: 0} end)
        {first.row.row_id, {hash, normalized}}
    end
  end

  defp wrap_line_cache_entry(_entries), do: nil

  @doc "Returns the source buffer position for a click in wrapped composed rows."
  @spec wrapped_source_position(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Context.t(),
          map()
        ) :: {:ok, non_neg_integer(), non_neg_integer()} | :error
  def wrapped_source_position(
        lines,
        first_line,
        visual_row,
        display_col,
        %Context{} = ctx,
        options
      )
      when is_list(lines) and is_integer(first_line) and is_integer(visual_row) and
             is_integer(display_col) and is_map(options) do
    lines
    |> build_visual_entries_wrapped(
      first_line,
      ctx,
      %{first_line_byte_offset: 0, options: options},
      no_retain(LineIdentity.new(first_line + length(lines)))
    )
    |> Enum.at(visual_row)
    |> source_position_from_visual_entry(display_col, ctx.decorations)
  end

  @spec source_position_from_visual_entry(
          visual_row_entry() | nil,
          non_neg_integer(),
          Decorations.t()
        ) ::
          {:ok, non_neg_integer(), non_neg_integer()} | :error
  defp source_position_from_visual_entry(nil, _display_col, _decorations), do: :error

  defp source_position_from_visual_entry(entry, display_col, decorations) do
    composed_col = entry.source_start_col + max(display_col - entry.indent_width, 0)
    buffer_col = Decorations.display_col_to_buf_col(decorations, entry.buf_line, composed_col)
    {:ok, entry.buf_line, buffer_col}
  end

  # ── Visual row building ────────────────────────────────────────────────

  @spec build_visual_entries(
          [String.t()],
          non_neg_integer(),
          [DisplayMap.entry()] | nil,
          boolean(),
          Context.t(),
          map(),
          retain_ctx()
        ) :: [visual_row_entry()]
  defp build_visual_entries(
         lines,
         first_line,
         visible_line_map,
         wrap_on,
         ctx,
         snapshot,
         retain_ctx
       ) do
    build_visual_entries_for_mode(
      lines,
      first_line,
      visible_line_map,
      wrap_on,
      ctx,
      snapshot,
      retain_ctx
    )
  end

  # Click hit-testing builds entries without retention (no previous-frame cache).
  @spec no_retain(LineIdentity.t()) :: retain_ctx()
  defp no_retain(line_identity),
    do: %{
      prev: %{},
      prev_wrap: %{},
      compose_fp: 0,
      line_identity: line_identity,
      decoration_slots: %{}
    }

  @spec build_visual_entries_for_mode(
          [String.t()],
          non_neg_integer(),
          [DisplayMap.entry()] | nil,
          boolean(),
          Context.t(),
          map(),
          retain_ctx()
        ) :: [visual_row_entry()]
  defp build_visual_entries_for_mode(
         lines,
         first_line,
         visible_line_map,
         _wrap_on,
         ctx,
         snapshot,
         retain_ctx
       )
       when is_list(visible_line_map) do
    build_visual_entries_folded(lines, first_line, visible_line_map, ctx, snapshot, retain_ctx)
  end

  defp build_visual_entries_for_mode(lines, first_line, nil, true, ctx, snapshot, retain_ctx) do
    build_visual_entries_wrapped(lines, first_line, ctx, snapshot, retain_ctx)
  end

  defp build_visual_entries_for_mode(lines, first_line, nil, false, ctx, snapshot, retain_ctx) do
    build_visual_entries_sequential(lines, first_line, ctx, snapshot, retain_ctx)
  end

  # Sequential path (no folds): one visual row per line.
  @spec build_visual_entries_sequential(
          [String.t()],
          non_neg_integer(),
          Context.t(),
          map(),
          retain_ctx()
        ) :: [visual_row_entry()]
  defp build_visual_entries_sequential(lines, first_line, ctx, snapshot, retain_ctx) do
    first_byte_off = snapshot.first_line_byte_offset

    lines_with_offsets = build_lines_with_offsets(lines, first_byte_off)

    highlight_segments_list =
      if ctx.highlight do
        Highlight.styles_for_visible_lines(ctx.highlight, lines_with_offsets)
      else
        List.duplicate(nil, length(lines))
      end

    lines_with_offsets
    |> Enum.zip(highlight_segments_list)
    |> Enum.with_index()
    |> Enum.map(fn {{{line_text, line_byte_offset}, hl_segments}, idx} ->
      compose_sequential_entry(
        first_line + idx,
        line_text,
        hl_segments,
        line_byte_offset,
        ctx,
        retain_ctx
      )
    end)
  end

  # Composes (or reuses) the single visual-row entry for one sequential line.
  # Shared by the full sequential build and the residence dirty-line splice
  # (#2658) so both produce byte-identical entries for the same inputs.
  @spec compose_sequential_entry(
          non_neg_integer(),
          String.t(),
          [Highlight.styled_segment()] | nil,
          non_neg_integer(),
          Context.t(),
          retain_ctx()
        ) :: visual_row_entry()
  defp compose_sequential_entry(
         buf_line,
         line_text,
         hl_segments,
         line_byte_offset,
         ctx,
         retain_ctx
       ) do
    row_id = Row.stable_id(:normal, durable_source_id(retain_ctx, buf_line))

    {row, input_hash, reused?} =
      compose_or_reuse(retain_ctx, row_id, {:seq, line_text, hl_segments}, fn ->
        {composed_text, spans} =
          compose_line(line_text, hl_segments, ctx, buf_line, line_byte_offset)

        %Row{
          row_id: row_id,
          row_type: :normal,
          buf_line: buf_line,
          text: composed_text,
          spans: spans,
          content_hash: Row.compute_hash(composed_text, spans)
        }
      end)

    row
    |> Row.reposition(buf_line)
    |> visual_entry(0, Unicode.display_width(row.text), 0)
    |> with_retain_meta(input_hash, reused?)
  end

  @spec build_visual_entries_wrapped(
          [String.t()],
          non_neg_integer(),
          Context.t(),
          map(),
          retain_ctx()
        ) :: [visual_row_entry()]
  defp build_visual_entries_wrapped(lines, first_line, ctx, snapshot, retain_ctx) do
    first_byte_off = snapshot.first_line_byte_offset
    lines_with_offsets = build_lines_with_offsets(lines, first_byte_off)

    highlight_segments_list =
      if ctx.highlight do
        Highlight.styles_for_visible_lines(ctx.highlight, lines_with_offsets)
      else
        List.duplicate(nil, length(lines))
      end

    wrap_opts = wrap_options(ctx, snapshot.options)
    content_width = Keyword.fetch!(wrap_opts, :content_width)

    lines_with_offsets
    |> Enum.zip(highlight_segments_list)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{{line_text, line_byte_offset}, hl_segments}, idx} ->
      build_wrapped_logical_line(%{
        line_text: line_text,
        line_byte_offset: line_byte_offset,
        hl_segments: hl_segments,
        buf_line: first_line + idx,
        content_width: content_width,
        wrap_opts: wrap_opts,
        ctx: ctx,
        retain_ctx: retain_ctx
      })
    end)
  end

  # Builds (or replays) the full visual-row set for one wrapped logical line.
  #
  # True logical-line reuse: when the line's full input fingerprint (text,
  # highlight segments, shared compose context, AND content width, since wrap
  # points depend on width) matches the cached logical line, the entire
  # visual-row set is replayed verbatim, skipping both compose_line and the wrap
  # computation. Otherwise the line is composed and re-wrapped from scratch (#2287).
  @spec build_wrapped_logical_line(map()) :: [visual_row_entry()]
  defp build_wrapped_logical_line(params) do
    %{
      line_text: line_text,
      hl_segments: hl_segments,
      buf_line: buf_line,
      content_width: content_width,
      retain_ctx: retain_ctx
    } = params

    wrap_line_hash =
      row_input_hash(retain_ctx, {:wrap_line, line_text, hl_segments, content_width})

    source_id = durable_source_id(retain_ctx, buf_line)

    case reuse_wrapped_line(retain_ctx, source_id, buf_line, wrap_line_hash) do
      {:reuse, entries} -> entries
      :miss -> compose_wrapped_logical_line(params, wrap_line_hash)
    end
  end

  @spec compose_wrapped_logical_line(map(), non_neg_integer()) :: [visual_row_entry()]
  defp compose_wrapped_logical_line(params, wrap_line_hash) do
    %{
      line_text: line_text,
      line_byte_offset: line_byte_offset,
      hl_segments: hl_segments,
      buf_line: buf_line,
      wrap_opts: wrap_opts,
      ctx: ctx
    } = params

    {composed_text, spans} =
      compose_line(line_text, hl_segments, ctx, buf_line, line_byte_offset)

    composed_text
    |> wrap_composed_entries(
      spans,
      buf_line,
      durable_source_id(params.retain_ctx, buf_line),
      wrap_opts
    )
    |> Enum.map(&stamp_wrapped_entry(&1, wrap_line_hash))
  end

  @spec stamp_wrapped_entry(visual_row_entry(), non_neg_integer()) :: visual_row_entry()
  defp stamp_wrapped_entry(entry, wrap_line_hash) do
    entry
    |> with_retain_meta(wrap_line_hash, false)
    |> Map.put(:wrap_line_hash, wrap_line_hash)
  end

  # Replays a cached wrapped logical line when its fingerprint is unchanged. The
  # cached entries already carry their Rows (ids, text, spans, hashes) and wrap
  # metadata, so reuse reproduces the exact visual-row set with no recomposition.
  @spec reuse_wrapped_line(
          retain_ctx(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:reuse, [visual_row_entry()]} | :miss
  defp reuse_wrapped_line(%{prev_wrap: prev_wrap}, source_id, buf_line, wrap_line_hash) do
    row_id = Row.stable_id(:normal, source_id)

    case Map.get(prev_wrap, row_id) do
      {^wrap_line_hash, entries} when is_list(entries) ->
        {:reuse, Enum.map(entries, &mark_wrapped_reused(&1, buf_line, wrap_line_hash))}

      _ ->
        :miss
    end
  end

  @spec mark_wrapped_reused(map(), non_neg_integer(), non_neg_integer()) ::
          visual_row_entry()
  defp mark_wrapped_reused(entry, buf_line, wrap_line_hash) do
    entry
    |> Map.put(:buf_line, buf_line)
    |> Map.update!(:row, &Row.reposition(&1, buf_line))
    |> with_retain_meta(wrap_line_hash, true)
    |> Map.put(:wrap_line_hash, wrap_line_hash)
  end

  @spec with_retain_meta(visual_row_entry(), non_neg_integer(), boolean()) :: visual_row_entry()
  defp with_retain_meta(entry, input_hash, reused?) do
    entry
    |> Map.put(:input_hash, input_hash)
    |> Map.put(:reused?, reused?)
  end

  @spec wrap_composed_entries(
          String.t(),
          [Span.t()],
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) :: [visual_row_entry()]
  defp wrap_composed_entries(composed_text, spans, buf_line, source_id, opts) do
    [visual_rows] = WrapMap.compute([composed_text], Keyword.fetch!(opts, :content_width), opts)

    visual_rows
    |> Enum.with_index()
    |> Enum.map(fn {visual_row, visual_index} ->
      text = WrapMap.display_text(visual_row)
      row_type = if visual_index == 0, do: :normal, else: :wrap_continuation
      row_spans = spans_for_visual_row(spans, composed_text, visual_row)
      source_start = visual_row_source_start(composed_text, visual_row)
      source_end = visual_row_source_end(source_start, visual_row)
      source_start_byte = Map.get(visual_row, :byte_offset, 0)

      source_end_byte =
        source_start_byte +
          byte_size(Map.get(visual_row, :source_text, Map.get(visual_row, :text, "")))

      indent_width = Map.get(visual_row, :indent_width, 0)

      row = %Row{
        row_id: Row.stable_id(row_type, source_id, visual_index),
        row_type: row_type,
        buf_line: buf_line,
        visual_index: visual_index,
        text: text,
        spans: row_spans,
        content_hash: Row.compute_hash(text, row_spans)
      }

      visual_entry(
        row,
        composed_text,
        source_start,
        source_end,
        source_start_byte,
        source_end_byte,
        indent_width
      )
    end)
  end

  @spec wrap_options(Context.t(), map()) :: keyword()
  defp wrap_options(%Context{} = ctx, options) do
    [
      content_width: max(ctx.content_w, 1),
      breakindent: Map.get(options, :breakindent, true),
      linebreak: Map.get(options, :linebreak, true),
      oracle: ctx.width_oracle,
      tab_width: ctx.tab_width
    ]
  end

  @spec trim_visual_entries([visual_row_entry()], non_neg_integer(), non_neg_integer()) :: [
          visual_row_entry()
        ]
  defp trim_visual_entries(entries, offset, row_count) do
    entries
    |> drop_visual_entry_offset(offset)
    |> Enum.take(row_count)
    |> Enum.with_index()
    |> Enum.map(fn {entry, display_row} -> %{entry | display_row: display_row} end)
  end

  @spec drop_visual_entry_offset([visual_row_entry()], non_neg_integer()) :: [visual_row_entry()]
  defp drop_visual_entry_offset(entries, 0), do: entries

  defp drop_visual_entry_offset(entries, offset) do
    case Enum.drop(entries, offset) do
      [] -> entries |> Enum.at(-1) |> List.wrap()
      visible -> visible
    end
  end

  @spec visual_entry(Row.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          visual_row_entry()
  defp visual_entry(%Row{} = row, source_start_col, source_end_col, indent_width) do
    visual_entry(
      row,
      row.text,
      source_start_col,
      source_end_col,
      0,
      byte_size(row.text),
      indent_width
    )
  end

  @spec visual_entry(
          Row.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: visual_row_entry()
  defp visual_entry(
         %Row{} = row,
         source_text,
         source_start_col,
         source_end_col,
         source_start_byte,
         source_end_byte,
         indent_width
       ) do
    %{
      row: row,
      buf_line: row.buf_line,
      visual_index: row.visual_index,
      display_row: 0,
      source_text: source_text,
      source_start_byte: source_start_byte,
      source_end_byte: source_end_byte,
      source_start_col: source_start_col,
      source_end_col: source_end_col,
      indent_width: indent_width,
      row_width: Unicode.display_width(row.text)
    }
  end

  @spec spans_for_visual_row([Span.t()], String.t(), WrapMap.visual_row()) :: [Span.t()]
  defp spans_for_visual_row(spans, composed_text, visual_row) do
    source_start = visual_row_source_start(composed_text, visual_row)
    source_end = visual_row_source_end(source_start, visual_row)
    indent_width = Map.get(visual_row, :indent_width, 0)

    spans
    |> Enum.flat_map(&Span.rebase_to_visual_row(&1, source_start, source_end, indent_width))
  end

  @spec visual_row_source_start(String.t(), WrapMap.visual_row()) :: non_neg_integer()
  defp visual_row_source_start(composed_text, visual_row) do
    Unicode.display_col(composed_text, Map.get(visual_row, :byte_offset, 0))
  end

  @spec visual_row_source_end(non_neg_integer(), WrapMap.visual_row()) :: non_neg_integer()
  defp visual_row_source_end(source_start, visual_row) do
    source_text = Map.get(visual_row, :source_text, Map.get(visual_row, :text, ""))
    source_start + Unicode.display_width(source_text)
  end

  # Fold-aware path: walks visible_line_map entries.
  @spec build_visual_entries_folded(
          [String.t()],
          non_neg_integer(),
          [DisplayMap.entry()],
          Context.t(),
          map(),
          retain_ctx()
        ) :: [visual_row_entry()]
  defp build_visual_entries_folded(lines, first_line, visible_line_map, ctx, snapshot, retain_ctx) do
    line_byte_offsets =
      build_line_byte_offsets(lines, first_line, snapshot.first_line_byte_offset)

    highlight_segments_by_line =
      build_highlight_segments_by_line(
        lines,
        first_line,
        visible_line_map,
        line_byte_offsets,
        ctx.highlight
      )

    source_ctx = %{
      line_byte_offsets: line_byte_offsets,
      highlight_segments_by_line: highlight_segments_by_line,
      line_identity: retain_ctx.line_identity,
      decoration_slots: retain_ctx.decoration_slots
    }

    {entries, _counters} =
      Enum.map_reduce(visible_line_map, %{}, fn {buf_line, entry_type}, counters ->
        {visual_identity_index, counters} = next_visual_identity(buf_line, entry_type, counters)

        {row, input_hash, reused?} =
          build_visual_row_entry_retained(
            buf_line,
            entry_type,
            lines,
            first_line,
            ctx,
            source_ctx,
            visual_identity_index,
            retain_ctx
          )

        entry =
          row
          |> visual_entry(0, Unicode.display_width(row.text), 0)
          |> with_retain_meta(input_hash, reused?)

        {entry, counters}
      end)

    entries
  end

  @spec build_highlight_segments_by_line(
          [String.t()],
          non_neg_integer(),
          [DisplayMap.entry()],
          %{non_neg_integer() => non_neg_integer()},
          Highlight.t() | nil
        ) :: %{non_neg_integer() => [Highlight.styled_segment()]}
  defp build_highlight_segments_by_line(_lines, _first_line, _visible_line_map, _offsets, nil),
    do: %{}

  defp build_highlight_segments_by_line(
         lines,
         first_line,
         visible_line_map,
         line_byte_offsets,
         %Highlight{} = hl
       ) do
    source_lines =
      visible_line_map
      |> Enum.map(&source_highlight_line/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(fn buf_line ->
        {buf_line,
         {line_at(lines, buf_line, first_line), Map.get(line_byte_offsets, buf_line, 0)}}
      end)
      |> Enum.sort_by(fn {_buf_line, {_line_text, line_byte_offset}} -> line_byte_offset end)

    source_lines
    |> Enum.map(fn {_buf_line, line_with_offset} -> line_with_offset end)
    |> then(&Highlight.styles_for_visible_lines(hl, &1))
    |> then(fn highlight_segments -> Enum.zip(source_lines, highlight_segments) end)
    |> Map.new(fn {{buf_line, _line_with_offset}, segments} -> {buf_line, segments} end)
  end

  @spec source_highlight_line(DisplayMap.entry()) :: non_neg_integer() | nil
  defp source_highlight_line({buf_line, :normal}), do: buf_line
  defp source_highlight_line({buf_line, {:fold_start, _hidden_count}}), do: buf_line
  defp source_highlight_line(_entry), do: nil

  # Reuse only plain folded `:normal` rows; decoration-driven rows (folds,
  # virtual lines, blocks) recompose every frame to stay conservative (#2287).
  @spec build_visual_row_entry_retained(
          non_neg_integer(),
          term(),
          [String.t()],
          non_neg_integer(),
          Context.t(),
          folded_source_ctx(),
          non_neg_integer(),
          retain_ctx()
        ) :: {Row.t(), non_neg_integer(), boolean()}
  defp build_visual_row_entry_retained(
         buf_line,
         :normal,
         lines,
         first_line,
         ctx,
         source_ctx,
         index,
         retain_ctx
       ) do
    line_text = line_at(lines, buf_line, first_line)
    hl_segments = Map.get(source_ctx.highlight_segments_by_line, buf_line)
    row_id = Row.stable_id(:normal, durable_source_id(retain_ctx, buf_line))

    {row, input_hash, reused?} =
      compose_or_reuse(retain_ctx, row_id, {:fold_normal, line_text, hl_segments}, fn ->
        build_visual_row_entry(buf_line, :normal, lines, first_line, ctx, source_ctx, index)
      end)

    {Row.reposition(row, buf_line), input_hash, reused?}
  end

  defp build_visual_row_entry_retained(
         buf_line,
         entry_type,
         lines,
         first_line,
         ctx,
         source_ctx,
         index,
         retain_ctx
       ) do
    row = build_visual_row_entry(buf_line, entry_type, lines, first_line, ctx, source_ctx, index)

    {row, row_input_hash(retain_ctx, {:fold_other, row.row_id, row.content_hash}), false}
  end

  @spec next_visual_identity(non_neg_integer(), term(), map()) :: {non_neg_integer(), map()}
  defp next_visual_identity(buf_line, entry_type, counters) do
    case visual_identity_key(buf_line, entry_type) do
      nil ->
        {0, counters}

      key ->
        index = Map.get(counters, key, 0)
        {index, Map.put(counters, key, index + 1)}
    end
  end

  @spec visual_identity_key(non_neg_integer(), term()) :: term() | nil
  defp visual_identity_key(buf_line, {:virtual_line, _vt}), do: {buf_line, :virtual_line}
  defp visual_identity_key(buf_line, {:block, _block, _line_idx}), do: {buf_line, :block}
  defp visual_identity_key(_buf_line, _entry_type), do: nil

  @spec build_visual_row_entry(
          non_neg_integer(),
          term(),
          [String.t()],
          non_neg_integer(),
          Context.t(),
          folded_source_ctx(),
          non_neg_integer()
        ) :: Row.t()
  defp build_visual_row_entry(
         buf_line,
         :normal,
         lines,
         first_line,
         ctx,
         source_ctx,
         _index
       ) do
    line_text = line_at(lines, buf_line, first_line)
    line_byte_offset = Map.get(source_ctx.line_byte_offsets, buf_line, 0)
    hl_segments = Map.get(source_ctx.highlight_segments_by_line, buf_line)
    {composed, spans} = compose_line(line_text, hl_segments, ctx, buf_line, line_byte_offset)

    %Row{
      row_id: Row.stable_id(:normal, durable_source_id(source_ctx, buf_line)),
      row_type: :normal,
      buf_line: buf_line,
      text: composed,
      spans: spans,
      content_hash: Row.compute_hash(composed, spans)
    }
  end

  defp build_visual_row_entry(
         buf_line,
         {:fold_start, hidden_count},
         lines,
         first_line,
         ctx,
         source_ctx,
         _index
       ) do
    line_text = line_at(lines, buf_line, first_line)
    line_byte_offset = Map.get(source_ctx.line_byte_offsets, buf_line, 0)
    hl_segments = Map.get(source_ctx.highlight_segments_by_line, buf_line)
    {composed, spans} = compose_line(line_text, hl_segments, ctx, buf_line, line_byte_offset)
    {composed, spans} = append_fold_summary(composed, spans, hidden_count, ctx)

    %Row{
      row_id: Row.stable_id(:fold_start, durable_source_id(source_ctx, buf_line)),
      row_type: :fold_start,
      buf_line: buf_line,
      text: composed,
      spans: spans,
      content_hash: Row.compute_hash(composed, spans)
    }
  end

  defp build_visual_row_entry(
         buf_line,
         {:virtual_line, vt},
         _lines,
         _first_line,
         _ctx,
         source_ctx,
         visual_identity_index
       ) do
    text = virtual_text_to_string(vt)

    spans = virtual_text_spans(vt)

    %Row{
      row_id:
        Row.stable_decoration_id(
          :virtual_line,
          durable_source_id(source_ctx, buf_line),
          decoration_slot(source_ctx, buf_line, :virtual_line, vt.id)
        ),
      row_type: :virtual_line,
      buf_line: buf_line,
      visual_index: visual_identity_index,
      text: text,
      spans: spans,
      content_hash: Row.compute_hash(text, spans)
    }
  end

  defp build_visual_row_entry(
         buf_line,
         {:block, block, line_idx},
         _lines,
         _first_line,
         ctx,
         source_ctx,
         visual_identity_index
       ) do
    # Block decorations render via callback; capture the rendered text using the same text width as the draw path.
    rendered_lines = block.render.(ctx.content_w)
    normalized = BlockDecoration.normalize_render_result(rendered_lines)
    segments = Enum.at(normalized, line_idx, [])
    text = Enum.map_join(segments, fn {t, _style} -> t end)
    spans = segments_to_spans(segments)

    %Row{
      row_id:
        Row.stable_decoration_id(
          :block,
          durable_source_id(source_ctx, buf_line),
          decoration_slot(source_ctx, buf_line, :block, {block.id, line_idx})
        ),
      row_type: :block,
      buf_line: buf_line,
      visual_index: visual_identity_index,
      text: text,
      spans: spans,
      content_hash: Row.compute_hash(text, spans)
    }
  end

  defp build_visual_row_entry(
         buf_line,
         {:decoration_fold, fold},
         _lines,
         _first_line,
         _ctx,
         source_ctx,
         _index
       ) do
    hidden = FoldRegion.hidden_count(fold)
    text = " ··· #{hidden} lines"

    %Row{
      row_id:
        Row.stable_decoration_id(
          :fold_start,
          durable_source_id(source_ctx, buf_line),
          decoration_slot(source_ctx, buf_line, :decoration_fold, fold.id)
        ),
      row_type: :fold_start,
      buf_line: buf_line,
      text: text,
      spans: [],
      content_hash: Row.compute_hash(text, [])
    }
  end

  # ── Line composition ───────────────────────────────────────────────────

  # Composes the final display text and highlight spans for a line.
  #
  # Runs the shared composition pipeline: highlight segments are merged
  # with decorations, conceals are applied, and inline virtual text is
  # spliced in. The resulting segments are then converted to composed
  # text + Span structs.
  #
  # Both the draw path (Line.ex) and the semantic path (this builder)
  # use the same composition functions from Renderer.Composition,
  # guaranteeing identical output for the same input.
  @spec compose_line(
          String.t(),
          [Highlight.styled_segment()] | nil,
          Context.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {String.t(), [Span.t()]}
  defp compose_line(line_text, hl_segments, ctx, buf_line, line_byte_offset) do
    ctx = maybe_reveal_conceals(ctx, buf_line)

    # Start with highlight segments or plain text
    segments =
      case hl_segments do
        nil -> [{line_text, Minga.Core.Face.new()}]
        segs -> segs
      end

    # Merge decoration highlights (search matches, etc.)
    line_highlights = Decorations.highlights_for_line(ctx.decorations, buf_line)

    line_highlights =
      line_highlights ++ todo_highlight_ranges(line_text, buf_line, ctx, line_byte_offset)

    segments = Decorations.merge_highlights(segments, line_highlights, buf_line)

    # Apply conceals and inject inline virtual text (shared pipeline)
    segments = Composition.compose_segments(segments, ctx.decorations, buf_line)

    segments =
      if ctx.show_invisible,
        do: Composition.apply_invisible_chars(segments, ctx.tab_width, ctx.whitespace_face),
        else: segments

    # Convert to composed text + spans
    Composition.segments_to_text_and_spans(segments)
  end

  @spec maybe_reveal_conceals(Context.t(), non_neg_integer()) :: Context.t()
  defp maybe_reveal_conceals(
         %Context{cursor_line: buf_line, decorations: decorations} = ctx,
         buf_line
       ) do
    if Decorations.has_conceal_ranges?(decorations) do
      Context.with_decorations(ctx, Decorations.without_conceals(decorations))
    else
      ctx
    end
  end

  defp maybe_reveal_conceals(%Context{} = ctx, _buf_line), do: ctx

  @spec append_fold_summary(String.t(), [Span.t()], non_neg_integer(), Context.t()) ::
          {String.t(), [Span.t()]}
  defp append_fold_summary(composed, spans, hidden_count, ctx) do
    suffix = " ··· #{hidden_count} lines"
    start_col = Unicode.display_width(composed)
    end_col = start_col + Unicode.display_width(suffix)

    fold_span =
      Span.from_face(Minga.Core.Face.new(fg: ctx.gutter_colors.fold_fg), start_col, end_col)

    {composed <> suffix, Enum.concat(spans, [fold_span])}
  end

  @spec todo_highlight_ranges(String.t(), non_neg_integer(), Context.t(), non_neg_integer()) :: [
          HighlightRange.t()
        ]
  defp todo_highlight_ranges(line_text, buf_line, ctx, line_byte_offset) do
    line_text
    |> HlTodo.scan_line()
    |> Enum.filter(&todo_match_in_scope?(&1, ctx, line_text, line_byte_offset))
    |> Enum.map(&todo_highlight_range(&1, buf_line, ctx, line_text))
  end

  @spec todo_match_in_scope?(HlTodo.match(), Context.t(), String.t(), non_neg_integer()) ::
          boolean()
  defp todo_match_in_scope?(_match, %{highlight: nil}, _line_text, _line_byte_offset), do: true

  defp todo_match_in_scope?(
         {start_byte, end_byte, _keyword},
         %{highlight: highlight},
         line_text,
         line_byte_offset
       ) do
    if Highlight.has_spans?(highlight) do
      highlight
      |> Highlight.comment_ranges_for_line(line_text, line_byte_offset)
      |> Enum.any?(fn {comment_start, comment_end} ->
        start_byte >= comment_start and end_byte <= comment_end
      end)
    else
      true
    end
  end

  @spec todo_highlight_range(HlTodo.match(), non_neg_integer(), Context.t(), String.t()) ::
          HighlightRange.t()
  defp todo_highlight_range({start_byte, end_byte, keyword}, buf_line, ctx, line_text) do
    %HighlightRange{
      id: make_ref(),
      start: {buf_line, byte_offset_to_grapheme_index(line_text, start_byte)},
      end_: {buf_line, byte_offset_to_grapheme_index(line_text, end_byte)},
      style: Map.get(ctx.hl_todo_faces, keyword, Minga.Core.Face.new(bold: true)),
      priority: 10,
      group: :hl_todo
    }
  end

  @spec byte_offset_to_grapheme_index(String.t(), non_neg_integer()) :: non_neg_integer()
  defp byte_offset_to_grapheme_index(text, byte_offset) do
    text
    |> binary_part(0, min(byte_offset, byte_size(text)))
    |> String.length()
  rescue
    ArgumentError -> String.length(text)
  end

  # ── Cursor display coordinates ─────────────────────────────────────────

  @spec compute_display_cursor(
          non_neg_integer(),
          non_neg_integer(),
          Viewport.t(),
          FoldMap.t(),
          Decorations.t(),
          [visual_row_entry()],
          boolean()
        ) :: {non_neg_integer(), non_neg_integer()}
  defp compute_display_cursor(
         cursor_line,
         cursor_col,
         _viewport,
         _fold_map,
         decorations,
         visual_entries,
         true
       ) do
    compute_wrapped_display_cursor(cursor_line, cursor_col, decorations, visual_entries)
  end

  defp compute_display_cursor(
         cursor_line,
         cursor_col,
         viewport,
         fold_map,
         decorations,
         _visual_entries,
         false
       ) do
    visible_cursor =
      if FoldMap.empty?(fold_map) do
        cursor_line
      else
        FoldMap.buffer_to_visible(fold_map, cursor_line)
      end

    row = max(visible_cursor - viewport.top, 0)
    col = Decorations.buf_col_to_display_col(decorations, cursor_line, cursor_col)
    {row, col}
  end

  # True when the cursor's line is inside the visible viewport, so the caret and
  # cursorline should paint. After wheel free-scroll (#2684) the cursor can leave
  # the viewport without moving; off-screen we hide both rather than clamp them to
  # an edge row. Non-wrapped: the fold-visible cursor line must sit in
  # `[top, top + rows)`. Wrapped: a visible visual row must map back to the cursor
  # line.
  @spec cursor_on_screen?(
          non_neg_integer(),
          Viewport.t(),
          FoldMap.t(),
          [visual_row_entry()],
          non_neg_integer(),
          boolean()
        ) :: boolean()
  defp cursor_on_screen?(
         cursor_line,
         _viewport,
         _fold_map,
         visual_entries,
         visible_row_count,
         true
       ) do
    Enum.any?(visual_entries, fn entry ->
      entry.buf_line == cursor_line and entry.display_row >= 0 and
        entry.display_row < visible_row_count
    end)
  end

  defp cursor_on_screen?(
         cursor_line,
         viewport,
         fold_map,
         _visual_entries,
         visible_row_count,
         false
       ) do
    visible_cursor =
      if FoldMap.empty?(fold_map) do
        cursor_line
      else
        FoldMap.buffer_to_visible(fold_map, cursor_line)
      end

    visible_cursor >= viewport.top and visible_cursor < viewport.top + visible_row_count
  end

  @spec compute_wrapped_display_cursor(
          non_neg_integer(),
          non_neg_integer(),
          Decorations.t(),
          [visual_row_entry()]
        ) :: {non_neg_integer(), non_neg_integer()}
  defp compute_wrapped_display_cursor(cursor_line, cursor_col, decorations, visual_entries) do
    cursor_display_col = Decorations.buf_col_to_display_col(decorations, cursor_line, cursor_col)

    visual_entries
    |> Enum.filter(&(&1.buf_line == cursor_line))
    |> visual_entry_for_source_col(cursor_display_col)
    |> cursor_position_from_visual_entry(cursor_display_col)
  end

  @spec visual_entry_for_source_col([visual_row_entry()], non_neg_integer()) ::
          visual_row_entry() | nil
  defp visual_entry_for_source_col([], _cursor_display_col), do: nil

  defp visual_entry_for_source_col(entries, cursor_display_col) do
    Enum.find(entries, fn entry ->
      cursor_display_col >= entry.source_start_col and cursor_display_col < entry.source_end_col
    end) || Enum.at(entries, -1)
  end

  @spec cursor_position_from_visual_entry(visual_row_entry() | nil, non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp cursor_position_from_visual_entry(nil, cursor_display_col), do: {0, cursor_display_col}

  defp cursor_position_from_visual_entry(entry, cursor_display_col) do
    col = max(cursor_display_col - entry.source_start_col + entry.indent_width, 0)
    {entry.display_row, col}
  end

  @spec adjust_cursor_col_for_shape(
          non_neg_integer(),
          non_neg_integer(),
          RenderWindow.cursor_shape(),
          [Row.t()]
        ) :: non_neg_integer()
  defp adjust_cursor_col_for_shape(row, col, :block, visual_rows) do
    row_width = visual_rows |> Enum.at(row) |> visual_row_width()

    if row_width > 0 and col >= row_width do
      row_width - 1
    else
      col
    end
  end

  defp adjust_cursor_col_for_shape(_row, col, _shape, _visual_rows), do: col

  @spec visual_row_width(Row.t() | nil) :: non_neg_integer()
  defp visual_row_width(nil), do: 0
  defp visual_row_width(%Row{text: text}), do: Unicode.display_width(text)

  # ── Gutter ─────────────────────────────────────────────────────────────

  @spec build_gutter(
          WindowScroll.t(),
          Context.t(),
          RenderWindow.content_kind(),
          [visual_row_entry()]
        ) :: Gutter.t() | nil
  defp build_gutter(%WindowScroll{} = scroll, %Context{} = ctx, content_kind, visual_entries)
       when content_kind in [:buffer, :agent_chat] do
    %WindowScroll{
      win_id: win_id,
      win_layout: %{content: {content_row, content_col, full_width, content_height}},
      cursor_line: cursor_line,
      snapshot: snapshot,
      content_w: _content_w,
      line_number_style: line_number_style,
      is_active: is_active
    } = scroll

    line_count = max(snapshot.line_count, 0)

    metrics = gutter_metrics(scroll, :buffer)
    line_number_width = metrics.line_number_width
    sign_col_width = metrics.sign_col_width

    %Gutter{
      window_id: win_id,
      content_row: content_row,
      content_col: content_col,
      content_height: content_height,
      is_active: is_active,
      content_width: full_width,
      cursor_line: max(cursor_line, 0),
      line_number_style: line_number_style,
      line_number_width: line_number_width,
      sign_col_width: sign_col_width,
      entries: build_gutter_entries(scroll, ctx, line_count, visual_entries)
    }
  end

  defp build_gutter(_scroll, _ctx, _content_kind, _visual_entries), do: nil

  @spec build_geometry(state(), WindowScroll.t(), RenderWindow.content_kind()) :: PaneGeometry.t()
  defp build_geometry(state, %WindowScroll{} = scroll, content_kind) do
    metrics = gutter_metrics(scroll, content_kind)
    gutter_width = GutterMetrics.total_width(metrics)
    content_rect = scroll.win_layout.content
    total_rect = Map.get(scroll.win_layout, :total, content_rect)
    {row, col, width, height} = content_rect
    gutter_rect = {row, col, min(gutter_width, width), height}
    text_col = col + min(gutter_width, width)
    text_width = max(width - gutter_width, 0)
    text_rect = {row, text_col, text_width, height}

    %PaneGeometry{
      window_id: scroll.win_id,
      total_rect: total_rect,
      content_rect: content_rect,
      text_rect: text_rect,
      gutter_rect: gutter_rect,
      clip_rect: text_rect,
      viewport: viewport_summary(scroll, text_width),
      gutter_metrics: metrics,
      hit_regions: hit_regions(state, scroll.win_id, text_rect, gutter_rect, metrics)
    }
  end

  @spec gutter_metrics(WindowScroll.t(), RenderWindow.content_kind()) :: GutterMetrics.t()
  defp gutter_metrics(%WindowScroll{} = scroll, content_kind)
       when content_kind in [:buffer, :agent_chat] do
    line_count = max(scroll.snapshot.line_count, 0)

    line_number_width =
      if scroll.line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)

    %GutterMetrics{
      line_number_width: line_number_width,
      sign_col_width: EditorGutter.sign_column_width() + EditorGutter.fold_column_width()
    }
  end

  defp gutter_metrics(_scroll, _content_kind) do
    %GutterMetrics{line_number_width: 0, sign_col_width: 0}
  end

  @spec viewport_summary(WindowScroll.t(), non_neg_integer()) :: RenderViewport.t()
  defp viewport_summary(%WindowScroll{} = scroll, text_width) do
    %RenderViewport{
      top: scroll.viewport.top,
      left: scroll.viewport.left,
      rows: Viewport.content_rows(scroll.viewport),
      cols: text_width,
      total_lines: max(scroll.snapshot.line_count, 0),
      visual_row_offset: scroll.viewport.visual_row_offset,
      total_visual_rows: total_visual_rows(scroll)
    }
  end

  @spec total_visual_rows(WindowScroll.t()) :: non_neg_integer()
  defp total_visual_rows(%WindowScroll{total_visual_rows: total})
       when is_integer(total) and total > 0,
       do: total

  defp total_visual_rows(%WindowScroll{wrap_on: false, snapshot: snapshot}),
    do: max(snapshot.line_count, 0)

  defp total_visual_rows(%WindowScroll{} = scroll) do
    scroll.lines
    |> WrapMap.compute(max(scroll.content_w, 1),
      breakindent: Map.get(scroll.snapshot.options, :breakindent, true),
      linebreak: Map.get(scroll.snapshot.options, :linebreak, true),
      oracle: scroll.width_oracle,
      tab_width: Map.get(scroll.snapshot.options, :tab_width, 2)
    )
    |> WrapMap.visual_row_count()
  end

  @spec hit_regions(
          state(),
          non_neg_integer(),
          PaneGeometry.rect(),
          PaneGeometry.rect(),
          GutterMetrics.t()
        ) :: [HitRegion.t()]
  defp hit_regions(state, window_id, text_rect, gutter_rect, %GutterMetrics{} = metrics) do
    [text_hit_region(window_id, text_rect)] ++
      gutter_hit_regions(window_id, gutter_rect, metrics) ++
      status_bar_hit_regions(state, window_id) ++
      divider_hit_regions(state, window_id)
  end

  @spec text_hit_region(non_neg_integer(), PaneGeometry.rect()) :: HitRegion.t()
  defp text_hit_region(window_id, rect) do
    %HitRegion{kind: :text, rect: rect, window_id: window_id, target: %{window_id: window_id}}
  end

  @spec gutter_hit_regions(non_neg_integer(), PaneGeometry.rect(), GutterMetrics.t()) :: [
          HitRegion.t()
        ]
  defp gutter_hit_regions(_window_id, {_row, _col, 0, _height}, _metrics), do: []

  defp gutter_hit_regions(
         window_id,
         {row, col, width, height} = gutter_rect,
         %GutterMetrics{} = metrics
       ) do
    fold_col = col + max(metrics.sign_col_width - 1, 0)
    fold_width = if metrics.sign_col_width > 0 and fold_col < col + width, do: 1, else: 0

    [
      %HitRegion{
        kind: :gutter,
        rect: gutter_rect,
        window_id: window_id,
        target: %{window_id: window_id}
      },
      %HitRegion{
        kind: :fold_control,
        rect: {row, fold_col, fold_width, height},
        window_id: window_id,
        target: %{window_id: window_id}
      }
    ]
    |> Enum.reject(fn %HitRegion{rect: {_row, _col, region_width, region_height}} ->
      region_width == 0 or region_height == 0
    end)
  end

  @spec status_bar_hit_regions(state(), non_neg_integer()) :: [HitRegion.t()]
  defp status_bar_hit_regions(state, window_id) do
    case Layout.get(state).status_bar do
      nil ->
        []

      rect ->
        [
          %HitRegion{
            kind: :status_bar,
            rect: rect,
            window_id: window_id,
            target: %{window_id: window_id}
          }
        ]
    end
  end

  @spec divider_hit_regions(state(), non_neg_integer()) :: [HitRegion.t()]
  defp divider_hit_regions(state, window_id) do
    layout = Layout.get(state)
    windows = state.workspace.windows

    verticals =
      if windows.tree == nil do
        []
      else
        collect_vertical_dividers(windows.tree, layout.editor_area)
      end

    horizontals =
      Enum.map(layout.horizontal_separators, fn {row, col, width, _filename} ->
        {row, col, width, 1}
      end)

    Enum.map(verticals ++ horizontals, fn rect ->
      %HitRegion{
        kind: :divider,
        rect: rect,
        window_id: window_id,
        target: %{window_id: window_id}
      }
    end)
  end

  @spec collect_vertical_dividers(WindowTree.t(), Layout.rect()) :: [PaneGeometry.rect()]
  defp collect_vertical_dividers({:leaf, _id}, _rect), do: []

  defp collect_vertical_dividers(
         {:split, :vertical, left, right, size},
         {row, col, width, height}
       ) do
    usable = width - 1
    left_width = WindowTree.clamp_size(size, usable)
    right_width = max(usable - left_width, 1)
    separator_col = col + left_width

    [{row, separator_col, 1, height}] ++
      collect_vertical_dividers(left, {row, col, left_width, height}) ++
      collect_vertical_dividers(right, {row, separator_col + 1, right_width, height})
  end

  defp collect_vertical_dividers(
         {:split, :horizontal, top, bottom, size},
         {row, col, width, height}
       ) do
    top_height = WindowTree.clamp_size(size, height)
    bottom_height = max(height - top_height, 1)

    collect_vertical_dividers(top, {row, col, width, top_height}) ++
      collect_vertical_dividers(bottom, {row + top_height, col, width, bottom_height})
  end

  @spec build_gutter_entries(
          WindowScroll.t(),
          Context.t(),
          non_neg_integer(),
          [visual_row_entry()]
        ) :: [GutterEntry.t()]
  defp build_gutter_entries(_scroll, _ctx, 0, _visual_entries), do: []

  defp build_gutter_entries(
         %WindowScroll{} = scroll,
         %Context{} = ctx,
         line_count,
         visual_entries
       ) do
    fold_ranges = scroll.window.fold_ranges
    fold_start_lines = MapSet.new(fold_ranges, & &1.start_line)
    fold_end_by_start = Map.new(fold_ranges, fn range -> {range.start_line, range.end_line} end)

    Enum.map(visual_entries, fn entry ->
      entry
      |> visual_gutter_entry()
      |> resolve_gutter_entry(fold_start_lines, fold_end_by_start, ctx, line_count)
    end)
  end

  @spec visual_gutter_entry(visual_row_entry()) :: {non_neg_integer(), term()}
  defp visual_gutter_entry(%{buf_line: buf_line, row: %Row{row_type: row_type}}),
    do: {buf_line, row_type}

  @spec resolve_gutter_entry(
          {non_neg_integer(), term()},
          MapSet.t(non_neg_integer()),
          %{non_neg_integer() => non_neg_integer()},
          Context.t(),
          non_neg_integer()
        ) :: GutterEntry.t()
  defp resolve_gutter_entry(
         {buf_line, :wrap_continuation},
         _fold_start_lines,
         _fold_end_by_start,
         _ctx,
         _line_count
       ) do
    blank_gutter_entry(buf_line, :wrap_continuation)
  end

  defp resolve_gutter_entry(
         {buf_line, row_type},
         _fold_start_lines,
         _fold_end_by_start,
         _ctx,
         _line_count
       )
       when row_type in [:virtual_line, :block] do
    blank_gutter_entry(buf_line, :blank)
  end

  defp resolve_gutter_entry(
         {buf_line, row_type},
         fold_start_lines,
         fold_end_by_start,
         ctx,
         line_count
       )
       when buf_line < line_count do
    sign_type = resolve_sign_type(buf_line, ctx.diagnostic_signs, ctx.git_signs)
    display_type = resolve_display_type(row_type, fold_start_lines, buf_line)
    fold_end_line = Map.get(fold_end_by_start, buf_line, 0xFFFF_FFFF)

    case sign_type do
      :none ->
        resolve_annotation_entry(buf_line, display_type, fold_end_line, ctx.decorations)

      _ ->
        %GutterEntry{
          buf_line: buf_line,
          display_type: display_type,
          sign_type: sign_type,
          fold_end_line: fold_end_line
        }
    end
  end

  defp resolve_gutter_entry(
         {buf_line, _row_type},
         _fold_start_lines,
         _fold_end_by_start,
         _ctx,
         _line_count
       ) do
    blank_gutter_entry(buf_line, :normal)
  end

  @spec blank_gutter_entry(non_neg_integer(), GutterEntry.display_type()) :: GutterEntry.t()
  defp blank_gutter_entry(buf_line, display_type) do
    %GutterEntry{
      buf_line: buf_line,
      display_type: display_type,
      sign_type: :none,
      fold_end_line: 0xFFFF_FFFF
    }
  end

  @spec resolve_display_type(term(), MapSet.t(non_neg_integer()), non_neg_integer()) ::
          GutterEntry.display_type()
  defp resolve_display_type(:fold_start, _fold_start_lines, _buf_line), do: :fold_start
  defp resolve_display_type({:fold_start, _hidden}, _fold_start_lines, _buf_line), do: :fold_start

  defp resolve_display_type({:decoration_fold, _fold}, _fold_start_lines, _buf_line),
    do: :fold_start

  defp resolve_display_type(:normal, fold_start_lines, buf_line) do
    if MapSet.member?(fold_start_lines, buf_line), do: :fold_open, else: :normal
  end

  defp resolve_display_type(_row_type, _fold_start_lines, _buf_line), do: :normal

  @spec resolve_annotation_entry(
          non_neg_integer(),
          GutterEntry.display_type(),
          non_neg_integer(),
          Decorations.t()
        ) :: GutterEntry.t()
  defp resolve_annotation_entry(
         buf_line,
         display_type,
         fold_end_line,
         %Decorations{} = decorations
       ) do
    decorations
    |> Decorations.annotations_for_line(buf_line)
    |> Enum.filter(fn ann -> ann.kind == :gutter_icon end)
    |> annotation_gutter_entry(buf_line, display_type, fold_end_line)
  end

  @spec annotation_gutter_entry(
          [Decorations.LineAnnotation.t()],
          non_neg_integer(),
          GutterEntry.display_type(),
          non_neg_integer()
        ) :: GutterEntry.t()
  defp annotation_gutter_entry([], buf_line, display_type, fold_end_line) do
    %GutterEntry{
      buf_line: buf_line,
      display_type: display_type,
      sign_type: :none,
      fold_end_line: fold_end_line
    }
  end

  defp annotation_gutter_entry([ann | _], buf_line, display_type, fold_end_line) do
    %GutterEntry{
      buf_line: buf_line,
      display_type: display_type,
      sign_type: :annotation,
      fold_end_line: fold_end_line,
      sign_fg: ann.fg,
      sign_text: String.slice(ann.text, 0, 2)
    }
  end

  @spec resolve_sign_type(non_neg_integer(), %{non_neg_integer() => atom()}, %{
          non_neg_integer() => atom()
        }) :: GutterEntry.sign_type()
  defp resolve_sign_type(buf_line, diag_signs, git_signs) do
    case Map.get(diag_signs, buf_line) do
      :error -> :diag_error
      :warning -> :diag_warning
      :info -> :diag_info
      :hint -> :diag_hint
      :diag_advisory -> :diag_advisory
      nil -> resolve_git_sign(buf_line, git_signs)
    end
  end

  @spec resolve_git_sign(non_neg_integer(), %{non_neg_integer() => atom()}) ::
          GutterEntry.sign_type()
  defp resolve_git_sign(buf_line, git_signs) do
    case Map.get(git_signs, buf_line) do
      :added -> :git_added
      :modified -> :git_modified
      :removed -> :git_removed
      :deleted -> :git_deleted
      _ -> :none
    end
  end

  # ── Cursorline ─────────────────────────────────────────────────────────

  @spec build_cursorline(non_neg_integer(), non_neg_integer(), boolean(), boolean(), Context.t()) ::
          Cursorline.t() | nil
  defp build_cursorline(_content_row, _cursor_row, false, _on_screen?, _ctx), do: nil

  # The cursor has scrolled off-viewport (#2684): no cursorline, so it disappears
  # with its line instead of ghosting at the edge row, and returns on scroll-back.
  defp build_cursorline(_content_row, _cursor_row, true, false, _ctx), do: nil

  defp build_cursorline(content_row, cursor_row, true, true, %Context{cursorline_bg: bg})
       when is_integer(bg), do: %Cursorline{row: content_row + cursor_row, bg_rgb: bg}

  defp build_cursorline(_content_row, _cursor_row, true, true, %Context{}),
    do: Cursorline.disabled()

  # ── Indent guides ──────────────────────────────────────────────────────

  @spec build_indent_guides(WindowScroll.t(), Context.t(), RenderWindow.content_kind()) ::
          IndentGuides.t()
  defp build_indent_guides(%WindowScroll{win_id: win_id}, _ctx, content_kind)
       when content_kind != :buffer, do: IndentGuides.empty(win_id)

  defp build_indent_guides(%WindowScroll{} = scroll, %Context{} = ctx, :buffer) do
    if indent_guides_enabled?() do
      lines =
        scroll.lines
        |> Enum.slice(scroll.visible_row_start_index, Viewport.content_rows(scroll.viewport))

      {guides, levels} = IndentGuide.compute_with_levels(lines, ctx.tab_width, ctx.cursor_col)
      indent_guides_from_guides(scroll.win_id, ctx.tab_width, guides, levels)
    else
      IndentGuides.empty(scroll.win_id)
    end
  end

  @spec indent_guides_enabled?() :: boolean()
  defp indent_guides_enabled? do
    Config.get(:indent_guides)
  catch
    :exit, _ -> true
  end

  @spec indent_guides_from_guides(non_neg_integer(), pos_integer(), [IndentGuide.guide()], [
          non_neg_integer()
        ]) :: IndentGuides.t()
  defp indent_guides_from_guides(win_id, tab_width, [], _levels),
    do: %IndentGuides{
      window_id: win_id,
      tab_width: tab_width,
      active_guide_col: 0xFFFF,
      guide_cols: [],
      line_indent_levels: []
    }

  defp indent_guides_from_guides(win_id, tab_width, guides, levels) do
    active_guide = Enum.find(guides, fn guide -> guide.active end)
    active_col = if active_guide, do: active_guide.col, else: 0xFFFF

    %IndentGuides{
      window_id: win_id,
      tab_width: tab_width,
      active_guide_col: active_col,
      guide_cols: Enum.map(guides, & &1.col),
      line_indent_levels: levels
    }
  end

  # ── Overlays ───────────────────────────────────────────────────────────

  @spec build_selection(
          Selection.visual_selection(),
          Viewport.t(),
          pos_integer(),
          [visual_row_entry()],
          boolean()
        ) :: Selection.t() | nil
  defp build_selection(selection, viewport, visible_rows, _visual_entries, false) do
    Selection.from_visual_selection(
      selection,
      viewport.top,
      visible_rows,
      viewport.left,
      viewport.cols
    )
  end

  defp build_selection(nil, _viewport, _visible_rows, _visual_entries, true), do: nil

  defp build_selection(
         {:char, {sl, sc}, {el, ec}},
         _viewport,
         _visible_rows,
         visual_entries,
         true
       ) do
    build_wrapped_char_selection(sl, sc, el, ec, visual_entries)
  end

  defp build_selection(
         {:line, start_line, end_line},
         _viewport,
         _visible_rows,
         visual_entries,
         true
       ) do
    build_wrapped_line_selection(start_line, end_line, visual_entries)
  end

  @spec build_search_matches(
          [Minga.Editing.Search.Match.t()],
          Minga.Editing.Search.Match.t() | nil,
          Viewport.t(),
          non_neg_integer(),
          [visual_row_entry()],
          boolean()
        ) :: [SearchMatch.t()]
  defp build_search_matches(
         matches,
         confirm_match,
         viewport,
         viewport_bottom,
         _visual_entries,
         false
       ) do
    SearchMatch.from_context_matches(matches, confirm_match, viewport.top, viewport_bottom)
  end

  defp build_search_matches(
         matches,
         confirm_match,
         _viewport,
         _viewport_bottom,
         visual_entries,
         true
       ) do
    Enum.flat_map(matches, fn %{line: line, col: col, length: len} = match ->
      project_byte_range(line, col, line, col + len, visual_entries, fn row,
                                                                        start_col,
                                                                        _end_row,
                                                                        end_col ->
        %SearchMatch{
          row: row,
          start_col: start_col,
          end_col: end_col,
          is_current: confirm_match != nil and match == confirm_match
        }
      end)
    end)
  end

  @spec build_diagnostic_ranges(
          String.t() | nil,
          Viewport.t(),
          pos_integer(),
          [visual_row_entry()],
          boolean(),
          [String.t()],
          non_neg_integer()
        ) :: [DiagnosticRange.t()]
  defp build_diagnostic_ranges(
         nil,
         _viewport,
         _visible_rows,
         _visual_entries,
         _wrapped?,
         _lines,
         _first_line
       ),
       do: []

  defp build_diagnostic_ranges(
         path,
         viewport,
         visible_rows,
         visual_entries,
         wrapped?,
         lines,
         first_line
       )
       when is_binary(path) do
    uri = SyncServer.path_to_uri(path)

    case Diagnostics.for_uri(uri) do
      [] ->
        []

      diagnostics ->
        viewport_bottom = viewport.top + visible_rows
        line_cache = diagnostic_line_cache(diagnostics, lines, first_line)

        if wrapped? do
          Enum.flat_map(
            diagnostics,
            &diagnostic_to_wrapped_ranges(&1, visual_entries, line_cache)
          )
        else
          DiagnosticRange.from_diagnostics(diagnostics, viewport.top, viewport_bottom, line_cache)
        end
    end
  end

  @spec diagnostic_line_cache([Diagnostic.t()], [String.t()], non_neg_integer()) :: %{
          non_neg_integer() => String.t()
        }
  defp diagnostic_line_cache(diagnostics, lines, first_line) do
    diagnostics
    |> Enum.flat_map(fn diag -> [diag.range.start_line, diag.range.end_line] end)
    |> Enum.uniq()
    |> Map.new(fn line -> {line, line_at(lines, line, first_line)} end)
  end

  @spec diagnostic_to_wrapped_ranges(Diagnostic.t(), [visual_row_entry()], %{
          non_neg_integer() => String.t()
        }) :: [DiagnosticRange.t()]
  defp diagnostic_to_wrapped_ranges(%Diagnostic{} = diag, visual_entries, line_cache) do
    {start_line, start_byte} =
      Diagnostic.start_position(diag, Map.get(line_cache, diag.range.start_line, ""))

    {end_line, end_byte} =
      Diagnostic.end_position(diag, Map.get(line_cache, diag.range.end_line, ""))

    project_byte_range(
      start_line,
      start_byte,
      end_line,
      end_byte,
      visual_entries,
      fn start_row, start_col, end_row, end_col ->
        %DiagnosticRange{
          start_row: start_row,
          start_col: start_col,
          end_row: end_row,
          end_col: end_col,
          severity: diag.severity
        }
      end
    )
  end

  # ── Document highlights ─────────────────────────────────────────────────

  @spec build_document_highlights(
          [Minga.LSP.DocumentHighlight.t()] | nil,
          Viewport.t(),
          non_neg_integer(),
          [visual_row_entry()],
          boolean()
        ) :: [DocumentHighlight.t()]
  defp build_document_highlights(nil, _viewport, _bottom, _visual_entries, _wrapped?), do: []
  defp build_document_highlights([], _viewport, _bottom, _visual_entries, _wrapped?), do: []

  defp build_document_highlights(highlights, viewport, viewport_bottom, _visual_entries, false) do
    highlights
    |> Enum.filter(fn hl ->
      hl.start_line < viewport_bottom and hl.end_line >= viewport.top
    end)
    |> Enum.map(fn hl ->
      %DocumentHighlight{
        start_row: hl.start_line - viewport.top,
        start_col: hl.start_col,
        end_row: hl.end_line - viewport.top,
        end_col: hl.end_col,
        kind: hl.kind
      }
    end)
  end

  defp build_document_highlights(highlights, _viewport, _viewport_bottom, visual_entries, true) do
    Enum.flat_map(highlights, fn hl ->
      project_range(
        hl.start_line,
        hl.start_col,
        hl.end_line,
        hl.end_col,
        visual_entries,
        fn start_row, start_col, end_row, end_col ->
          %DocumentHighlight{
            start_row: start_row,
            start_col: start_col,
            end_row: end_row,
            end_col: end_col,
            kind: hl.kind
          }
        end
      )
    end)
  end

  # ── Line annotations ──────────────────────────────────────────────────

  @spec build_annotations(
          Decorations.t(),
          non_neg_integer(),
          non_neg_integer(),
          [visual_row_entry()],
          boolean()
        ) :: [Annotation.t()]
  defp build_annotations(
         %Decorations{annotations: []},
         _top,
         _bottom,
         _visual_entries,
         _wrapped?
       ),
       do: []

  defp build_annotations(
         %Decorations{} = decorations,
         viewport_top,
         viewport_bottom,
         _visual_entries,
         false
       ) do
    decorations.annotations
    |> Enum.filter(fn ann ->
      ann.line >= viewport_top and ann.line < viewport_bottom
    end)
    |> Enum.sort_by(fn ann -> {ann.line, ann.priority} end)
    |> Enum.map(fn ann ->
      %Annotation{
        row: ann.line - viewport_top,
        kind: ann.kind,
        fg: ann.fg,
        bg: ann.bg,
        text: ann.text
      }
    end)
  end

  defp build_annotations(
         %Decorations{} = decorations,
         _viewport_top,
         _viewport_bottom,
         visual_entries,
         true
       ) do
    decorations.annotations
    |> Enum.sort_by(fn ann -> {ann.line, ann.priority} end)
    |> Enum.flat_map(fn ann ->
      case first_visual_entry_for_line(visual_entries, ann.line) do
        nil ->
          []

        entry ->
          [
            %Annotation{
              row: entry.display_row,
              kind: ann.kind,
              fg: ann.fg,
              bg: ann.bg,
              text: ann.text
            }
          ]
      end
    end)
  end

  @spec build_wrapped_char_selection(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [visual_row_entry()]
        ) :: Selection.t() | nil
  defp build_wrapped_char_selection(start_line, start_col, end_line, end_col, visual_entries) do
    selected_entries = visual_entries_for_line_range(visual_entries, start_line, end_line)

    with [_ | _] <- selected_entries,
         start_entry <- selection_endpoint_entry(selected_entries, start_line, start_col, :first),
         end_entry <- selection_endpoint_entry(selected_entries, end_line, end_col, :last) do
      %Selection{
        type: :char,
        start_row: start_entry.display_row,
        start_col: selection_visual_col(start_entry, start_col, :start),
        end_row: end_entry.display_row,
        end_col: selection_visual_col(end_entry, end_col, :end)
      }
    else
      _ -> nil
    end
  end

  @spec build_wrapped_line_selection(non_neg_integer(), non_neg_integer(), [visual_row_entry()]) ::
          Selection.t() | nil
  defp build_wrapped_line_selection(start_line, end_line, visual_entries) do
    case visual_entries_for_line_range(visual_entries, start_line, end_line) do
      [] ->
        nil

      entries ->
        start_entry = hd(entries)
        end_entry = Enum.at(entries, -1)

        %Selection{
          type: :line,
          start_row: start_entry.display_row,
          start_col: 0,
          end_row: end_entry.display_row,
          end_col: 0
        }
    end
  end

  @spec selection_endpoint_entry(
          [visual_row_entry()],
          non_neg_integer(),
          non_neg_integer(),
          :first | :last
        ) :: visual_row_entry()
  defp selection_endpoint_entry(entries, line, col, fallback) do
    line_entries = Enum.filter(entries, &(&1.buf_line == line))

    if line_entries == [] do
      endpoint_fallback(entries, fallback)
    else
      visual_entry_for_source_col(line_entries, col) || endpoint_fallback(entries, fallback)
    end
  end

  @spec endpoint_fallback([visual_row_entry()], :first | :last) :: visual_row_entry()
  defp endpoint_fallback(entries, :first), do: hd(entries)
  defp endpoint_fallback(entries, :last), do: Enum.at(entries, -1)

  @spec visual_entries_for_line_range([visual_row_entry()], non_neg_integer(), non_neg_integer()) ::
          [
            visual_row_entry()
          ]
  defp visual_entries_for_line_range(visual_entries, start_line, end_line) do
    Enum.filter(visual_entries, fn entry ->
      entry.buf_line >= start_line and entry.buf_line <= end_line
    end)
  end

  @spec first_visual_entry_for_line([visual_row_entry()], non_neg_integer()) ::
          visual_row_entry() | nil
  defp first_visual_entry_for_line(visual_entries, line) do
    Enum.find(visual_entries, &(&1.buf_line == line))
  end

  @spec project_range(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [visual_row_entry()],
          (non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer() -> term())
        ) :: [term()]
  defp project_range(start_line, start_col, end_line, end_col, visual_entries, build_range) do
    visual_entries
    |> visual_entries_for_line_range(start_line, end_line)
    |> Enum.flat_map(
      &project_entry_range(&1, start_line, start_col, end_line, end_col, build_range)
    )
  end

  @spec project_entry_range(
          visual_row_entry(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          (non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer() -> term())
        ) :: [term()]
  defp project_entry_range(entry, start_line, start_col, end_line, end_col, build_range) do
    range_start =
      if entry.buf_line == start_line,
        do: max(start_col, entry.source_start_col),
        else: entry.source_start_col

    range_end =
      if entry.buf_line == end_line,
        do: min(end_col, entry.source_end_col),
        else: entry.source_end_col

    if range_end > range_start do
      [
        build_range.(
          entry.display_row,
          visual_col_for_source_col(entry, range_start),
          entry.display_row,
          visual_col_for_source_col(entry, range_end)
        )
      ]
    else
      []
    end
  end

  @spec project_byte_range(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [visual_row_entry()],
          (non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer() -> term())
        ) :: [term()]
  defp project_byte_range(start_line, start_byte, end_line, end_byte, visual_entries, build_range) do
    visual_entries
    |> visual_entries_for_line_range(start_line, end_line)
    |> Enum.flat_map(
      &project_entry_byte_range(&1, start_line, start_byte, end_line, end_byte, build_range)
    )
  end

  @spec project_entry_byte_range(
          visual_row_entry(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          (non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer() -> term())
        ) :: [term()]
  defp project_entry_byte_range(entry, start_line, start_byte, end_line, end_byte, build_range) do
    range_start =
      if entry.buf_line == start_line,
        do: max(start_byte, entry.source_start_byte),
        else: entry.source_start_byte

    range_end =
      if entry.buf_line == end_line,
        do: min(end_byte, entry.source_end_byte),
        else: entry.source_end_byte

    if range_end > range_start do
      [
        build_range.(
          entry.display_row,
          visual_col_for_source_byte(entry, range_start),
          entry.display_row,
          visual_col_for_source_byte(entry, range_end)
        )
      ]
    else
      []
    end
  end

  @spec selection_visual_col(visual_row_entry(), non_neg_integer(), :start | :end) ::
          non_neg_integer()
  defp selection_visual_col(entry, source_col, :start) when source_col <= entry.source_start_col,
    do: 0

  defp selection_visual_col(entry, source_col, :end) when source_col >= entry.source_end_col,
    do: entry.row_width

  defp selection_visual_col(entry, source_col, _endpoint),
    do: visual_col_for_source_col(entry, source_col)

  @spec visual_col_for_source_byte(visual_row_entry(), non_neg_integer()) :: non_neg_integer()
  defp visual_col_for_source_byte(entry, source_byte) do
    source_col = Unicode.display_col(entry.source_text, source_byte)
    visual_col_for_source_col(entry, source_col)
  end

  @spec visual_col_for_source_col(visual_row_entry(), non_neg_integer()) :: non_neg_integer()
  defp visual_col_for_source_col(entry, source_col) do
    source_col
    |> min(entry.source_end_col)
    |> max(entry.source_start_col)
    |> Kernel.-(entry.source_start_col)
    |> Kernel.+(entry.indent_width)
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  @spec line_at([String.t()], non_neg_integer(), non_neg_integer()) :: String.t()
  defp line_at(lines, buf_line, first_line) do
    idx = buf_line - first_line

    if idx >= 0 and idx < length(lines) do
      Enum.at(lines, idx, "")
    else
      ""
    end
  end

  @spec build_lines_with_offsets([String.t()], non_neg_integer()) ::
          [{String.t(), non_neg_integer()}]
  defp build_lines_with_offsets(lines, first_byte_off) do
    {pairs_rev, _} =
      Enum.reduce(lines, {[], first_byte_off}, fn line, {acc, off} ->
        {[{line, off} | acc], off + byte_size(line) + 1}
      end)

    Enum.reverse(pairs_rev)
  end

  @spec build_line_byte_offsets([String.t()], non_neg_integer(), non_neg_integer()) :: %{
          non_neg_integer() => non_neg_integer()
        }
  defp build_line_byte_offsets(lines, first_line, first_byte_off) do
    lines
    |> build_lines_with_offsets(first_byte_off)
    |> Enum.with_index(first_line)
    |> Map.new(fn {{_line_text, line_byte_offset}, buf_line} ->
      {buf_line, line_byte_offset}
    end)
  end

  @spec virtual_text_to_string(Decorations.VirtualText.t()) :: String.t()
  defp virtual_text_to_string(%{segments: segments}) do
    Enum.map_join(segments, fn {text, _style} -> text end)
  end

  @spec virtual_text_spans(Decorations.VirtualText.t()) :: [Span.t()]
  defp virtual_text_spans(%{segments: segments}) do
    segments_to_spans(segments)
  end

  @spec segments_to_spans([{String.t(), Minga.Core.Face.t()}]) :: [Span.t()]
  defp segments_to_spans(segments) do
    {spans, _col} =
      Enum.reduce(segments, {[], 0}, fn {text, style}, {acc, col} ->
        width = Unicode.display_width(text)

        if width > 0 do
          span = Span.from_face(style, col, col + width, font_id_for_face(style))
          {[span | acc], col + width}
        else
          {acc, col}
        end
      end)

    Enum.reverse(spans)
  end

  @spec font_id_for_face(Minga.Core.Face.t()) :: non_neg_integer()
  defp font_id_for_face(%Minga.Core.Face{font_family: nil}), do: 0

  defp font_id_for_face(%Minga.Core.Face{font_family: family}) when is_binary(family) do
    case FontRegistry.process_registry() do
      nil ->
        0

      registry ->
        {font_id, updated_registry, _new?} =
          FontRegistry.get_or_register(registry, family)

        FontRegistry.put_process_registry(updated_registry)
        font_id
    end
  end
end
