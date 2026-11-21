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
  alias Minga.Diagnostics.Diagnostic
  alias Minga.Editing
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
  alias MingaEditor.Layout
  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.RenderModel.Window.SourceOffsetMap
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.RenderPipeline.ContentHelpers
  alias MingaEditor.Renderer.Composition
  alias MingaEditor.Renderer.Context
  alias MingaEditor.Renderer.RenderWindow, as: RendererWindow
  alias Minga.RenderModel.Window, as: RenderWindow
  alias Minga.RenderModel.Window.ContentDigest
  alias MingaEditor.RenderModel.Window.BuildResult
  alias MingaEditor.RenderModel.Window.ResidentBuild
  alias MingaEditor.RenderModel.Window.ResidentSemanticState
  alias MingaEditor.Renderer.SearchHighlight
  alias MingaEditor.Renderer.TextPresentation
  alias MingaEditor.Renderer.WrapLayout
  alias MingaEditor.RenderModel.Window.VisualRow
  alias Minga.RenderModel.Window.Annotation
  alias Minga.RenderModel.Window.Cursorline
  alias Minga.RenderModel.Window.DiagnosticRange
  alias Minga.RenderModel.Window.DocumentHighlight
  alias Minga.RenderModel.Window.Gutter
  alias Minga.RenderModel.Window.Gutter.ResidentRows
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
  alias MingaEditor.UI.Highlight
  alias MingaEditor.UI.FontRegistry

  @type state :: EditorState.t() | MingaEditor.RenderPipeline.Input.t()
  @typep visual_row_entry :: VisualRow.t()
  @type build_stats :: BuildResult.t()

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
           source: (non_neg_integer() -> {String.t(), non_neg_integer()}),
           highlight_segments_by_line: %{non_neg_integer() => [Highlight.styled_segment()]},
           line_identity: LineIdentity.t() | nil,
           decoration_slots: %{optional(term()) => Row.row_slot()}
         }

  @doc """
  Builds a `RenderWindow` for one editor window.

  Called from the Content stage with the same `WindowScroll` and
  `Context` that drive the draw-based rendering.
  """
  @spec build(state(), WindowScroll.t(), Context.t(), FontRegistry.t(), keyword()) ::
          {RenderWindow.t(), FontRegistry.t()}
  def build(state, scroll, ctx, font_registry, opts \\ []) do
    {window, _stats, font_registry} = build_with_stats(state, scroll, ctx, font_registry, opts)
    {window, font_registry}
  end

  @doc """
  Builds a `RenderWindow` and reports retained-row statistics (#2287).

  Identical output to `build/4` but also returns how many rows were freshly
  rasterized and the retained-row map to carry into the next frame. Pass the
  previous frame's retained rows via the `:retained_rows` option so unchanged
  rows are reused verbatim instead of being recomposed.
  """
  @spec build_with_stats(state(), WindowScroll.t(), Context.t(), FontRegistry.t(), keyword()) ::
          {RenderWindow.t(), build_stats(), FontRegistry.t()}
  def build_with_stats(state, scroll, ctx, %FontRegistry{} = font_registry, opts \\ []) do
    %WindowScroll{
      is_active: is_active,
      viewport: viewport,
      cursor_line: cursor_line,
      cursor_byte_col: cursor_byte_col,
      cursor_col: cursor_col,
      first_line: first_line,
      snapshot: snapshot,
      window: window,
      win_layout: win_layout,
      visible_line_map: visible_line_map,
      wrap_on: wrap_on
    } = scroll

    win_id = scroll.window.id

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
        composition_fingerprint(ctx, wrap_on, snapshot.options),
        Keyword.get(opts, :retained_rows, %{}),
        Keyword.get(opts, :retained_wrap_lines, %{}),
        scroll.line_identity,
        decoration_slots
      )

    # Build visual rows from the same data the draw path uses. Unchanged rows
    # are reused from the retained-row cache (no recompose) when their cheap
    # input fingerprint matches; only composed rows count as rasterized (#2287).
    #
    # Full residence composes only the dirty logical line groups. The treap
    # retains untouched visual rows and indexes both coordinate systems.
    {all_visual_entries, resident_result, mixed_builds, font_registry} =
      build_window_entries(state, scroll, ctx, retain_ctx, opts, font_registry)

    {scroll, viewport, visible_row_start_index} = presentation_anchor(scroll, resident_result)
    payload_overscan_before = max(scroll.visible_row_start_index - viewport.visual_row_offset, 0)

    resident_context_start = resident_field(resident_result, :context_start, 0)

    local_visible_start = max(visible_row_start_index - resident_context_start, 0)

    visual_entries =
      trim_visual_entries(all_visual_entries, local_visible_start, visible_row_count)

    resident_entries =
      retained_presentation_entries(
        resident_result,
        all_visual_entries,
        local_visible_start,
        visible_row_count,
        payload_overscan_before
      )

    {new_retained, rasterized, content_digest, resident_build_state, resident_rows_spliced} =
      resolve_retained_and_digest(resident_result, resident_entries, retain_ctx)

    new_retained_wrap = retained_window_wrap_lines(scroll, all_visual_entries)

    presentation_rows = Enum.map(resident_entries, & &1.row)
    committed_rows = Enum.map(visual_entries, & &1.row)
    wrapped_coordinates? = wrapped_coordinates?(scroll)
    row_store_mode = row_store_mode(resident_build_state)

    resident_cursor =
      resident_wrapped_cursor(
        resident_build_state,
        wrapped_coordinates?,
        cursor_line,
        cursor_byte_col
      )

    {display_cursor_row, display_cursor_col} =
      case resident_cursor do
        {rank, col} ->
          {max(rank - visible_row_start_index, 0), col}

        nil ->
          compute_display_cursor(
            cursor_line,
            cursor_byte_col,
            cursor_col,
            viewport,
            window.fold_map,
            ctx.decorations,
            visual_entries,
            wrapped_coordinates?
          )
      end

    cursor_shape = active_cursor_shape(state, is_active)
    cursor_eligible = cursor_eligible?(state, is_active)

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
      case resident_cursor do
        {rank, _} ->
          rank >= visible_row_start_index and rank < visible_row_start_index + visible_row_count

        nil ->
          cursor_on_screen?(
            {cursor_line, cursor_byte_col},
            viewport,
            window.fold_map,
            visual_entries,
            visible_row_count,
            wrapped_coordinates?
          )
      end

    # Hide the editor cursor when the minibuffer has focus (command, search,
    # eval, search_prompt modes). The native SwiftUI minibuffer shows its
    # own cursor; having two cursors visible is confusing. Also hide it when the
    # cursor has scrolled off-viewport (#2684).
    {cursor_visible, retain_cursor_source?} =
      cursor_presentation_visibility(
        cursor_eligible,
        cursor_on_screen?,
        display_cursor_col,
        ctx.content_w,
        scroll,
        row_store_mode,
        content_kind
      )

    raw_selection =
      ContentHelpers.visual_selection_bounds(state, {cursor_line, scroll.cursor_byte_col})

    selection_source =
      selection_coordinates(raw_selection, ctx.visual_selection, wrapped_coordinates?)

    # Selection in display coordinates
    selection =
      build_selection(
        selection_source,
        viewport,
        visible_row_count,
        visual_entries,
        wrapped_coordinates?
      )

    {absolute_cursor_row, absolute_cursor_col} =
      resident_cursor ||
        {cursor_line,
         Decorations.buf_col_to_display_col(ctx.decorations, cursor_line, cursor_col)}

    accessibility_selection_ranges = accessibility_selection_ranges(raw_selection, visual_entries)

    accessibility_cursor =
      accessibility_cursor(
        retain_cursor_source?,
        {display_cursor_row, display_cursor_col},
        {cursor_line, scroll.cursor_byte_col},
        Enum.find(visual_entries, &(&1.display_row == display_cursor_row))
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
        elem(ctx.diagnostics_snapshot, 1),
        viewport,
        visible_row_count,
        visual_entries,
        wrapped_coordinates?,
        diagnostic_source(scroll),
        first_line,
        resident_build_state
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

    geometry = build_geometry(state, scroll, content_kind, row_store_mode)

    horizontal_pan_limit =
      horizontal_pan_limit(
        visual_entries,
        geometry,
        content_kind,
        scroll.wrap_on,
        state.intent.frame.capabilities
      )

    text_rows = text_presentation_rows(resident_build_state, resident_entries)

    text_store_identity =
      text_store_identity(row_store_mode, visible_row_start_index, resident_entries)

    text_identity =
      {
        snapshot.version,
        retain_ctx.compose_fp,
        content_digest,
        window.fold_map,
        ctx.content_w,
        ctx.wrap_on,
        Minga.Core.WidthOracle.fingerprint(ctx.width_oracle),
        scroll.content_epoch,
        rect,
        viewport.top,
        viewport.left,
        viewport.visual_row_offset,
        text_store_identity
      }

    text_identity =
      scroll_text_identity(
        state,
        scroll,
        resident_build_state,
        new_retained_wrap,
        mixed_builds,
        text_identity,
        window.authoritative_scroll_seq
      )

    {:buffer, buffer} = window.content

    text_presentation =
      TextPresentation.retain(
        RendererWindow.text_presentation(window),
        win_id,
        buffer,
        snapshot.version,
        text_identity,
        text_rows,
        if(is_integer(state.frame_seq),
          do: state.frame_seq + 1,
          else: System.unique_integer([:positive, :monotonic])
        )
      )

    {resident_semantic_state, resident_semantics} =
      build_resident_semantics(
        Keyword.get(opts, :resident_semantic_state),
        resident_build_state,
        resident_result,
        %{
          window_id: win_id,
          content_epoch: scroll.content_epoch,
          keyframe?:
            state.intent.frame.force_keyframe? or adapter_full_snapshot_pending?(state, win_id),
          cursor_eligible: cursor_eligible,
          cursor_row: absolute_cursor_row,
          cursor_col: absolute_cursor_col,
          cursorline_bg: ctx.cursorline_bg,
          selection: if(wrapped_coordinates?, do: raw_selection, else: ctx.visual_selection),
          wrapped?: wrapped_coordinates?,
          diagnostics_snapshot: ctx.diagnostics_snapshot,
          annotations_revision: ctx.decorations.annotation_version,
          decorations: ctx.decorations,
          tab_width: ctx.tab_width,
          guides_enabled?: indent_guides_enabled?()
        }
      )

    render_window = %RenderWindow{
      window_id: win_id,
      text_presentation_id: text_presentation.presentation_id,
      content_kind: content_kind,
      accessibility_label: accessibility_label(snapshot),
      accessibility_generation: window.accessibility_generation,
      accessibility_cursor: accessibility_cursor,
      accessibility_selection_ranges: accessibility_selection_ranges,
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
      gutter: build_gutter(scroll, ctx, content_kind, resident_entries, row_store_mode),
      cursorline:
        build_cursorline(content_row, display_cursor_row, is_active, cursor_on_screen?, ctx),
      indent_guides: build_indent_guides(scroll, ctx, content_kind, visual_entries),
      geometry: geometry,
      content_epoch: scroll.content_epoch,
      full_refresh: scroll.full_refresh,
      scroll_seq: scroll.scroll_seq,
      horizontal_pan_ack: window.horizontal_pan_ack,
      horizontal_pan_limit: horizontal_pan_limit,
      # Non-wrapped, non-folded windows emit consecutive :normal buffer lines, so
      # ScrollPresentation can derive the resident line range arithmetically.
      contiguous_rows: is_nil(visible_line_map) and not wrap_on,
      wrapped: scroll.wrap_on,
      # Set only on the residence path; the GUI adapter gates the content
      # frame-emit on it instead of hashing the full rows list (#2658).
      content_digest: content_digest,
      row_delta: resident_field(resident_result, :row_delta, nil),
      row_store_mode: row_store_mode,
      resident_semantics: resident_semantics
    }

    {render_window,
     %BuildResult{
       rasterized: rasterized,
       retained_rows: new_retained,
       retained_wrap_lines: new_retained_wrap,
       resident_build: resident_build_state,
       resident_semantic_state: resident_semantic_state,
       resident_rows_spliced: resident_rows_spliced,
       row_slot_allocator: row_slot_allocator,
       text_presentation: text_presentation
     }, font_registry}
  end

  defp build_window_entries(
         state,
         %{full_residence: true} = scroll,
         ctx,
         retain_ctx,
         opts,
         registry
       ) do
    materialize? =
      state.intent.frame.force_keyframe? or
        adapter_full_snapshot_pending?(state, scroll.window.id)

    {entries, result, registry} =
      build_resident_entries(
        scroll,
        scroll.lines,
        scroll.first_line,
        ctx,
        scroll.snapshot,
        retain_ctx,
        Keyword.put(opts, :keyframe?, materialize?),
        registry
      )

    {entries, result, %{}, registry}
  end

  defp build_window_entries(
         _state,
         %WindowScroll{wrap_on: true, visible_line_map: %DisplayMap{} = page} = scroll,
         ctx,
         retain_ctx,
         _opts,
         registry
       ) do
    {:buffer, buffer} = scroll.window.content

    {_, builds} =
      TextPresentation.matching_mixed_wrap(
        RendererWindow.text_presentation(scroll.window),
        buffer,
        scroll.snapshot.version,
        page.wrap_basis
      )

    source = fn line ->
      {text, offset, _, _, _} = DisplayMap.source(page, line)
      {text, offset}
    end

    builds = Map.take(builds, Map.keys(page.sources))

    {entries, builds, registry} =
      build_folded_entries(page.entries, source, page, ctx, retain_ctx, registry, builds)

    {entries, nil, builds, registry}
  end

  defp build_window_entries(_state, scroll, ctx, retain_ctx, _opts, registry) do
    {entries, registry} =
      build_visual_entries(
        scroll.lines,
        scroll.first_line,
        scroll.visible_line_map,
        scroll.wrap_on,
        ctx,
        scroll.snapshot,
        retain_ctx,
        registry
      )

    {entries, nil, %{}, registry}
  end

  defp resident_field(nil, _key, default), do: default
  defp resident_field(result, key, _default), do: Map.fetch!(result, key)

  defp retained_window_wrap_lines(
         %WindowScroll{full_residence: false, visible_line_map: nil} = scroll,
         entries
       ),
       do: retained_wrap_lines(entries, wrapped_coordinates?(scroll))

  defp retained_window_wrap_lines(%WindowScroll{}, _entries), do: %{}

  defp retained_presentation_entries(nil, entries, first, count, overscan),
    do: presentation_visual_entries(entries, first, count, overscan)

  defp retained_presentation_entries(result, _entries, _first, _count, _overscan),
    do: result.payloads

  defp wrapped_coordinates?(%WindowScroll{wrap_on: true, visible_line_map: nil}), do: true

  defp wrapped_coordinates?(%WindowScroll{wrap_on: true, visible_line_map: %DisplayMap{}}),
    do: true

  defp wrapped_coordinates?(%WindowScroll{}), do: false

  @spec build_resident_semantics(
          ResidentSemanticState.t() | nil,
          ResidentBuild.t() | nil,
          map() | nil,
          map()
        ) ::
          {ResidentSemanticState.t() | nil, Minga.RenderModel.Window.ResidentSemantics.t() | nil}
  defp build_resident_semantics(_previous, nil, _result, _input), do: {nil, nil}

  defp build_resident_semantics(previous, %ResidentBuild{} = resident, result, input) do
    ResidentSemanticState.build(
      previous,
      Map.merge(input, %{resident_build: resident, resident_result: result})
    )
  end

  @spec accessibility_label(Minga.Buffer.RenderSnapshot.t()) :: String.t()
  defp accessibility_label(%{name: name, read_only: read_only}) when is_binary(name) do
    append_read_only_label(name, read_only)
  end

  defp accessibility_label(%{file_path: path, read_only: read_only}) when is_binary(path) do
    append_read_only_label(Path.basename(path), read_only)
  end

  defp accessibility_label(_snapshot), do: "[no file]"

  @spec append_read_only_label(String.t(), boolean()) :: String.t()
  defp append_read_only_label(label, true), do: label <> " [RO]"
  defp append_read_only_label(label, false), do: label

  @spec adapter_full_snapshot_pending?(map(), non_neg_integer()) :: boolean()
  defp adapter_full_snapshot_pending?(state, window_id) do
    state.caches.adapter_gui_caches.pending_window_delta_ids
    |> MapSet.member?(window_id)
  end

  defp resident_wrapped_cursor(%ResidentBuild{store: store}, true, line, byte),
    do: ResidentStore.source_position(store, line, byte, :start)

  defp resident_wrapped_cursor(_resident, _wrapped?, _line, _byte), do: nil

  # ── Full-document residence incremental build (#2658) ──────────────────────

  @doc "Resolves the resident composition plan from the same context used by the builder."
  @spec plan_resident_build(WindowScroll.t(), Context.t()) :: ResidentBuild.plan() | :windowed
  def plan_resident_build(%WindowScroll{full_residence: false}, _ctx), do: :windowed

  def plan_resident_build(%WindowScroll{} = scroll, ctx) do
    window = scroll.window

    ResidentBuild.plan(RendererWindow.resident_build(window), %{
      compose_fp: composition_fingerprint(ctx, scroll.wrap_on, scroll.snapshot.options),
      highlight_fp: highlight_content_fingerprint(ctx.highlight),
      reset?: scroll.full_refresh,
      hydration_reason: RendererWindow.hydration_reason(window),
      edit_deltas: RendererWindow.pending_edit_deltas(window),
      line_count: scroll.snapshot.line_count
    })
  end

  # Hydration and splices compose with the same wrapped or sequential line
  # path. Presentation only reads the resulting viewport-sized context.
  @spec build_resident_entries(
          WindowScroll.t(),
          [String.t()],
          non_neg_integer(),
          Context.t(),
          map(),
          retain_ctx(),
          keyword(),
          FontRegistry.t()
        ) :: {[visual_row_entry()], map(), FontRegistry.t()}
  defp build_resident_entries(
         scroll,
         lines,
         first_line,
         ctx,
         snapshot,
         retain_ctx,
         opts,
         font_registry
       ) do
    inputs = %{
      source: resident_source(first_line, lines, snapshot.line_count),
      line_count: snapshot.line_count,
      compose_fp: retain_ctx.compose_fp,
      highlight_fp: highlight_content_fingerprint(ctx.highlight),
      reset?: scroll.full_refresh,
      hydration_reason: Keyword.get(opts, :hydration_reason),
      keyframe?: Keyword.get(opts, :keyframe?, false),
      retained_rows: retain_ctx.prev,
      edit_deltas: Keyword.get(opts, :edit_deltas, []),
      font_registry: font_registry,
      build_all: fn registry ->
        # Hydration is the one path where BufferPrefetch explicitly supplied the
        # whole bounded line range. No retained Document is sliced here.
        build_visual_entries(
          lines,
          first_line,
          nil,
          scroll.wrap_on,
          ctx,
          snapshot,
          retain_ctx,
          registry
        )
      end,
      build_dirty: fn dirty, registry ->
        build_dirty_entries(
          dirty,
          lines,
          first_line,
          scroll.wrap_on,
          ctx,
          snapshot,
          retain_ctx,
          registry
        )
      end
    }

    plan =
      Keyword.get_lazy(opts, :resident_plan, fn ->
        ResidentBuild.plan(Keyword.get(opts, :resident_build), inputs)
      end)

    inputs = Map.put(inputs, :plan, plan)

    {state, result, font_registry} =
      ResidentBuild.run(Keyword.get(opts, :resident_build), inputs)

    {visible_start, anchor} = resident_anchor(state.store, scroll.viewport)
    context_before = 8
    context_start = max(visible_start - context_before, 0)
    context_count = Viewport.content_rows(scroll.viewport) + context_before * 2
    context_payloads = ResidentStore.payload_range(state.store, context_start, context_count)

    {context_payloads,
     Map.merge(result, %{
       state: state,
       context_start: context_start,
       visible_start: visible_start,
       anchor: anchor
     }), font_registry}
  end

  defp resident_anchor(%ResidentStore{size: 0}, _viewport), do: {0, {0, 0}}

  defp resident_anchor(store, viewport) do
    line = min(viewport.top, ResidentStore.line_count(store) - 1)
    {first, count} = ResidentStore.line_extent(store, line)
    bottom = max(ResidentStore.size(store) - Viewport.content_rows(viewport), 0)
    rank = min(first + min(viewport.visual_row_offset, count - 1), bottom)
    {rank, ResidentStore.anchor_at(store, rank)}
  end

  # DisplayMap already selected the visible rows, including a partial source group at the top.
  defp presentation_anchor(%WindowScroll{visible_line_map: %DisplayMap{}} = scroll, nil),
    do: {scroll, scroll.viewport, 0}

  defp presentation_anchor(scroll, nil),
    do:
      {scroll, scroll.viewport,
       scroll.visible_row_start_index + scroll.viewport.visual_row_offset}

  defp presentation_anchor(scroll, %{visible_start: rank, anchor: {line, offset}}) do
    viewport = Viewport.put_top_visual(scroll.viewport, line, offset, offset + 1)

    {%{scroll | viewport: viewport}, viewport, rank}
  end

  defp scroll_text_identity(
         _state,
         %{wrap_on: true} = scroll,
         %ResidentBuild{},
         _groups,
         _mixed_builds,
         identity,
         authoritative_seq
       ) do
    basis =
      WrapLayout.basis(scroll.snapshot, scroll.content_w, scroll.width_oracle, scroll.cursor_line)

    {:wrapped_resident, basis, authoritative_seq, identity}
  end

  defp scroll_text_identity(
         _state,
         %{wrap_on: true, visible_line_map: %DisplayMap{wrap_basis: basis} = page},
         nil,
         _groups,
         builds,
         identity,
         _explicit_request
       )
       when is_tuple(basis) do
    TextPresentation.mixed_wrap_identity(page, builds, identity)
  end

  defp scroll_text_identity(
         state,
         %{wrap_on: true, visible_line_map: nil} = scroll,
         nil,
         groups,
         _mixed_builds,
         identity,
         _authoritative_seq
       )
       when map_size(groups) > 0 do
    if scroll.is_active and SearchHighlight.substitute_preview?(state) do
      identity
    else
      basis =
        WrapLayout.basis(
          scroll.snapshot,
          scroll.content_w,
          scroll.width_oracle,
          scroll.cursor_line
        )

      counts =
        Map.new(groups, fn {_row_id, {_hash, [%VisualRow{buf_line: line} | _] = rows}} ->
          {line, length(rows)}
        end)

      {:wrapped_windowed, basis, counts, identity}
    end
  end

  defp scroll_text_identity(
         _state,
         _scroll,
         _resident,
         _groups,
         _builds,
         identity,
         _explicit_request
       ),
       do: identity

  @spec row_store_mode(ResidentBuild.t() | nil) :: :windowed | {:resident, non_neg_integer()}
  defp row_store_mode(%ResidentBuild{store: store}), do: {:resident, ResidentStore.size(store)}
  defp row_store_mode(nil), do: :windowed

  @spec resident_source(non_neg_integer(), [String.t()], non_neg_integer()) ::
          ResidentBuild.source()
  defp resident_source(0, lines, count) do
    case length(lines) do
      ^count -> {:complete, lines}
      _ -> {:range, 0, lines}
    end
  end

  defp resident_source(first, lines, _count), do: {:range, first, lines}

  # Composes complete visual groups only for dirty logical lines.
  @spec build_dirty_entries(
          MapSet.t(non_neg_integer()),
          [String.t()],
          non_neg_integer(),
          boolean(),
          Context.t(),
          map(),
          retain_ctx(),
          FontRegistry.t()
        ) :: {%{non_neg_integer() => [visual_row_entry()]}, FontRegistry.t()}
  defp build_dirty_entries(
         dirty,
         lines,
         first_line,
         wrapped?,
         ctx,
         snapshot,
         retain_ctx,
         font_registry
       ) do
    first_byte_off = snapshot.first_line_byte_offset
    local_dirty = MapSet.new(dirty, &(&1 - first_line))
    offsets = dirty_line_offsets(lines, first_byte_off, local_dirty)
    masked = masked_highlight_by_index(ctx.highlight, lines, first_byte_off, local_dirty)
    wrap_opts = if wrapped?, do: wrap_options(ctx, snapshot.options), else: nil

    Enum.reduce(dirty, {%{}, font_registry}, fn absolute_index, {acc, registry} ->
      local_index = absolute_index - first_line
      {line_text, line_byte_offset} = Map.fetch!(offsets, local_index)

      {entry, registry} =
        compose_dirty_group(
          absolute_index,
          line_text,
          Map.get(masked, local_index),
          line_byte_offset,
          wrap_opts,
          ctx,
          retain_ctx,
          registry
        )

      {Map.put(acc, absolute_index, entry), registry}
    end)
  end

  defp compose_dirty_group(line, text, segments, offset, nil, ctx, retain_ctx, registry) do
    {entry, registry} =
      compose_sequential_entry(line, text, segments, offset, ctx, retain_ctx, registry)

    {[entry], registry}
  end

  defp compose_dirty_group(line, text, segments, offset, opts, ctx, retain_ctx, registry) do
    build_wrapped_logical_line(
      %{
        line_text: text,
        line_byte_offset: offset,
        hl_segments: segments,
        buf_line: line,
        content_width: Keyword.fetch!(opts, :content_width),
        wrap_opts: opts,
        ctx: ctx,
        retain_ctx: retain_ctx
      },
      registry
    )
  end

  @spec dirty_line_offsets([String.t()], non_neg_integer(), MapSet.t(non_neg_integer())) ::
          %{non_neg_integer() => {String.t(), non_neg_integer()}}
  defp dirty_line_offsets(lines, first_byte_off, dirty),
    do: dirty_line_offsets(lines, 0, first_byte_off, dirty, %{})

  defp dirty_line_offsets([], _index, _offset, _dirty, offsets), do: offsets

  defp dirty_line_offsets([line | rest], index, offset, dirty, offsets) do
    offsets =
      if MapSet.member?(dirty, index), do: Map.put(offsets, index, {line, offset}), else: offsets

    dirty_line_offsets(rest, index + 1, offset + byte_size(line) + 1, dirty, offsets)
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
  defp highlight_content_fingerprint(%Highlight{} = hl), do: Highlight.fingerprint(hl)

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
          non_neg_integer(),
          %{optional(non_neg_integer()) => {non_neg_integer(), Row.t()}},
          %{optional(non_neg_integer()) => {non_neg_integer(), [visual_row_entry()]}},
          LineIdentity.t() | nil,
          map()
        ) :: retain_ctx()
  defp retain_ctx(compose_fp, prev, prev_wrap, line_identity, decoration_slots)
       when is_map(prev) and is_map(prev_wrap) and is_map(decoration_slots) do
    %{
      prev: prev,
      prev_wrap: prev_wrap,
      compose_fp: compose_fp,
      line_identity: line_identity,
      decoration_slots: decoration_slots
    }
  end

  @spec composition_fingerprint(Context.t(), boolean(), map()) :: non_neg_integer()
  defp composition_fingerprint(ctx, wrapped?, options) do
    conceal_cursor =
      if Decorations.has_conceal_ranges?(ctx.decorations), do: ctx.cursor_line, else: nil

    wrap_geometry =
      if wrapped? do
        opts = wrap_options(ctx, options)
        {Keyword.delete(opts, :oracle), Minga.Core.WidthOracle.fingerprint(ctx.width_oracle)}
      end

    :erlang.phash2({
      ctx.composition_key || Decorations.text_composition_key(ctx.decorations),
      ctx.show_invisible,
      ctx.tab_width,
      ctx.whitespace_face,
      ctx.hl_todo_faces,
      ctx.highlight != nil,
      wrap_geometry,
      conceal_cursor
    })
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
  @spec compose_or_reuse(
          retain_ctx(),
          non_neg_integer(),
          term(),
          FontRegistry.t(),
          (FontRegistry.t() -> {Row.t(), FontRegistry.t()})
        ) :: {Row.t(), non_neg_integer(), boolean(), FontRegistry.t()}
  defp compose_or_reuse(
         %{prev: prev} = retain_ctx,
         row_id,
         key,
         font_registry,
         compose_fun
       ) do
    input_hash = row_input_hash(retain_ctx, key)

    case Map.get(prev, row_id) do
      {^input_hash, %Row{} = cached} ->
        {cached, input_hash, true, font_registry}

      _ ->
        {row, font_registry} = compose_fun.(font_registry)
        {row, input_hash, false, font_registry}
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
      {row_id, retained} = VisualRow.retained_row(entry)
      rasterized = if VisualRow.reused?(entry), do: rasterized, else: rasterized + 1
      {Map.put(map, row_id, retained), rasterized}
    end)
  end

  # Cache complete logical lines before viewport trimming, including continuation rows outside the current presentation.
  # Reused entries reset display_row so the next viewport positions them independently.
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
  defp wrap_line_cache_entry([%VisualRow{visual_index: 0} = first | _] = entries) do
    case first.wrap_line_hash do
      nil ->
        nil

      hash ->
        normalized = Enum.map(entries, &VisualRow.with_display_row(&1, 0))
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
      no_retain(LineIdentity.new(first_line + length(lines))),
      FontRegistry.new()
    )
    |> elem(0)
    |> Enum.at(visual_row)
    |> source_position_from_visual_entry(display_col)
  end

  @doc "Maps a hit in a measured mixed-layout segment back to its source position."
  @spec mixed_source_position(
          DisplayMap.source(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Context.t()
        ) :: {:ok, non_neg_integer(), non_neg_integer()} | :error
  def mixed_source_position(
        {text, _offset, composed, _rows, _count} = source,
        line,
        index,
        display_col,
        ctx
      ) do
    rows = DisplayMap.segments(source, index, 1)
    [entry] = project_wrapped_entries(rows, index, composed, text, [], {line, line}, ctx)
    source_position_from_visual_entry(entry, display_col)
  end

  @spec source_position_from_visual_entry(visual_row_entry() | nil, non_neg_integer()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | :error
  defp source_position_from_visual_entry(nil, _display_col), do: :error

  defp source_position_from_visual_entry(entry, display_col) do
    row_local_utf16 = utf16_at_display_col(entry.row.text, display_col)

    case VisualRow.source_position(entry, row_local_utf16) do
      {:ok, {line, source_byte}} -> {:ok, line, source_byte}
      :not_source_backed -> :error
    end
  end

  # ── Visual row building ────────────────────────────────────────────────

  @spec build_visual_entries(
          [String.t()],
          non_neg_integer(),
          [DisplayMap.entry()] | nil,
          boolean(),
          Context.t(),
          map(),
          retain_ctx(),
          FontRegistry.t()
        ) :: {[visual_row_entry()], FontRegistry.t()}
  defp build_visual_entries(
         lines,
         first_line,
         visible_line_map,
         wrap_on,
         ctx,
         snapshot,
         retain_ctx,
         font_registry
       ) do
    build_visual_entries_for_mode(
      lines,
      first_line,
      visible_line_map,
      wrap_on,
      ctx,
      snapshot,
      retain_ctx,
      font_registry
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
          retain_ctx(),
          FontRegistry.t()
        ) :: {[visual_row_entry()], FontRegistry.t()}
  defp build_visual_entries_for_mode(
         lines,
         first_line,
         visible_line_map,
         _wrap_on,
         ctx,
         snapshot,
         retain_ctx,
         font_registry
       )
       when is_list(visible_line_map) do
    build_visual_entries_folded(
      lines,
      first_line,
      visible_line_map,
      ctx,
      snapshot,
      retain_ctx,
      font_registry
    )
  end

  defp build_visual_entries_for_mode(
         lines,
         first_line,
         nil,
         true,
         ctx,
         snapshot,
         retain_ctx,
         font_registry
       ) do
    build_visual_entries_wrapped(lines, first_line, ctx, snapshot, retain_ctx, font_registry)
  end

  defp build_visual_entries_for_mode(
         lines,
         first_line,
         nil,
         false,
         ctx,
         snapshot,
         retain_ctx,
         font_registry
       ) do
    build_visual_entries_sequential(lines, first_line, ctx, snapshot, retain_ctx, font_registry)
  end

  # Sequential path (no folds): one visual row per line.
  @spec build_visual_entries_sequential(
          [String.t()],
          non_neg_integer(),
          Context.t(),
          map(),
          retain_ctx(),
          FontRegistry.t()
        ) :: {[visual_row_entry()], FontRegistry.t()}
  defp build_visual_entries_sequential(
         lines,
         first_line,
         ctx,
         snapshot,
         retain_ctx,
         font_registry
       ) do
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
    |> Enum.map_reduce(font_registry, fn
      {{{line_text, line_byte_offset}, hl_segments}, idx}, registry ->
        compose_sequential_entry(
          first_line + idx,
          line_text,
          hl_segments,
          line_byte_offset,
          ctx,
          retain_ctx,
          registry
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
          retain_ctx(),
          FontRegistry.t()
        ) :: {visual_row_entry(), FontRegistry.t()}
  defp compose_sequential_entry(
         buf_line,
         line_text,
         hl_segments,
         line_byte_offset,
         ctx,
         retain_ctx,
         font_registry
       ) do
    row_id = Row.stable_id(:normal, durable_source_id(retain_ctx, buf_line))

    {row, input_hash, reused?, font_registry} =
      compose_or_reuse(
        retain_ctx,
        row_id,
        {:seq, line_text, hl_segments},
        font_registry,
        fn registry ->
          {composed_text, spans, registry} =
            compose_line(line_text, hl_segments, ctx, buf_line, line_byte_offset, registry)

          {%Row{
             row_id: row_id,
             row_type: :normal,
             buf_line: buf_line,
             text: composed_text,
             spans: spans,
             content_hash: Row.compute_hash(composed_text, spans)
           }, registry}
        end
      )

    entry =
      row
      |> Row.reposition(buf_line)
      |> visual_entry(line_text, ctx, 0, Unicode.display_width(row.text), 0)
      |> VisualRow.with_retention(input_hash, reused?)

    {entry, font_registry}
  end

  @spec build_visual_entries_wrapped(
          [String.t()],
          non_neg_integer(),
          Context.t(),
          map(),
          retain_ctx(),
          FontRegistry.t()
        ) :: {[visual_row_entry()], FontRegistry.t()}
  defp build_visual_entries_wrapped(
         lines,
         first_line,
         ctx,
         snapshot,
         retain_ctx,
         font_registry
       ) do
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
    |> Enum.flat_map_reduce(font_registry, fn
      {{{line_text, line_byte_offset}, hl_segments}, idx}, registry ->
        build_wrapped_logical_line(
          %{
            line_text: line_text,
            line_byte_offset: line_byte_offset,
            hl_segments: hl_segments,
            buf_line: first_line + idx,
            content_width: content_width,
            wrap_opts: wrap_opts,
            ctx: ctx,
            retain_ctx: retain_ctx
          },
          registry
        )
    end)
  end

  # Builds (or replays) the full visual-row set for one wrapped logical line.
  #
  # True logical-line reuse: when the line's full input fingerprint (text,
  # highlight segments, shared compose context, AND content width, since wrap
  # points depend on width) matches the cached logical line, the entire
  # visual-row set is replayed verbatim, skipping both compose_line and the wrap
  # computation. Otherwise the line is composed and re-wrapped from scratch (#2287).
  @spec build_wrapped_logical_line(map(), FontRegistry.t()) ::
          {[visual_row_entry()], FontRegistry.t()}
  defp build_wrapped_logical_line(params, font_registry) do
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
      {:reuse, entries} -> {entries, font_registry}
      :miss -> compose_wrapped_logical_line(params, wrap_line_hash, font_registry)
    end
  end

  @spec compose_wrapped_logical_line(map(), non_neg_integer(), FontRegistry.t()) ::
          {[visual_row_entry()], FontRegistry.t()}
  defp compose_wrapped_logical_line(params, wrap_line_hash, font_registry) do
    %{
      line_text: line_text,
      line_byte_offset: line_byte_offset,
      hl_segments: hl_segments,
      buf_line: buf_line,
      wrap_opts: wrap_opts,
      ctx: ctx
    } = params

    {composed_text, spans, font_registry} =
      compose_line(line_text, hl_segments, ctx, buf_line, line_byte_offset, font_registry)

    entries =
      wrap_composed_entries(
        composed_text,
        line_text,
        spans,
        buf_line,
        durable_source_id(params.retain_ctx, buf_line),
        ctx,
        wrap_opts
      )
      |> Enum.map(&stamp_wrapped_entry(&1, wrap_line_hash))

    {entries, font_registry}
  end

  @spec stamp_wrapped_entry(visual_row_entry(), non_neg_integer()) :: visual_row_entry()
  defp stamp_wrapped_entry(entry, wrap_line_hash) do
    entry
    |> VisualRow.with_retention(wrap_line_hash, false)
    |> VisualRow.with_wrap_line_hash(wrap_line_hash)
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

  @spec mark_wrapped_reused(visual_row_entry(), non_neg_integer(), non_neg_integer()) ::
          visual_row_entry()
  defp mark_wrapped_reused(entry, buf_line, wrap_line_hash) do
    entry
    |> VisualRow.reposition(buf_line)
    |> VisualRow.with_retention(wrap_line_hash, true)
    |> VisualRow.with_wrap_line_hash(wrap_line_hash)
  end

  @spec wrap_composed_entries(
          String.t(),
          String.t(),
          [Span.t()],
          non_neg_integer(),
          non_neg_integer(),
          Context.t(),
          keyword()
        ) :: [visual_row_entry()]
  defp wrap_composed_entries(composed_text, source_text, spans, buf_line, source_id, ctx, opts) do
    [visual_rows] = WrapMap.compute([composed_text], Keyword.fetch!(opts, :content_width), opts)

    project_wrapped_entries(
      visual_rows,
      0,
      composed_text,
      source_text,
      spans,
      {buf_line, source_id},
      ctx
    )
  end

  defp project_wrapped_entries(
         visual_rows,
         first_index,
         composed_text,
         source_text,
         spans,
         {buf_line, source_id},
         ctx
       ) do
    decorations = composition_decorations(ctx, buf_line)

    {rows, offsets, width} =
      measure_wrapped_rows(visual_rows, composed_text, source_text, decorations, buf_line, ctx)

    project_measured_rows(
      rows,
      first_index,
      spans,
      {buf_line, source_id},
      {offsets, width, decorations}
    )
  end

  defp measure_wrapped_rows(
         [%{byte_offset: first_byte} | _] = visual_rows,
         composed_text,
         source_text,
         decorations,
         buf_line,
         ctx
       ) do
    source_offset_map =
      SourceOffsetMap.new(source_text, composed_text, decorations, buf_line,
        tab_width: ctx.tab_width
      )

    source_line_width = Unicode.display_width(source_text)

    prefix = binary_part(composed_text, 0, first_byte)
    start_utf16 = utf16_offset(prefix, first_byte)
    start_col = Unicode.display_width(prefix)

    {visual_rows_with_offsets, _} =
      Enum.map_reduce(visual_rows, {start_utf16, start_col}, fn %{source_text: text} = row,
                                                                {utf16, col} ->
        next_utf16 = utf16 + utf16_offset(text, byte_size(text))
        next_col = col + Unicode.display_width(text)
        {{row, utf16, next_utf16, col, next_col}, {next_utf16, next_col}}
      end)

    composed_boundaries =
      visual_rows_with_offsets
      |> Enum.flat_map(fn {_row, composed_start_utf16, composed_end_utf16, _start, _end} ->
        [{composed_start_utf16, :start}, {composed_end_utf16, :end}]
      end)

    source_bytes =
      SourceOffsetMap.composed_utf16_to_source_bytes(source_offset_map, composed_boundaries)

    rows = with_source_bytes(visual_rows_with_offsets, source_bytes, [])
    {rows, source_offset_map, source_line_width}
  end

  defp with_source_bytes([], [], acc), do: Enum.reverse(acc)

  defp with_source_bytes(
         [{row, utf16_start, utf16_end, col_start, col_end} | rows],
         [byte_start, byte_end | bytes],
         acc
       ) do
    measured = {row, utf16_start, utf16_end, col_start, col_end, byte_start, byte_end}
    with_source_bytes(rows, bytes, [measured | acc])
  end

  defp project_measured_rows(
         rows,
         first_index,
         spans,
         {buf_line, source_id},
         {source_offset_map, source_line_width, decorations}
       ) do
    rows
    |> Enum.with_index(first_index)
    |> Enum.map_reduce(spans, fn
      {{visual_row, composed_start_utf16, composed_end_utf16, source_start, source_end,
        source_start_byte, source_end_byte}, visual_index},
      pending_spans ->
        text = WrapMap.display_text(visual_row)
        row_type = if visual_index == 0, do: :normal, else: :wrap_continuation
        indent_width = visual_row.indent_width

        {row_spans, pending_spans} =
          spans_for_visual_row(pending_spans, source_start, source_end, indent_width, [])

        source_start_col =
          Decorations.display_col_to_buf_col(
            decorations,
            buf_line,
            source_start,
            source_line_width
          )

        source_end_col =
          Decorations.display_col_to_buf_col(
            decorations,
            buf_line,
            source_end,
            source_line_width
          )

        source_offset_map =
          SourceOffsetMap.slice(
            source_offset_map,
            source_start_byte,
            source_end_byte,
            composed_start_utf16,
            composed_end_utf16
          )

        row = %Row{
          row_id: Row.stable_id(row_type, source_id, visual_index),
          row_type: row_type,
          buf_line: buf_line,
          visual_index: visual_index,
          text: text,
          spans: row_spans,
          content_hash: Row.compute_hash(text, row_spans)
        }

        entry =
          VisualRow.new(
            row,
            source_offset_map,
            source_start_col,
            source_end_col,
            indent_width
          )

        {entry, pending_spans}
    end)
    |> elem(0)
  end

  @spec wrap_options(Context.t(), map()) :: keyword()
  defp wrap_options(%Context{} = ctx, options),
    do: WrapLayout.options(ctx.content_w, ctx.width_oracle, options)

  @spec trim_visual_entries([visual_row_entry()], non_neg_integer(), non_neg_integer()) :: [
          visual_row_entry()
        ]
  defp trim_visual_entries(entries, offset, row_count) do
    entries
    |> drop_visual_entry_offset(offset)
    |> Enum.take(row_count)
    |> Enum.with_index()
    |> Enum.map(fn {entry, display_row} -> VisualRow.with_display_row(entry, display_row) end)
  end

  @spec drop_visual_entry_offset([visual_row_entry()], non_neg_integer()) :: [visual_row_entry()]
  defp drop_visual_entry_offset(entries, 0), do: entries

  defp drop_visual_entry_offset(entries, offset) do
    case Enum.drop(entries, offset) do
      [] -> entries |> Enum.at(-1) |> List.wrap()
      visible -> visible
    end
  end

  @spec visual_entry(
          Row.t(),
          String.t(),
          Context.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          visual_row_entry()
  defp visual_entry(
         %Row{} = row,
         source_text,
         %Context{} = ctx,
         source_start_col,
         source_end_col,
         indent_width
       ) do
    decorations = composition_decorations(ctx, row.buf_line)

    VisualRow.new(
      row,
      SourceOffsetMap.new(source_text, row.text, decorations, row.buf_line,
        tab_width: ctx.tab_width
      ),
      source_start_col,
      source_end_col,
      indent_width
    )
  end

  @spec source_text_for_entry(Row.t(), (non_neg_integer() -> {String.t(), non_neg_integer()})) ::
          String.t()
  defp source_text_for_entry(%Row{row_type: row_type, buf_line: buf_line}, source)
       when row_type in [:normal, :fold_start],
       do: elem(source.(buf_line), 0)

  defp source_text_for_entry(%Row{text: text}, _source), do: text

  @spec composition_decorations(Context.t(), non_neg_integer()) :: Decorations.t()
  defp composition_decorations(%Context{} = ctx, buf_line) do
    ctx
    |> maybe_reveal_conceals(buf_line)
    |> Map.fetch!(:decorations)
  end

  # Composition emits ordered, disjoint spans. A long span can cross several
  # rows; details behind the current row can never be needed again.
  defp spans_for_visual_row([%Span{end_col: last} | rest], first, last_col, indent, acc)
       when last <= first,
       do: spans_for_visual_row(rest, first, last_col, indent, acc)

  defp spans_for_visual_row(
         [%Span{start_col: start} = span | rest] = spans,
         first,
         last,
         indent,
         acc
       )
       when start < last do
    updated = Enum.reverse(Span.rebase_to_visual_row(span, first, last, indent), acc)

    if span.end_col > last,
      do: {Enum.reverse(updated), spans},
      else: spans_for_visual_row(rest, first, last, indent, updated)
  end

  defp spans_for_visual_row(spans, _first, _last, _indent, acc), do: {Enum.reverse(acc), spans}

  # Fold-aware path: walks visible_line_map entries.
  @spec build_visual_entries_folded(
          [String.t()],
          non_neg_integer(),
          [DisplayMap.entry()],
          Context.t(),
          map(),
          retain_ctx(),
          FontRegistry.t()
        ) :: {[visual_row_entry()], FontRegistry.t()}
  defp build_visual_entries_folded(
         lines,
         first_line,
         visible_line_map,
         ctx,
         snapshot,
         retain_ctx,
         font_registry
       ) do
    pairs = lines |> build_lines_with_offsets(snapshot.first_line_byte_offset) |> List.to_tuple()

    source = fn buf_line ->
      index = buf_line - first_line
      if index >= 0 and index < tuple_size(pairs), do: elem(pairs, index), else: {"", 0}
    end

    {entries, _, registry} =
      build_folded_entries(visible_line_map, source, nil, ctx, retain_ctx, font_registry, %{})

    {entries, registry}
  end

  defp build_folded_entries(entries, source, page, ctx, retain_ctx, registry, builds) do
    source_ctx = %{
      source: source,
      highlight_segments_by_line:
        build_highlight_segments_by_line(entries, source, ctx.highlight),
      line_identity: retain_ctx.line_identity,
      decoration_slots: retain_ctx.decoration_slots
    }

    style_key = mixed_style_key(page, ctx)

    build_folded_rows(
      entries,
      page,
      ctx,
      source_ctx,
      retain_ctx,
      {style_key, builds, %{}, registry, []}
    )
  end

  defp mixed_style_key(%DisplayMap{wrap_basis: basis}, ctx) when is_tuple(basis) do
    {ctx.whitespace_face, ctx.hl_todo_faces,
     if(ctx.highlight, do: Highlight.fingerprint(ctx.highlight))}
  end

  defp mixed_style_key(_page, _ctx), do: nil

  defp build_folded_rows(
         [],
         _page,
         _ctx,
         _source,
         _retain,
         {_key, builds, _counters, registry, acc}
       ),
       do: {Enum.reverse(acc), builds, registry}

  defp build_folded_rows(
         [{line, {:wrapped, first}} | rest],
         %DisplayMap{} = page,
         ctx,
         source_ctx,
         retain,
         {style_key, builds, counters, registry, acc}
       ) do
    {rest, count} = take_wrap_run(rest, line, 1)
    address = {line, durable_source_id(retain, line)}

    {entries, builds, registry} =
      project_mixed_run(page, {first, count}, address, ctx, {style_key, builds, registry})

    acc =
      Enum.reduce(entries, acc, fn entry, rows ->
        hash = row_input_hash(retain, {:mixed_wrap, entry.row.row_id, entry.row.content_hash})
        [VisualRow.with_retention(entry, hash, false) | rows]
      end)

    build_folded_rows(
      rest,
      page,
      ctx,
      source_ctx,
      retain,
      {style_key, builds, counters, registry, acc}
    )
  end

  defp build_folded_rows(
         [{line, kind} | rest],
         page,
         ctx,
         source_ctx,
         retain,
         {style_key, builds, counters, registry, acc}
       ) do
    {index, counters} = next_visual_identity(line, kind, counters)

    {row, input_hash, reused?, registry} =
      build_visual_row_entry_retained(line, kind, ctx, source_ctx, index, retain, registry)

    entry =
      row
      |> visual_entry(
        source_text_for_entry(row, source_ctx.source),
        ctx,
        0,
        Unicode.display_width(row.text),
        0
      )
      |> VisualRow.with_retention(input_hash, reused?)

    build_folded_rows(
      rest,
      page,
      ctx,
      source_ctx,
      retain,
      {style_key, builds, counters, registry, [entry | acc]}
    )
  end

  defp project_mixed_run(
         %DisplayMap{wrap_basis: nil} = page,
         {first, count},
         {line, _} = address,
         ctx,
         {_style_key, builds, registry}
       ) do
    {text, _, composed, _, _} = source = DisplayMap.source(page, line)
    {spans, registry} = compose_mixed_spans(source, line, ctx, registry)
    rows = DisplayMap.segments(source, first, count)
    entries = project_wrapped_entries(rows, first, composed, text, spans, address, ctx)
    {entries, builds, registry}
  end

  defp project_mixed_run(page, {first, count}, {line, _} = address, ctx, {key, builds, registry}) do
    source = DisplayMap.source(page, line)
    decorations = composition_decorations(ctx, line)

    # Transient blocks receive fresh IDs on every frame. Only source-line
    # highlights affect these spans, and their decorative IDs are not styling.
    highlights =
      decorations
      |> Decorations.highlights_for_line(line)
      |> Enum.map(fn range -> {range.start, range.end_, range.style, range.priority} end)

    key = {key, highlights}

    {build, registry} =
      mixed_line_build(Map.get(builds, line), source, line, key, decorations, ctx, registry)

    {metrics, offsets, width, _, spans} = build
    last = first + count - 1
    spans = mixed_run_spans(spans, elem(elem(metrics, first), 3), elem(elem(metrics, last), 4))
    rows = for index <- first..last, do: elem(metrics, index)

    entries =
      project_measured_rows(rows, first, spans, address, {offsets, width, decorations})

    {entries, Map.put(builds, line, build), registry}
  end

  # Keep source geometry and styles indexed per measured line. Only the
  # visible portion is turned into Rows or placed in the interaction index.
  defp mixed_line_build(
         {_, _, _, {style_key, families}, _} = build,
         _source,
         _line,
         style_key,
         _decorations,
         _ctx,
         %FontRegistry{families: families} = registry
       ),
       do: {build, registry}

  defp mixed_line_build(previous, source, line, style_key, decorations, ctx, registry) do
    {text, _, composed, _, count} = source

    {metrics, offsets, width} =
      case previous do
        {metrics, offsets, width, _, _} ->
          {metrics, offsets, width}

        nil ->
          {rows, offsets, width} =
            source
            |> DisplayMap.segments(0, count)
            |> measure_wrapped_rows(composed, text, decorations, line, ctx)

          {List.to_tuple(rows), offsets, width}
      end

    {spans, registry} = compose_mixed_spans(source, line, ctx, registry)
    {{metrics, offsets, width, {style_key, registry.families}, List.to_tuple(spans)}, registry}
  end

  defp compose_mixed_spans({text, offset, _, _, _}, line, ctx, registry) do
    hl =
      if ctx.highlight do
        [segments] = Highlight.styles_for_visible_lines(ctx.highlight, [{text, offset}])
        segments
      end

    {_styled_text, spans, registry} = compose_line(text, hl, ctx, line, offset, registry)
    {spans, registry}
  end

  defp mixed_run_spans(spans, first, last) do
    size = tuple_size(spans)
    first_index = first_intersecting_span(spans, first, 0, size)
    take_intersecting_spans(spans, first_index, size, last, [])
  end

  defp first_intersecting_span(_spans, _column, index, index), do: index

  defp first_intersecting_span(spans, column, low, high) do
    mid = div(low + high, 2)
    span = elem(spans, mid)

    if span.end_col <= column do
      first_intersecting_span(spans, column, mid + 1, high)
    else
      first_intersecting_span(spans, column, low, mid)
    end
  end

  defp take_intersecting_spans(_spans, size, size, _last, acc), do: Enum.reverse(acc)

  defp take_intersecting_spans(spans, index, size, last, acc) do
    case elem(spans, index) do
      %Span{start_col: first} = span when first < last ->
        take_intersecting_spans(spans, index + 1, size, last, [span | acc])

      _ ->
        Enum.reverse(acc)
    end
  end

  defp take_wrap_run([{line, {:wrapped, _}} | rest], line, count),
    do: take_wrap_run(rest, line, count + 1)

  defp take_wrap_run(rest, _line, count), do: {rest, count}

  @spec build_highlight_segments_by_line(
          [DisplayMap.entry()],
          (non_neg_integer() -> {String.t(), non_neg_integer()}),
          Highlight.t() | nil
        ) :: %{non_neg_integer() => [Highlight.styled_segment()]}
  defp build_highlight_segments_by_line(_entries, _source, nil), do: %{}

  defp build_highlight_segments_by_line(entries, source, %Highlight{} = hl) do
    source_lines =
      entries
      |> Enum.map(&source_highlight_line/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(fn line -> {line, source.(line)} end)

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
          Context.t(),
          folded_source_ctx(),
          non_neg_integer(),
          retain_ctx(),
          FontRegistry.t()
        ) :: {Row.t(), non_neg_integer(), boolean(), FontRegistry.t()}
  defp build_visual_row_entry_retained(
         buf_line,
         :normal,
         ctx,
         source_ctx,
         index,
         retain_ctx,
         font_registry
       ) do
    {line_text, _offset} = source_ctx.source.(buf_line)
    hl_segments = Map.get(source_ctx.highlight_segments_by_line, buf_line)
    row_id = Row.stable_id(:normal, durable_source_id(retain_ctx, buf_line))

    {row, input_hash, reused?, font_registry} =
      compose_or_reuse(
        retain_ctx,
        row_id,
        {:fold_normal, line_text, hl_segments},
        font_registry,
        fn registry ->
          build_visual_row_entry(
            buf_line,
            :normal,
            ctx,
            source_ctx,
            index,
            registry
          )
        end
      )

    {Row.reposition(row, buf_line), input_hash, reused?, font_registry}
  end

  defp build_visual_row_entry_retained(
         buf_line,
         entry_type,
         ctx,
         source_ctx,
         index,
         retain_ctx,
         font_registry
       ) do
    {row, font_registry} =
      build_visual_row_entry(
        buf_line,
        entry_type,
        ctx,
        source_ctx,
        index,
        font_registry
      )

    {row, row_input_hash(retain_ctx, {:fold_other, row.row_id, row.content_hash}), false,
     font_registry}
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
          Context.t(),
          folded_source_ctx(),
          non_neg_integer(),
          FontRegistry.t()
        ) :: {Row.t(), FontRegistry.t()}
  defp build_visual_row_entry(
         buf_line,
         :normal,
         ctx,
         source_ctx,
         _index,
         font_registry
       ) do
    {line_text, line_byte_offset} = source_ctx.source.(buf_line)
    hl_segments = Map.get(source_ctx.highlight_segments_by_line, buf_line)

    {composed, spans, font_registry} =
      compose_line(line_text, hl_segments, ctx, buf_line, line_byte_offset, font_registry)

    {%Row{
       row_id: Row.stable_id(:normal, durable_source_id(source_ctx, buf_line)),
       row_type: :normal,
       buf_line: buf_line,
       text: composed,
       spans: spans,
       content_hash: Row.compute_hash(composed, spans)
     }, font_registry}
  end

  defp build_visual_row_entry(
         buf_line,
         {:fold_start, hidden_count},
         ctx,
         source_ctx,
         _index,
         font_registry
       ) do
    {line_text, line_byte_offset} = source_ctx.source.(buf_line)
    hl_segments = Map.get(source_ctx.highlight_segments_by_line, buf_line)

    {composed, spans, font_registry} =
      compose_line(line_text, hl_segments, ctx, buf_line, line_byte_offset, font_registry)

    {composed, spans} = append_fold_summary(composed, spans, hidden_count, ctx)

    {%Row{
       row_id: Row.stable_id(:fold_start, durable_source_id(source_ctx, buf_line)),
       row_type: :fold_start,
       buf_line: buf_line,
       text: composed,
       spans: spans,
       content_hash: Row.compute_hash(composed, spans)
     }, font_registry}
  end

  defp build_visual_row_entry(
         buf_line,
         {:virtual_line, vt},
         _ctx,
         source_ctx,
         visual_identity_index,
         font_registry
       ) do
    text = virtual_text_to_string(vt)

    {spans, font_registry} = virtual_text_spans(vt, font_registry)

    {%Row{
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
     }, font_registry}
  end

  defp build_visual_row_entry(
         buf_line,
         {:block, block, line_idx},
         ctx,
         source_ctx,
         visual_identity_index,
         font_registry
       ) do
    # Block decorations render via callback; capture the rendered text using the same text width as the draw path.
    rendered_lines = block.render.(ctx.content_w)
    normalized = BlockDecoration.normalize_render_result(rendered_lines)
    segments = Enum.at(normalized, line_idx, [])
    text = Enum.map_join(segments, fn {t, _style} -> t end)
    {spans, font_registry} = segments_to_spans(segments, font_registry)

    {%Row{
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
     }, font_registry}
  end

  defp build_visual_row_entry(
         buf_line,
         {:decoration_fold, fold},
         _ctx,
         source_ctx,
         _index,
         font_registry
       ) do
    hidden = FoldRegion.hidden_count(fold)
    text = " ··· #{hidden} lines"

    {%Row{
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
     }, font_registry}
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
          non_neg_integer(),
          FontRegistry.t()
        ) :: {String.t(), [Span.t()], FontRegistry.t()}
  defp compose_line(
         line_text,
         hl_segments,
         ctx,
         buf_line,
         line_byte_offset,
         font_registry
       ) do
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
      Composition.present_whitespace(
        segments,
        ctx.tab_width,
        ctx.show_invisible,
        ctx.whitespace_face
      )

    # Convert to composed text + spans
    Composition.segments_to_text_and_spans(segments, font_registry)
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

  @spec text_presentation_rows(ResidentBuild.t() | nil, [visual_row_entry()]) ::
          TextPresentation.rows()
  defp text_presentation_rows(%ResidentBuild{store: store}, _entries), do: {:resident, store}
  defp text_presentation_rows(nil, entries), do: {:windowed, List.to_tuple(entries)}

  @spec text_store_identity(:windowed | {:resident, non_neg_integer()}, non_neg_integer(), [
          visual_row_entry()
        ]) :: tuple()
  defp text_store_identity({:resident, count}, _start, _entries), do: {:resident, count}
  defp text_store_identity(:windowed, start, entries), do: {:windowed, start, length(entries)}

  @spec selection_coordinates(
          ContentHelpers.visual_selection(),
          ContentHelpers.visual_selection(),
          boolean()
        ) :: ContentHelpers.visual_selection()
  defp selection_coordinates(nil, display_selection, true), do: display_selection
  defp selection_coordinates(source_selection, _display_selection, true), do: source_selection
  defp selection_coordinates(_source_selection, display_selection, false), do: display_selection

  @spec compute_display_cursor(
          non_neg_integer(),
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
         cursor_byte_col,
         _cursor_col,
         _viewport,
         _fold_map,
         _decorations,
         visual_entries,
         true
       ) do
    compute_wrapped_display_cursor(cursor_line, cursor_byte_col, visual_entries)
  end

  defp compute_display_cursor(
         cursor_line,
         _cursor_byte_col,
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

  # A visible continuation of the cursor's source line is not enough: the
  # continuation that contains the cursor itself must be on-screen.
  @spec cursor_on_screen?(
          {non_neg_integer(), non_neg_integer()},
          Viewport.t(),
          FoldMap.t(),
          [visual_row_entry()],
          non_neg_integer(),
          boolean()
        ) :: boolean()
  defp cursor_on_screen?(
         {cursor_line, cursor_byte},
         _viewport,
         _fold_map,
         visual_entries,
         _visible_row_count,
         true
       ) do
    not is_nil(wrapped_cursor_entry(visual_entries, cursor_line, cursor_byte))
  end

  defp cursor_on_screen?(
         {cursor_line, _cursor_byte},
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
          [visual_row_entry()]
        ) :: {non_neg_integer(), non_neg_integer()}
  defp compute_wrapped_display_cursor(cursor_line, cursor_byte, visual_entries) do
    case wrapped_cursor_entry(visual_entries, cursor_line, cursor_byte) do
      {entry, offset} -> {entry.display_row, VisualRow.display_col_at_composed(entry, offset)}
      nil -> {0, 0}
    end
  end

  defp wrapped_cursor_entry(entries, line, byte) do
    case Enum.filter(entries, &source_selection_entry?(&1, line, line)) do
      [] ->
        nil

      [first | _] = entries ->
        map = first.source_offset_map
        offset = cursor_composed_utf16(first, byte)
        line_end = composed_line_end(map.spans)

        matching =
          Enum.find(entries, fn entry ->
            offset >= entry.composed_start_utf16 and
              (offset < entry.composed_end_utf16 or
                 (offset == line_end and offset == entry.composed_end_utf16))
          end)

        if matching, do: {matching, offset}
    end
  end

  defp composed_line_end([]), do: 0
  defp composed_line_end(spans), do: spans |> List.last() |> elem(4)

  defp cursor_composed_utf16(
         %VisualRow{row: %Row{row_type: :fold_start}, source_text: text, source_offset_map: map},
         byte
       )
       when byte == byte_size(text),
       do: SourceOffsetMap.source_to_composed_utf16(map, byte, :end)

  defp cursor_composed_utf16(%VisualRow{source_offset_map: map}, byte),
    do: SourceOffsetMap.source_to_composed_utf16(map, byte, :start)

  @spec visual_entry_for_source_byte([visual_row_entry()], non_neg_integer()) ::
          visual_row_entry() | nil
  defp visual_entry_for_source_byte([], _cursor_byte), do: nil

  defp visual_entry_for_source_byte(entries, cursor_byte) do
    Enum.find(entries, fn entry ->
      cursor_byte >= entry.source_start_byte and cursor_byte < entry.source_end_byte
    end)
  end

  @spec adjust_cursor_col_for_shape(
          non_neg_integer(),
          non_neg_integer(),
          RenderWindow.cursor_shape(),
          [Row.t()]
        ) :: non_neg_integer()
  defp active_cursor_shape(state, true), do: Editing.cursor_shape(state)
  defp active_cursor_shape(_state, false), do: :block

  defp cursor_eligible?(state, true), do: not Editing.minibuffer_mode?(state)
  defp cursor_eligible?(_state, false), do: false

  @spec cursor_presentation_visibility(
          boolean(),
          boolean(),
          non_neg_integer(),
          non_neg_integer(),
          WindowScroll.t(),
          :windowed | {:resident, non_neg_integer()},
          RenderWindow.content_kind()
        ) :: {boolean(), boolean()}
  defp cursor_presentation_visibility(true, true, col, width, scroll, store_mode, content_kind) do
    visible =
      wrapped_coordinates?(scroll) or Viewport.includes_column?(scroll.viewport, col, width)

    # A local pan can reveal a windowed caret before the BEAM commits its new clip.
    retain_source =
      visible or (store_mode == :windowed and content_kind == :buffer and not scroll.wrap_on)

    {visible, retain_source}
  end

  defp cursor_presentation_visibility(
         _eligible,
         _on_screen,
         _col,
         _width,
         _scroll,
         _store_mode,
         _content_kind
       ),
       do: {false, false}

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
          [visual_row_entry()],
          :windowed | {:resident, non_neg_integer()}
        ) :: Gutter.t() | nil
  defp build_gutter(
         %WindowScroll{} = scroll,
         %Context{} = ctx,
         content_kind,
         visual_entries,
         row_store_mode
       )
       when content_kind in [:buffer, :agent_chat] do
    %WindowScroll{
      win_layout: %{content: {content_row, content_col, full_width, content_height}},
      cursor_line: cursor_line,
      snapshot: snapshot,
      content_w: _content_w,
      line_number_style: line_number_style,
      is_active: is_active
    } = scroll

    win_id = scroll.window.id

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
      entries: build_gutter_entries(scroll, ctx, line_count, visual_entries, row_store_mode)
    }
  end

  defp build_gutter(_scroll, _ctx, _content_kind, _visual_entries, _mode), do: nil

  @spec build_geometry(state(), WindowScroll.t(), RenderWindow.content_kind(), term()) ::
          PaneGeometry.t()
  defp build_geometry(state, %WindowScroll{} = scroll, content_kind, mode) do
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
      window_id: scroll.window.id,
      total_rect: total_rect,
      content_rect: content_rect,
      text_rect: text_rect,
      gutter_rect: gutter_rect,
      clip_rect: text_rect,
      viewport: viewport_summary(scroll, text_width, mode),
      gutter_metrics: metrics,
      hit_regions: hit_regions(state, scroll.window.id, text_rect, gutter_rect, metrics)
    }
  end

  @spec horizontal_pan_limit(
          [VisualRow.t()],
          PaneGeometry.t(),
          RenderWindow.content_kind(),
          boolean(),
          term()
        ) :: non_neg_integer()
  defp horizontal_pan_limit(rows, %PaneGeometry{} = geometry, :buffer, false, capabilities) do
    {_row, _col, width, height} = geometry.text_rect
    width = pan_aperture_width(width, height, geometry.viewport, capabilities)
    widest = Enum.reduce(rows, 0, fn row, acc -> max(row.row_width, acc) end)
    min(max(widest - width, 0), 0xFFFF)
  end

  defp horizontal_pan_limit(_rows, _geometry, _kind, _wrapped, _capabilities), do: 0

  @spec pan_aperture_width(non_neg_integer(), non_neg_integer(), RenderViewport.t(), term()) ::
          pos_integer()
  defp pan_aperture_width(width, height, %{total_lines: lines}, %{frontend_type: :tui})
       when width > 1 and height > 0 and lines > height,
       do: width - 1

  defp pan_aperture_width(width, _height, _viewport, _capabilities), do: max(width, 1)

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

  @spec viewport_summary(WindowScroll.t(), non_neg_integer(), term()) :: RenderViewport.t()
  defp viewport_summary(%WindowScroll{} = scroll, text_width, mode) do
    %RenderViewport{
      top: scroll.viewport.top,
      left: scroll.viewport.left,
      rows: Viewport.content_rows(scroll.viewport),
      cols: text_width,
      total_lines: max(scroll.snapshot.line_count, 0),
      visual_row_offset: presentation_offset(scroll),
      total_visual_rows: total_visual_rows(scroll, mode)
    }
  end

  defp presentation_offset(%WindowScroll{visible_line_map: %DisplayMap{}}), do: 0
  defp presentation_offset(scroll), do: scroll.viewport.visual_row_offset

  @spec total_visual_rows(WindowScroll.t(), term()) :: non_neg_integer()
  defp total_visual_rows(_scroll, {:resident, total}), do: total

  defp total_visual_rows(%WindowScroll{total_visual_rows: total}, :windowed)
       when is_integer(total) and total > 0, do: total

  defp total_visual_rows(
         %WindowScroll{visible_line_map: %DisplayMap{}, snapshot: snapshot},
         :windowed
       ),
       do: max(snapshot.line_count, 0)

  defp total_visual_rows(%WindowScroll{wrap_on: false, snapshot: snapshot}, :windowed),
    do: max(snapshot.line_count, 0)

  defp total_visual_rows(%WindowScroll{}, :windowed), do: 0

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
    windows = state.windows

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
          [visual_row_entry()],
          :windowed | {:resident, non_neg_integer()}
        ) :: [GutterEntry.t()] | ResidentRows.t()

  defp build_gutter_entries(scroll, ctx, line_count, _entries, {:resident, _visual_count}) do
    fold_ranges = scroll.window.fold_ranges
    fold_start_lines = MapSet.new(fold_ranges, & &1.start_line)
    fold_end_by_start = Map.new(fold_ranges, &{&1.start_line, &1.end_line})

    # Normal rows have no sign by default; only semantic exceptions need stored entries.
    annotation_lines =
      for annotation <- ctx.decorations.annotations,
          annotation.kind == :gutter_icon,
          do: annotation.line

    overrides =
      (Map.keys(ctx.git_signs) ++
         Map.keys(ctx.diagnostic_signs) ++
         MapSet.to_list(fold_start_lines) ++ annotation_lines)
      |> Enum.uniq()
      |> Enum.filter(&(&1 >= 0 and &1 < line_count))
      |> Enum.sort()
      |> Enum.map(fn line ->
        resolve_gutter_entry(
          {line, :normal},
          fold_start_lines,
          fold_end_by_start,
          ctx,
          line_count
        )
      end)

    %ResidentRows{
      content_epoch: scroll.content_epoch,
      line_count: line_count,
      overrides: overrides
    }
  end

  defp build_gutter_entries(_scroll, _ctx, 0, _visual_entries, :windowed), do: []

  defp build_gutter_entries(
         %WindowScroll{} = scroll,
         %Context{} = ctx,
         line_count,
         visual_entries,
         :windowed
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

  @spec build_indent_guides(WindowScroll.t(), Context.t(), RenderWindow.content_kind(), [
          visual_row_entry()
        ]) ::
          IndentGuides.t()
  defp build_indent_guides(%WindowScroll{} = scroll, _ctx, content_kind, _entries)
       when content_kind != :buffer,
       do: IndentGuides.empty(scroll.window.id)

  defp build_indent_guides(%WindowScroll{} = scroll, %Context{} = ctx, :buffer, entries) do
    if indent_guides_enabled?() do
      lines = Enum.map(entries, &VisualRow.guide_source_line/1)

      {guides, levels} = IndentGuide.compute_with_levels(lines, ctx.tab_width, ctx.cursor_col)
      indent_guides_from_guides(scroll.window.id, ctx.tab_width, guides, levels)
    else
      IndentGuides.empty(scroll.window.id)
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

  @spec accessibility_selection_ranges(
          Selection.visual_selection(),
          [visual_row_entry()]
        ) :: [{non_neg_integer(), non_neg_integer(), non_neg_integer()}]
  defp accessibility_selection_ranges(nil, _entries), do: []

  defp accessibility_selection_ranges(
         {:char, {start_line, start_byte}, {end_line, end_byte}},
         entries
       ) do
    # If the endpoint source line is not visible, all selected visible lines
    # end at their own source boundary.
    end_exclusive =
      case Enum.find(entries, &(&1.buf_line == end_line)) do
        nil -> end_byte
        entry -> VisualRow.source_character_end(entry, end_byte)
      end

    entries
    |> Enum.filter(&source_selection_entry?(&1, start_line, end_line))
    |> Enum.flat_map(fn entry ->
      accessibility_char_range(entry, start_line, start_byte, end_line, end_exclusive)
    end)
  end

  defp accessibility_selection_ranges({:line, start_line, end_line}, entries) do
    entries
    |> Enum.filter(&source_selection_entry?(&1, start_line, end_line))
    |> Enum.map(fn entry ->
      {entry.display_row, 0, utf16_offset(entry.row.text, byte_size(entry.row.text))}
    end)
  end

  @spec source_selection_entry?(visual_row_entry(), non_neg_integer(), non_neg_integer()) ::
          boolean()
  defp source_selection_entry?(%VisualRow{row: %Row{row_type: row_type}}, _start, _end)
       when row_type in [:virtual_line, :block],
       do: false

  defp source_selection_entry?(%VisualRow{buf_line: line}, start_line, end_line),
    do: line >= start_line and line <= end_line

  @spec accessibility_char_range(
          visual_row_entry(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [{non_neg_integer(), non_neg_integer(), non_neg_integer()}]
  defp accessibility_char_range(entry, start_line, start_byte, end_line, end_exclusive) do
    range_start = if entry.buf_line == start_line, do: start_byte, else: entry.source_start_byte
    range_end = if entry.buf_line == end_line, do: end_exclusive, else: entry.source_end_byte
    selected_start = max(range_start, entry.source_start_byte)
    selected_end = min(range_end, entry.source_end_byte)
    start_clipped = entry.buf_line != start_line or range_start < entry.source_start_byte
    end_clipped = entry.buf_line != end_line or range_end > entry.source_end_byte

    accessibility_entry_utf16_range(
      entry,
      selected_start,
      selected_end,
      start_clipped,
      end_clipped
    )
  end

  @spec accessibility_entry_utf16_range(
          visual_row_entry(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          boolean()
        ) :: [{non_neg_integer(), non_neg_integer(), non_neg_integer()}]
  defp accessibility_entry_utf16_range(_entry, start_byte, end_byte, _start_clipped, _end_clipped)
       when end_byte <= start_byte,
       do: []

  defp accessibility_entry_utf16_range(
         entry,
         start_byte,
         end_byte,
         start_clipped,
         end_clipped
       ) do
    row_utf16 = utf16_offset(entry.row.text, byte_size(entry.row.text))
    indent_utf16 = max(row_utf16 - (entry.composed_end_utf16 - entry.composed_start_utf16), 0)

    start_utf16 =
      accessibility_composed_utf16(entry, start_byte, :start, indent_utf16, start_clipped)

    end_utf16 =
      accessibility_composed_utf16(entry, end_byte, :end, indent_utf16, end_clipped)

    if end_utf16 > start_utf16 do
      [{entry.display_row, min(start_utf16, row_utf16), min(end_utf16, row_utf16)}]
    else
      []
    end
  end

  @spec accessibility_composed_utf16(
          visual_row_entry(),
          non_neg_integer(),
          SourceOffsetMap.affinity(),
          non_neg_integer(),
          boolean()
        ) :: non_neg_integer()
  defp accessibility_composed_utf16(_entry, _source_byte, :start, _indent_utf16, true), do: 0

  defp accessibility_composed_utf16(entry, _source_byte, :end, _indent_utf16, true) do
    utf16_offset(entry.row.text, byte_size(entry.row.text))
  end

  defp accessibility_composed_utf16(entry, source_byte, affinity, indent_utf16, false) do
    composed_utf16 =
      SourceOffsetMap.source_to_composed_utf16(entry.source_offset_map, source_byte, affinity)

    composed_utf16
    |> Kernel.-(entry.composed_start_utf16)
    |> Kernel.+(indent_utf16)
    |> max(0)
    |> min(utf16_offset(entry.row.text, byte_size(entry.row.text)))
  end

  @spec accessibility_cursor(
          boolean(),
          {non_neg_integer(), non_neg_integer()},
          {non_neg_integer(), non_neg_integer()},
          visual_row_entry() | nil
        ) :: {non_neg_integer(), non_neg_integer()} | nil
  defp accessibility_cursor(false, _display, _source_position, _entry),
    do: nil

  defp accessibility_cursor(
         true,
         {row_index, _display_col},
         {_cursor_line, cursor_byte},
         %VisualRow{} = entry
       ) do
    row_utf16 = utf16_offset(entry.row.text, byte_size(entry.row.text))
    indent_utf16 = max(row_utf16 - (entry.composed_end_utf16 - entry.composed_start_utf16), 0)

    cursor_utf16 =
      entry
      |> cursor_composed_utf16(cursor_byte)
      |> Kernel.-(entry.composed_start_utf16)
      |> Kernel.+(indent_utf16)
      |> max(0)
      |> min(row_utf16)

    {row_index, cursor_utf16}
  end

  defp accessibility_cursor(true, _display, _source_position, nil), do: nil

  @spec utf16_offset(String.t(), non_neg_integer()) :: non_neg_integer()
  defp utf16_offset(text, byte_offset) do
    text
    |> binary_part(0, min(byte_offset, byte_size(text)))
    |> utf16_units(0)
  end

  defp utf16_units(<<>>, units), do: units

  defp utf16_units(<<cp::utf8, rest::binary>>, units),
    do: utf16_units(rest, units + if(cp > 0xFFFF, do: 2, else: 1))

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
          [Diagnostic.t()],
          Viewport.t(),
          pos_integer(),
          [visual_row_entry()],
          boolean(),
          [String.t()] | DisplayMap.t(),
          non_neg_integer(),
          ResidentBuild.t() | nil
        ) :: [DiagnosticRange.t()]
  defp build_diagnostic_ranges(
         diagnostics,
         viewport,
         visible_rows,
         visual_entries,
         wrapped?,
         lines,
         first_line,
         resident_build
       ) do
    case source_backed_diagnostics(diagnostics, resident_build) do
      [] ->
        []

      diagnostics ->
        viewport_bottom = viewport.top + visible_rows
        line_cache = diagnostic_line_cache(diagnostics, lines, first_line, resident_build)

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

  defp diagnostic_source(%WindowScroll{visible_line_map: %DisplayMap{} = page}), do: page
  defp diagnostic_source(%WindowScroll{lines: lines}), do: lines

  @spec source_backed_diagnostics([Diagnostic.t()], ResidentBuild.t() | nil) :: [Diagnostic.t()]
  defp source_backed_diagnostics(diagnostics, nil), do: diagnostics

  defp source_backed_diagnostics(diagnostics, %ResidentBuild{line_count: count}) do
    Enum.filter(diagnostics, fn %{range: range} ->
      range.start_line < count and range.end_line < count
    end)
  end

  @spec diagnostic_line_cache(
          [Diagnostic.t()],
          [String.t()] | DisplayMap.t(),
          non_neg_integer(),
          ResidentBuild.t() | nil
        ) :: %{
          non_neg_integer() => String.t()
        }
  defp diagnostic_line_cache(diagnostics, lines, first_line, resident_build) do
    diagnostics
    |> Enum.flat_map(fn diag -> [diag.range.start_line, diag.range.end_line] end)
    |> Enum.uniq()
    |> Map.new(fn line ->
      {line, diagnostic_source_line(line, lines, first_line, resident_build)}
    end)
  end

  @spec diagnostic_source_line(
          non_neg_integer(),
          [String.t()] | DisplayMap.t(),
          non_neg_integer(),
          ResidentBuild.t() | nil
        ) :: String.t()
  defp diagnostic_source_line(line, _lines, _first_line, %ResidentBuild{store: store}) do
    case ResidentStore.source_row(store, line) do
      {:ok, %VisualRow{source_text: text}} -> text
      :error -> raise ArgumentError, "diagnostic source line is outside the resident store"
    end
  end

  defp diagnostic_source_line(line, %DisplayMap{} = page, _first_line, nil),
    do: DisplayMap.source_text(page, line)

  defp diagnostic_source_line(line, lines, first_line, nil), do: line_at(lines, line, first_line)

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
  defp build_wrapped_char_selection(start_line, start_byte, end_line, end_byte, visual_entries) do
    selected_entries = visual_entries_for_line_range(visual_entries, start_line, end_line)

    with [_ | _] <- selected_entries,
         {start_entry, projected_start_byte} <-
           selection_start_entry(selected_entries, start_line, start_byte),
         {end_entry, projected_end_byte} <-
           selection_end_entry(selected_entries, end_line, end_byte) do
      %Selection{
        type: :char,
        start_row: start_entry.display_row,
        start_col: selection_visual_col(start_entry, projected_start_byte, :start),
        end_row: end_entry.display_row,
        end_col: selection_visual_col(end_entry, projected_end_byte, :end)
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

  @spec selection_start_entry(
          [visual_row_entry()],
          non_neg_integer(),
          non_neg_integer()
        ) :: {visual_row_entry(), non_neg_integer()}
  defp selection_start_entry(entries, line, source_byte) do
    line_entries = Enum.filter(entries, &(&1.buf_line == line))

    case visual_entry_for_source_byte(line_entries, source_byte) do
      nil ->
        entry = endpoint_fallback(entries, :first)
        {entry, entry.source_start_byte}

      entry ->
        {entry, source_byte}
    end
  end

  @spec selection_end_entry(
          [visual_row_entry()],
          non_neg_integer(),
          non_neg_integer()
        ) :: {visual_row_entry(), non_neg_integer()}
  defp selection_end_entry(entries, line, source_byte) do
    line_entries = Enum.filter(entries, &(&1.buf_line == line))

    case line_entries do
      [] ->
        entry = endpoint_fallback(entries, :last)
        {entry, entry.source_end_byte}

      [first | _] ->
        source_end = Unicode.next_grapheme_byte_offset(first.source_text, source_byte)
        entry = last_entry_intersecting_source(line_entries, source_byte, source_end)
        entry = entry || endpoint_fallback(line_entries, :last)
        {entry, min(source_end, entry.source_end_byte)}
    end
  end

  @spec last_entry_intersecting_source(
          [visual_row_entry()],
          non_neg_integer(),
          non_neg_integer()
        ) :: visual_row_entry() | nil
  defp last_entry_intersecting_source(entries, source_start, source_end) do
    entries
    |> Enum.filter(fn entry ->
      entry.source_start_byte < source_end and entry.source_end_byte > source_start
    end)
    |> Enum.at(-1)
  end

  @spec endpoint_fallback([visual_row_entry()], :first | :last) :: visual_row_entry()
  defp endpoint_fallback(entries, :first), do: hd(entries)
  defp endpoint_fallback(entries, :last), do: Enum.at(entries, -1)

  @spec visual_entries_for_line_range([visual_row_entry()], non_neg_integer(), non_neg_integer()) ::
          [
            visual_row_entry()
          ]
  defp visual_entries_for_line_range(visual_entries, start_line, end_line) do
    Enum.filter(visual_entries, &source_selection_entry?(&1, start_line, end_line))
  end

  @spec first_visual_entry_for_line([visual_row_entry()], non_neg_integer()) ::
          visual_row_entry() | nil
  defp first_visual_entry_for_line(visual_entries, line) do
    Enum.find(visual_entries, &source_selection_entry?(&1, line, line))
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
          visual_col_for_source_byte(entry, range_start, :start),
          entry.display_row,
          visual_col_for_source_byte(entry, range_end, :end)
        )
      ]
    else
      []
    end
  end

  @spec selection_visual_col(visual_row_entry(), non_neg_integer(), :start | :end) ::
          non_neg_integer()
  defp selection_visual_col(entry, source_byte, :start)
       when source_byte <= entry.source_start_byte,
       do: 0

  defp selection_visual_col(entry, source_byte, :end)
       when source_byte >= entry.source_end_byte,
       do: entry.row_width

  defp selection_visual_col(entry, source_byte, affinity) do
    visual_col_for_source_byte(entry, source_byte, affinity)
  end

  @spec visual_col_for_source_byte(
          visual_row_entry(),
          non_neg_integer(),
          SourceOffsetMap.affinity()
        ) :: non_neg_integer()
  defp visual_col_for_source_byte(entry, source_byte, affinity) do
    VisualRow.display_col(entry, source_byte, affinity)
  end

  @spec visual_col_for_source_col(visual_row_entry(), non_neg_integer()) :: non_neg_integer()
  defp visual_col_for_source_col(entry, source_col) do
    source_col
    |> min(entry.source_end_col)
    |> max(entry.source_start_col)
    |> Kernel.-(entry.source_start_col)
    |> Kernel.+(entry.indent_width)
  end

  @spec utf16_at_display_col(String.t(), non_neg_integer()) :: non_neg_integer()
  defp utf16_at_display_col(text, display_col) do
    do_utf16_at_display_col(text, display_col, 0, 0)
  end

  @spec do_utf16_at_display_col(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp do_utf16_at_display_col("", _target_col, _current_col, utf16), do: utf16

  defp do_utf16_at_display_col(text, target_col, current_col, utf16) do
    case String.next_grapheme(text) do
      {grapheme, rest} ->
        next_col = current_col + Unicode.grapheme_width(grapheme)

        if next_col > target_col do
          utf16
        else
          do_utf16_at_display_col(
            rest,
            target_col,
            next_col,
            utf16 + utf16_offset(grapheme, byte_size(grapheme))
          )
        end

      nil ->
        utf16
    end
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

  @spec virtual_text_to_string(Decorations.VirtualText.t()) :: String.t()
  defp virtual_text_to_string(%{segments: segments}) do
    Enum.map_join(segments, fn {text, _style} -> text end)
  end

  @spec virtual_text_spans(Decorations.VirtualText.t(), FontRegistry.t()) ::
          {[Span.t()], FontRegistry.t()}
  defp virtual_text_spans(%{segments: segments}, %FontRegistry{} = font_registry) do
    segments_to_spans(segments, font_registry)
  end

  @spec segments_to_spans([{String.t(), Minga.Core.Face.t()}], FontRegistry.t()) ::
          {[Span.t()], FontRegistry.t()}
  defp segments_to_spans(segments, %FontRegistry{} = font_registry) do
    {spans, _col, font_registry} =
      Enum.reduce(segments, {[], 0, font_registry}, fn
        {text, style}, {acc, col, registry} ->
          width = Unicode.display_width(text)

          if width > 0 do
            {font_id, registry} = font_id_for_face(style, registry)
            span = Span.from_face(style, col, col + width, font_id)
            {[span | acc], col + width, registry}
          else
            {acc, col, registry}
          end
      end)

    {Enum.reverse(spans), font_registry}
  end

  @spec font_id_for_face(Minga.Core.Face.t(), FontRegistry.t()) ::
          {non_neg_integer(), FontRegistry.t()}
  defp font_id_for_face(%Minga.Core.Face{font_family: nil}, %FontRegistry{} = registry),
    do: {0, registry}

  defp font_id_for_face(
         %Minga.Core.Face{font_family: family},
         %FontRegistry{} = registry
       )
       when is_binary(family) do
    {font_id, updated_registry, _new?} = FontRegistry.get_or_register(registry, family)
    {font_id, updated_registry}
  end
end
