defmodule Minga.Editor.RenderPipeline do
  @moduledoc """
  Named pipeline stages for the rendering pass.

  The render pipeline decomposes the monolithic `Renderer.render/1` into
  seven named stages with typed inputs and outputs. Each stage is a
  public function you can call independently with mock inputs for testing.

  ## Stages

  1. **Invalidation** — decides what needs redrawing. Currently a stub
     that always marks everything dirty (full redraw every frame).
  2. **Layout** — computes screen rectangles via `Layout.put/1`.
  3. **Scroll** — per-window viewport adjustment + buffer data fetch.
  4. **Content** — builds display list draws for each window's lines,
     gutter, and tildes.
  5. **Chrome** — builds modeline, minibuffer, overlays, separators,
     file tree, agent panel, and region definitions.
  6. **Compose** — merges content + chrome into a `Frame` struct,
     resolves cursor position and shape.
  7. **Emit** — converts frame to protocol commands and sends to the
     Zig port.

  ## Observability

  Each stage logs its name and elapsed time via `Logger.debug`. Set log
  level to `:debug` to see per-stage timing. In production (`:info` or
  higher), these calls are no-ops.
  """

  require Logger

  alias Minga.Agent.ChatRenderer
  alias Minga.Agent.Session
  alias Minga.Agent.View.Renderer, as: ViewRenderer
  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Config.Options
  alias Minga.Diagnostics
  alias Minga.Editor.CompletionUI
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Frame, Overlay, WindowFrame}
  alias Minga.Editor.DocumentSync
  alias Minga.Editor.Layout
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.Modeline
  alias Minga.Editor.PickerUI
  alias Minga.Editor.Renderer.BufferLine
  alias Minga.Editor.Renderer.Caps
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Renderer.Gutter
  alias Minga.Editor.Renderer.Minibuffer
  alias Minga.Editor.Renderer.Regions
  alias Minga.Editor.Renderer.SearchHighlight
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Title
  alias Minga.Editor.TreeRenderer
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Editor.WrapMap
  alias Minga.Git.Buffer, as: GitBuffer
  alias Minga.Mode.VisualState
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol
  alias Minga.Theme
  alias Minga.WhichKey

  # Agent input area = 3 rows (border + text + padding); cursor goes on the text row.
  @agent_input_height 3

  # ── Stage result types ─────────────────────────────────────────────────────

  defmodule Invalidation do
    @moduledoc """
    Output of the invalidation stage.

    Currently a stub that always requests a full redraw. Future work
    (#164) will track dirty windows and lines for incremental rendering.
    """

    defstruct full_redraw: true

    @type t :: %__MODULE__{
            full_redraw: boolean()
          }
  end

  defmodule WindowScroll do
    @moduledoc """
    Per-window data produced by the scroll stage.

    Bundles the viewport, buffer snapshot, cursor positions, and gutter
    dimensions for one window. The content stage consumes this to produce
    draws without making any GenServer calls.
    """

    @enforce_keys [
      :win_id,
      :window,
      :win_layout,
      :is_active,
      :viewport,
      :cursor_line,
      :cursor_byte_col,
      :cursor_col,
      :first_line,
      :lines,
      :snapshot,
      :gutter_w,
      :content_w,
      :has_sign_column,
      :preview_matches,
      :line_number_style,
      :wrap_on,
      :buf_version
    ]

    defstruct [
      :win_id,
      :window,
      :win_layout,
      :is_active,
      :viewport,
      :cursor_line,
      :cursor_byte_col,
      :cursor_col,
      :first_line,
      :lines,
      :snapshot,
      :gutter_w,
      :content_w,
      :has_sign_column,
      :preview_matches,
      :line_number_style,
      :wrap_on,
      :buf_version
    ]

    @type t :: %__MODULE__{
            win_id: Window.id(),
            window: Window.t(),
            win_layout: Layout.window_layout(),
            is_active: boolean(),
            viewport: Viewport.t(),
            cursor_line: non_neg_integer(),
            cursor_byte_col: non_neg_integer(),
            cursor_col: non_neg_integer(),
            first_line: non_neg_integer(),
            lines: [String.t()],
            snapshot: map(),
            gutter_w: non_neg_integer(),
            content_w: pos_integer(),
            has_sign_column: boolean(),
            preview_matches: list(),
            line_number_style: atom(),
            wrap_on: boolean(),
            buf_version: non_neg_integer()
          }
  end

  defmodule Chrome do
    @moduledoc """
    Output of the chrome stage: all non-content UI draws.

    Includes modeline, minibuffer, separators, file tree, agent panel
    sidebar, overlays, and region definitions.
    """

    alias Minga.Editor.DisplayList
    alias Minga.Editor.DisplayList.Overlay

    defstruct modeline_draws: %{},
              modeline_click_regions: [],
              minibuffer: [],
              separators: [],
              file_tree: [],
              agent_panel: [],
              overlays: [],
              regions: []

    @type t :: %__MODULE__{
            modeline_draws: %{non_neg_integer() => [DisplayList.draw()]},
            modeline_click_regions: [Minga.Editor.Modeline.click_region()],
            minibuffer: [DisplayList.draw()],
            separators: [DisplayList.draw()],
            file_tree: [DisplayList.draw()],
            agent_panel: [DisplayList.draw()],
            overlays: [Overlay.t()],
            regions: [binary()]
          }
  end

  # ── Orchestrator ───────────────────────────────────────────────────────────

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc """
  Runs the full render pipeline for the current editor state.

  Returns updated state with per-window render caches populated.
  The caller must use the returned state for dirty-line tracking
  to work across frames.
  """
  @spec run(state()) :: state()
  def run(state) do
    # Pre-pipeline: sync cursor
    state = EditorState.sync_active_window_cursor(state)

    # Stage 1: Invalidation (global triggers: visual selection, search, theme)
    state = timed(:invalidation, fn -> invalidate(state) end)

    # Stage 2: Layout
    state = timed(:layout, fn -> compute_layout(state) end)
    layout = Layout.get(state)

    debug_layout(state, layout)

    if state.agentic.active do
      run_agentic(state, layout)
    else
      run_windows(state, layout)
    end
  end

  @spec run_windows(state(), Layout.t()) :: state()
  defp run_windows(state, layout) do
    # Stage 3: Scroll (also runs per-window invalidation detection)
    {scrolls, state} = timed(:scroll, fn -> scroll_windows(state, layout) end)

    # Stage 4: Content (skips clean lines, updates window caches)
    {window_frames, cursor_info, state} =
      timed(:content, fn -> build_content(state, scrolls) end)

    # Stage 5: Chrome
    chrome = timed(:chrome, fn -> build_chrome(state, layout, scrolls, cursor_info) end)

    # Cache modeline click regions on state for mouse hit-testing
    state = %{state | modeline_click_regions: chrome.modeline_click_regions}

    # Stage 6: Compose
    frame =
      timed(:compose, fn -> compose_windows(window_frames, chrome, cursor_info, state) end)

    # Stage 7: Emit
    timed(:emit, fn -> emit(frame, state) end)

    state
  end

  @spec run_agentic(state(), Layout.t()) :: state()
  defp run_agentic(state, layout) do
    # Agentic path: Content is the ViewRenderer, Chrome is minimal
    panel_draws = timed(:content, fn -> ViewRenderer.render(state) end)

    chrome = timed(:chrome, fn -> build_chrome_agentic(state, layout) end)

    frame =
      timed(:compose, fn -> compose_agentic(panel_draws, chrome, state) end)

    timed(:emit, fn -> emit(frame, state) end)

    state
  end

  # ── Stage 1: Invalidation ─────────────────────────────────────────────────

  @doc """
  Invalidation stage (Stage 1). Currently a pass-through.

  All invalidation is handled by two mechanisms downstream:

  * **Structural invalidation** in `scroll_windows/2`: viewport scroll,
    gutter width, line count, buffer version changes detected via
    `Window.detect_invalidation/5`.

  * **Context invalidation** in `build_window_content/2`: visual
    selection, search matches, syntax highlights, diagnostic/git signs,
    horizontal scroll, active status, and theme colors detected via
    `Window.detect_context_change/2` using a fingerprint of the
    render context.
  """
  @spec invalidate(state()) :: state()
  def invalidate(state) do
    state
  end

  # ── Stage 2: Layout ────────────────────────────────────────────────────────

  @doc """
  Computes and caches the layout in editor state.

  Thin wrapper around `Layout.put/1`. Returns the updated state with
  the layout cached for downstream stages.
  """
  @spec compute_layout(state()) :: state()
  def compute_layout(state) do
    Layout.put(state)
  end

  # ── Stage 3: Scroll ────────────────────────────────────────────────────────

  @doc """
  Per-window viewport adjustment and buffer data fetch.

  For each window in the layout, reads the cursor position, computes
  the viewport scroll, fetches buffer lines, and determines gutter
  dimensions. Also runs per-window invalidation detection by comparing
  current scroll position, gutter width, line count, and buffer version
  against the window's tracking fields from the previous frame.

  Returns `{scrolls, updated_state}` where `updated_state` has the
  windows map updated with invalidation results.
  """
  @spec scroll_windows(state(), Layout.t()) :: {%{Window.id() => WindowScroll.t()}, state()}
  def scroll_windows(state, layout) do
    layout.window_layouts
    |> Enum.reduce({%{}, state}, fn {win_id, win_layout}, {acc, st} ->
      window = Map.get(st.windows.map, win_id)

      if window == nil or window.buffer == nil do
        {acc, st}
      else
        is_active = win_id == state.windows.active
        scroll = scroll_window(st, win_id, window, win_layout, is_active)

        # Detect per-window invalidation by comparing against last frame
        updated_window =
          Window.detect_invalidation(
            window,
            scroll.viewport.top,
            scroll.gutter_w,
            scroll.snapshot.line_count,
            scroll.buf_version
          )

        # Also invalidate gutter when cursor line changed with relative numbering
        updated_window =
          detect_gutter_invalidation(
            updated_window,
            scroll.cursor_line,
            scroll.line_number_style
          )

        # Store the invalidated window and update the scroll to reference it
        scroll = %{scroll | window: updated_window}

        new_map = Map.put(st.windows.map, win_id, updated_window)
        st = %{st | windows: %{st.windows | map: new_map}}

        {Map.put(acc, win_id, scroll), st}
      end
    end)
  end

  @spec scroll_window(
          state(),
          Window.id(),
          Window.t(),
          Layout.window_layout(),
          boolean()
        ) :: WindowScroll.t()
  defp scroll_window(state, win_id, window, win_layout, is_active) do
    {_row_off, _col_off, content_width, content_height} = win_layout.content

    # Cursor: active window reads live from buffer; inactive uses stored
    {cursor_line, cursor_byte_col} = window_cursor(window, is_active)

    # Viewport from Layout content rect
    wrap_on = wrap_enabled?()
    viewport = Viewport.new(content_height, content_width, 0)
    viewport = Viewport.scroll_to_cursor(viewport, {cursor_line, 0})
    {first_line, _last_line} = Viewport.visible_range(viewport)
    visible_rows = Viewport.content_rows(viewport)

    # Fetch buffer data
    fetch_rows = if wrap_on, do: visible_rows + div(visible_rows, 2), else: visible_rows
    snapshot = BufferServer.render_snapshot(window.buffer, first_line, fetch_rows)
    lines = snapshot.lines
    line_count = snapshot.line_count

    # Cursor byte → display col
    cursor_line_text = cursor_line_text(lines, cursor_line, first_line)
    cursor_col = Unicode.display_col(cursor_line_text, cursor_byte_col)

    # Gutter dimensions
    line_number_style = state.line_numbers

    {has_sign_column, gutter_w} =
      gutter_dimensions(state, window.buffer, line_number_style, line_count)

    content_w = max(viewport.cols - gutter_w, 1)

    # Horizontal scroll (disabled when wrapping)
    viewport = scroll_horizontal(viewport, cursor_line, cursor_col, wrap_on)

    # Substitution preview (active window only)
    {lines, preview_matches} =
      if is_active do
        SearchHighlight.maybe_substitute_preview(state, lines, first_line)
      else
        {lines, []}
      end

    %WindowScroll{
      win_id: win_id,
      window: window,
      win_layout: win_layout,
      is_active: is_active,
      viewport: viewport,
      cursor_line: cursor_line,
      cursor_byte_col: cursor_byte_col,
      cursor_col: cursor_col,
      first_line: first_line,
      lines: lines,
      snapshot: snapshot,
      gutter_w: gutter_w,
      content_w: content_w,
      has_sign_column: has_sign_column,
      preview_matches: preview_matches,
      line_number_style: line_number_style,
      wrap_on: wrap_on,
      buf_version: snapshot.version
    }
  end

  # When cursor line changes with relative or hybrid numbering, every
  # gutter entry shows a different number. Mark all lines dirty for
  # re-render. With absolute numbering, cursor movement doesn't affect
  # gutter content so we only mark the old and new cursor lines.
  @spec detect_gutter_invalidation(Window.t(), non_neg_integer(), atom()) :: Window.t()
  defp detect_gutter_invalidation(window, cursor_line, line_number_style) do
    old_cursor = window.last_cursor_line

    if old_cursor == cursor_line or old_cursor < 0 do
      # Cursor didn't move or first frame (already :all dirty)
      window
    else
      case line_number_style do
        style when style in [:relative, :hybrid] ->
          # Every visible line number changes. Use mark_dirty (not
          # invalidate) because the content draws are still valid;
          # only gutter numbers change.
          Window.mark_dirty(window, :all)

        _ ->
          # Only the old and new cursor lines need gutter + cursor highlight update
          Window.mark_dirty(window, [old_cursor, cursor_line])
      end
    end
  end

  # ── Stage 4: Content ──────────────────────────────────────────────────────

  @doc """
  Builds display list draws for each window's buffer content.

  Produces `WindowFrame` structs (with gutter, lines, tildes, but
  without modeline; modeline is in the Chrome stage) and the absolute
  cursor position for the active window.
  """
  @spec build_content(state(), %{Window.id() => WindowScroll.t()}) ::
          {[WindowFrame.t()], {non_neg_integer(), non_neg_integer()} | nil, state()}
  def build_content(state, scrolls) do
    {frames, cursor_info, state} =
      Enum.reduce(scrolls, {[], nil, state}, fn {_win_id, scroll}, {frames, cursor_info, st} ->
        {wf, ci, st} = build_window_content(st, scroll)
        new_cursor = if scroll.is_active and ci != nil, do: ci, else: cursor_info
        {[wf | frames], new_cursor, st}
      end)

    {Enum.reverse(frames), cursor_info, state}
  end

  @spec build_window_content(state(), WindowScroll.t()) ::
          {WindowFrame.t(), {non_neg_integer(), non_neg_integer()} | nil, state()}
  defp build_window_content(state, scroll) do
    %WindowScroll{
      win_layout: win_layout,
      is_active: is_active,
      viewport: viewport,
      cursor_line: cursor_line,
      cursor_byte_col: cursor_byte_col,
      cursor_col: cursor_col,
      first_line: first_line,
      lines: lines,
      snapshot: snapshot,
      gutter_w: gutter_w,
      content_w: content_w,
      has_sign_column: has_sign_column,
      preview_matches: preview_matches,
      line_number_style: line_number_style,
      wrap_on: wrap_on,
      window: window
    } = scroll

    {row_off, col_off, content_width, content_height} = win_layout.content
    visible_rows = Viewport.content_rows(viewport)

    cursor = {cursor_line, cursor_byte_col}

    # Build per-frame render context
    render_ctx =
      build_render_ctx(state, window, %{
        viewport: viewport,
        cursor: cursor,
        lines: lines,
        first_line: first_line,
        preview_matches: preview_matches,
        gutter_w: gutter_w,
        content_w: content_w,
        has_sign_column: has_sign_column,
        is_active: is_active
      })

    # Compute context fingerprint and check for context changes.
    # If any context input (visual selection, search, highlights, signs,
    # horizontal scroll, active status) changed, all lines are dirty.
    ctx_fp = context_fingerprint(render_ctx, is_active)
    window = Window.detect_context_change(window, ctx_fp)

    # Render lines with dirty-aware loop
    line_opts = %{
      first_line: first_line,
      cursor_line: cursor_line,
      ctx: render_ctx,
      ln_style: line_number_style,
      gutter_w: gutter_w,
      first_byte_off: snapshot.first_line_byte_offset,
      row_off: row_off,
      col_off: col_off,
      window: window
    }

    {gutter_draws, line_draws, rows_used, window} =
      if wrap_on do
        # Wrapped mode: always full render (wrap maps change unpredictably)
        {g, l, r} = render_lines_wrapped(lines, visible_rows, line_opts)
        {g, l, r, window}
      else
        render_lines_nowrap(lines, line_opts)
      end

    # Tilde lines for empty space below content
    tilde_draws =
      if rows_used < visible_rows do
        for row <- rows_used..(visible_rows - 1) do
          DisplayList.draw(row + row_off, col_off + gutter_w, "~",
            fg: state.theme.editor.tilde_fg
          )
        end
      else
        []
      end

    # Build WindowFrame
    win_frame = %WindowFrame{
      rect: {0, 0, content_width, content_height},
      gutter: DisplayList.draws_to_layer(gutter_draws),
      lines: DisplayList.draws_to_layer(line_draws),
      tilde_lines: DisplayList.draws_to_layer(tilde_draws),
      modeline: %{},
      cursor:
        if(is_active,
          do:
            {cursor_line - viewport.top + row_off,
             gutter_w + cursor_col - viewport.left + col_off},
          else: nil
        )
    }

    cursor_info =
      if is_active do
        {cursor_line - viewport.top + row_off, gutter_w + cursor_col - viewport.left + col_off}
      else
        nil
      end

    # Snapshot tracking fields and prune cache to visible range
    last_visible = first_line + length(lines) - 1

    updated_window =
      window
      |> Window.snapshot_after_render(
        viewport.top,
        gutter_w,
        snapshot.line_count,
        cursor_line,
        scroll.buf_version,
        ctx_fp
      )
      |> Window.prune_cache(first_line, last_visible)

    new_map = Map.put(state.windows.map, scroll.win_id, updated_window)
    state = %{state | windows: %{state.windows | map: new_map}}

    {win_frame, cursor_info, state}
  end

  # Builds a fingerprint from the render context that captures all inputs
  # affecting every visible line. Used to detect context changes between
  # frames (visual selection, search, highlights, signs, scroll, etc.).
  @spec context_fingerprint(Context.t(), boolean()) :: Window.context_fingerprint()
  defp context_fingerprint(%Context{} = ctx, is_active) do
    # Highlight identity: use the version counter which increments each
    # time tree-sitter sends new spans. Comparing the full spans tuple
    # would be expensive; the version is a cheap proxy.
    hl_id =
      case ctx.highlight do
        nil -> nil
        hl -> hl.version
      end

    {
      ctx.visual_selection,
      ctx.search_matches,
      hl_id,
      ctx.diagnostic_signs,
      ctx.git_signs,
      ctx.viewport.left,
      is_active,
      ctx.confirm_match
    }
  end

  # ── Stage 5: Chrome ────────────────────────────────────────────────────────

  @doc """
  Builds all non-content UI draws: modeline, minibuffer, separators,
  file tree, agent panel sidebar, overlays, and region definitions.
  """
  @spec build_chrome(
          state(),
          Layout.t(),
          %{Window.id() => WindowScroll.t()},
          {non_neg_integer(), non_neg_integer()} | nil
        ) :: Chrome.t()
  def build_chrome(state, layout, scrolls, cursor_info) do
    full_viewport = state.viewport

    # Modeline per window
    {modeline_draws, modeline_click_regions} =
      Enum.reduce(scrolls, {%{}, []}, fn {win_id, scroll}, {draws_acc, regions_acc} ->
        {draws, regions} = render_window_modeline(state, scroll)
        {Map.put(draws_acc, win_id, draws), regions ++ regions_acc}
      end)

    # Separators (vertical split borders)
    separator_draws =
      if EditorState.split?(state) do
        render_separators(
          state.windows.tree,
          layout.editor_area,
          elem(layout.editor_area, 3),
          state.theme
        )
      else
        []
      end

    # File tree
    tree_draws = TreeRenderer.render(state)

    # Agent panel sidebar
    agent_draws = render_agent_panel_from_layout(state, layout)

    # Minibuffer
    {minibuffer_row, _mbc, _mbw, _mbh} = layout.minibuffer
    minibuffer_draw = Minibuffer.render(state, minibuffer_row, full_viewport.cols)

    # Overlays
    render_overlays_flag = Caps.render_overlays?(state.capabilities)
    {picker_draws, picker_cursor} = PickerUI.render(state, full_viewport)
    whichkey_draws = if render_overlays_flag, do: render_whichkey(state, full_viewport), else: []

    completion_draws =
      case cursor_info do
        {cur_row, cur_col} ->
          CompletionUI.render(
            state.completion,
            %{
              cursor_row: cur_row,
              cursor_col: cur_col,
              viewport_rows: full_viewport.rows,
              viewport_cols: full_viewport.cols
            },
            state.theme
          )

        nil ->
          []
      end

    overlays =
      [
        %Overlay{draws: whichkey_draws},
        %Overlay{draws: completion_draws},
        %Overlay{draws: picker_draws, cursor: picker_cursor}
      ]
      |> Enum.reject(fn %Overlay{draws: d} -> d == [] end)

    # Region definitions
    regions = Regions.define_regions(layout)

    %Chrome{
      modeline_draws: modeline_draws,
      modeline_click_regions: modeline_click_regions,
      minibuffer: [minibuffer_draw],
      separators: separator_draws,
      file_tree: tree_draws,
      agent_panel: agent_draws,
      overlays: overlays,
      regions: regions
    }
  end

  @doc """
  Chrome stage for the agentic (full-screen agent) path.

  Produces minibuffer, overlays, and regions. No modeline, separators,
  file tree, or agent panel sidebar.
  """
  @spec build_chrome_agentic(state(), Layout.t()) :: Chrome.t()
  def build_chrome_agentic(state, layout) do
    full_viewport = state.viewport
    {minibuffer_row, _mbc, _mbw, _mbh} = layout.minibuffer

    minibuffer_draw = Minibuffer.render(state, minibuffer_row, full_viewport.cols)

    render_overlays_flag = Caps.render_overlays?(state.capabilities)
    whichkey_draws = if render_overlays_flag, do: render_whichkey(state, full_viewport), else: []
    {picker_draws, picker_cursor} = PickerUI.render(state, full_viewport)

    overlays =
      [
        %Overlay{draws: whichkey_draws},
        %Overlay{draws: picker_draws, cursor: picker_cursor}
      ]
      |> Enum.reject(fn %Overlay{draws: d} -> d == [] end)

    regions = Regions.define_regions(layout)

    %Chrome{
      minibuffer: [minibuffer_draw],
      overlays: overlays,
      regions: regions
    }
  end

  # ── Stage 6: Compose ──────────────────────────────────────────────────────

  @doc """
  Merges content WindowFrames and Chrome into a `Frame` struct.

  Injects modeline draws into each WindowFrame, resolves cursor
  position and shape, and assembles the final frame.
  """
  @spec compose_windows(
          [WindowFrame.t()],
          Chrome.t(),
          {non_neg_integer(), non_neg_integer()} | nil,
          state()
        ) :: Frame.t()
  def compose_windows(window_frames, chrome, cursor_info, state) do
    layout = Layout.get(state)

    # Inject modeline draws into WindowFrames + apply dimming
    window_frames =
      Enum.map(window_frames, fn wf ->
        inject_modeline(wf, chrome.modeline_draws)
      end)

    # Cursor shape
    cursor_shape =
      if state.picker_ui.picker do
        :beam
      else
        Modeline.cursor_shape(state.mode)
      end

    # Cursor position (picker overrides mode overrides buffer position)
    {minibuffer_row, _, _, _} = layout.minibuffer
    picker_cursor = find_picker_cursor(chrome.overlays)

    cursor =
      case picker_cursor do
        {row, col} -> {row, col}
        nil -> resolve_cursor(state, cursor_info, minibuffer_row)
      end

    # Agent panel input can steal the cursor
    {cursor, cursor_shape} =
      agent_cursor_override_from_layout(state, cursor, cursor_shape, layout)

    %Frame{
      cursor: cursor,
      cursor_shape: cursor_shape,
      windows: window_frames,
      file_tree: chrome.file_tree,
      separators: chrome.separators,
      agent_panel: chrome.agent_panel,
      minibuffer: chrome.minibuffer,
      overlays: chrome.overlays,
      regions: chrome.regions
    }
  end

  @doc """
  Compose stage for the agentic (full-screen agent) path.
  """
  @spec compose_agentic([DisplayList.draw()], Chrome.t(), state()) :: Frame.t()
  def compose_agentic(panel_draws, chrome, state) do
    # Cursor placement
    {cursor_row, cursor_col} = ViewRenderer.cursor_position(state)
    picker_cursor = find_picker_cursor(chrome.overlays)

    cursor_shape =
      if state.picker_ui.picker do
        :beam
      else
        if state.agent.panel.input_focused, do: :beam, else: :block
      end

    cursor =
      case picker_cursor do
        {pr, pc} -> {pr, pc}
        nil -> {cursor_row, cursor_col}
      end

    %Frame{
      cursor: cursor,
      cursor_shape: cursor_shape,
      agentic_view: panel_draws,
      minibuffer: chrome.minibuffer,
      overlays: chrome.overlays,
      regions: chrome.regions
    }
  end

  # ── Stage 7: Emit ─────────────────────────────────────────────────────────

  @doc """
  Converts the frame to protocol command binaries and sends them to
  the Zig port. Also sends title and window background color when they
  change (side-channel writes).
  """
  @spec emit(Frame.t(), state()) :: :ok
  def emit(frame, state) do
    commands = DisplayList.to_commands(frame)
    PortManager.send_commands(state.port_manager, commands)
    send_title(state)
    send_window_bg(state)
    :ok
  end

  # ── Observability ──────────────────────────────────────────────────────────

  @spec timed(atom(), (-> result)) :: result when result: var
  defp timed(stage, fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    elapsed = System.monotonic_time(:microsecond) - start
    Logger.debug("[render:#{stage}] #{elapsed}µs")
    result
  end

  @spec debug_layout(state(), Layout.t()) :: :ok
  defp debug_layout(state, layout) do
    vp = state.viewport
    ts = DateTime.utc_now() |> DateTime.to_string()

    log_lines = [
      "[#{ts}] viewport: #{vp.rows}x#{vp.cols}",
      "  editor_area: #{inspect(layout.editor_area)}",
      "  file_tree: #{inspect(layout.file_tree)}",
      "  minibuffer: #{inspect(layout.minibuffer)}",
      "  modeline: #{inspect(layout.window_layouts |> Map.values() |> Enum.map(& &1.modeline))}",
      ""
    ]

    File.write("/tmp/minga_layout_debug.log", Enum.join(log_lines, "\n"), [:append])
    :ok
  rescue
    _ -> :ok
  end

  # ── Private helpers: emit ──────────────────────────────────────────────────

  @spec send_title(state()) :: :ok
  defp send_title(state) do
    format = Options.get(:title_format) |> to_string()
    title = Title.format(state, format)

    if title != Process.get(:last_title) do
      Process.put(:last_title, title)
      PortManager.send_commands([Protocol.encode_set_title(title)])
    end

    :ok
  end

  @spec send_window_bg(state()) :: :ok
  defp send_window_bg(state) do
    bg = state.theme.editor.bg

    if bg != Process.get(:last_window_bg) do
      Process.put(:last_window_bg, bg)
      PortManager.send_commands([Protocol.encode_set_window_bg(bg)])
    end

    :ok
  end

  # ── Private helpers: scroll ────────────────────────────────────────────────

  @spec window_cursor(Window.t(), boolean()) :: {non_neg_integer(), non_neg_integer()}
  defp window_cursor(window, true), do: BufferServer.cursor(window.buffer)
  defp window_cursor(window, false), do: window.cursor

  @spec scroll_horizontal(Viewport.t(), non_neg_integer(), non_neg_integer(), boolean()) ::
          Viewport.t()
  defp scroll_horizontal(vp, cursor_line, _cursor_col, true = _wrap_on) do
    Viewport.scroll_to_cursor(%{vp | left: 0}, {cursor_line, 0})
  end

  defp scroll_horizontal(vp, cursor_line, cursor_col, false = _wrap_on) do
    Viewport.scroll_to_cursor(vp, {cursor_line, cursor_col})
  end

  @spec wrap_enabled?() :: boolean()
  defp wrap_enabled? do
    Options.get(:wrap)
  catch
    :exit, _ -> false
  end

  @spec wrap_option(atom()) :: boolean()
  defp wrap_option(name) do
    Options.get(name)
  catch
    :exit, _ -> true
  end

  @spec gutter_dimensions(state(), pid(), atom(), non_neg_integer()) ::
          {boolean(), non_neg_integer()}
  defp gutter_dimensions(state, buf, line_number_style, line_count) do
    has_sign_column =
      Map.has_key?(state.git_buffers, buf) or BufferServer.file_path(buf) != nil

    sign_w = if has_sign_column, do: Gutter.sign_column_width(), else: 0

    number_w =
      if line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)

    {has_sign_column, number_w + sign_w}
  end

  @spec cursor_line_text([String.t()], non_neg_integer(), non_neg_integer()) :: String.t()
  defp cursor_line_text(lines, cursor_line, first_line) do
    index = cursor_line - first_line

    if index >= 0 and index < length(lines) do
      Enum.at(lines, index)
    else
      ""
    end
  end

  # ── Private helpers: content ───────────────────────────────────────────────

  @spec build_render_ctx(state(), Window.t(), map()) :: Context.t()
  defp build_render_ctx(state, window, params) do
    %{
      viewport: viewport,
      cursor: cursor,
      lines: lines,
      first_line: first_line,
      preview_matches: preview_matches,
      gutter_w: gutter_w,
      content_w: content_w,
      has_sign_column: has_sign_column,
      is_active: is_active
    } = params

    visual_selection =
      if is_active do
        visual_selection_grapheme_bounds(state, cursor, lines, first_line)
      else
        nil
      end

    search_matches =
      case preview_matches do
        [] -> SearchHighlight.search_matches_for_lines(state, lines, first_line)
        _ -> preview_matches
      end

    %Context{
      viewport: viewport,
      visual_selection: visual_selection,
      search_matches: search_matches,
      gutter_w: gutter_w,
      content_w: content_w,
      confirm_match: if(is_active, do: SearchHighlight.current_confirm_match(state), else: nil),
      highlight: window_highlight(state, window),
      has_sign_column: has_sign_column,
      diagnostic_signs: diagnostic_signs_for_window(state, window),
      git_signs: git_signs_for_window(state, window),
      search_colors: state.theme.search,
      gutter_colors: state.theme.gutter,
      git_colors: state.theme.git
    }
  end

  @typep line_render_opts :: %{
           first_line: non_neg_integer(),
           cursor_line: non_neg_integer(),
           ctx: Context.t(),
           ln_style: atom(),
           gutter_w: non_neg_integer(),
           first_byte_off: non_neg_integer(),
           row_off: non_neg_integer(),
           col_off: non_neg_integer(),
           window: Window.t()
         }

  @spec render_lines_nowrap([String.t()], line_render_opts()) ::
          {[DisplayList.draw()], [DisplayList.draw()], non_neg_integer(), Window.t()}
  defp render_lines_nowrap(lines, opts) do
    %{
      first_line: first_line,
      cursor_line: cursor_line,
      ctx: ctx,
      ln_style: ln_style,
      gutter_w: gutter_w,
      first_byte_off: first_byte_off,
      row_off: row_off,
      col_off: col_off,
      window: window
    } = opts

    sign_w = if ctx.has_sign_column, do: Gutter.sign_column_width(), else: 0
    max_rows = length(lines)

    {gutters, contents_rev, _byte_off, window} =
      lines
      |> Enum.with_index()
      |> Enum.reduce(
        {[], [], first_byte_off, window},
        fn {line_text, screen_row}, {g, c, byte_off, win} ->
          buf_line = first_line + screen_row
          next_byte_off = byte_off + byte_size(line_text) + 1

          if Window.dirty?(win, buf_line) do
            # Dirty line: render fresh, cache the result
            {g_cmds, c_cmds, _rows} =
              BufferLine.render(%{
                line_text: line_text,
                buf_line: buf_line,
                cursor_line: cursor_line,
                byte_offset: byte_off,
                screen_row: screen_row,
                ctx: ctx,
                ln_style: ln_style,
                gutter_w: gutter_w,
                sign_w: sign_w,
                wrap_entry: nil,
                max_rows: max_rows,
                row_offset: row_off,
                col_offset: col_off
              })

            win = Window.cache_line(win, buf_line, g_cmds, c_cmds)
            {g_cmds ++ g, prepend_all(c, c_cmds), next_byte_off, win}
          else
            # Clean line: reuse cached draws, skip rendering
            g_cmds = Map.get(win.cached_gutter, buf_line, [])
            c_cmds = Map.get(win.cached_content, buf_line, [])
            {g_cmds ++ g, prepend_all(c, c_cmds), next_byte_off, win}
          end
        end
      )

    {Enum.reverse(gutters), Enum.reverse(contents_rev), length(lines), window}
  end

  @spec render_lines_wrapped([String.t()], pos_integer(), line_render_opts()) ::
          {[DisplayList.draw()], [DisplayList.draw()], non_neg_integer()}
  defp render_lines_wrapped(lines, max_rows, opts) do
    %{
      first_line: first_line,
      cursor_line: cursor_line,
      ctx: ctx,
      ln_style: ln_style,
      gutter_w: gutter_w,
      first_byte_off: first_byte_off,
      row_off: row_off,
      col_off: col_off
    } = opts

    breakindent = wrap_option(:breakindent)
    linebreak = wrap_option(:linebreak)

    wrap_map =
      WrapMap.compute(lines, ctx.content_w, breakindent: breakindent, linebreak: linebreak)

    sign_w = if ctx.has_sign_column, do: Gutter.sign_column_width(), else: 0

    {gutters, contents, screen_row, _byte_off} =
      lines
      |> Enum.with_index()
      |> Enum.zip(wrap_map)
      |> Enum.reduce_while(
        {[], [], 0, first_byte_off},
        fn {{line_text, line_idx}, visual_rows}, {g, c, sr, byte_off} ->
          {g2, c2, rows_used} =
            BufferLine.render(%{
              line_text: line_text,
              buf_line: first_line + line_idx,
              cursor_line: cursor_line,
              byte_offset: byte_off,
              screen_row: sr,
              ctx: ctx,
              ln_style: ln_style,
              gutter_w: gutter_w,
              sign_w: sign_w,
              wrap_entry: visual_rows,
              max_rows: max_rows,
              row_offset: row_off,
              col_offset: col_off
            })

          sr2 = sr + rows_used
          next_byte_off = byte_off + byte_size(line_text) + 1

          if sr2 >= max_rows do
            {:halt, {g2 ++ g, prepend_all(c, c2), sr2, next_byte_off}}
          else
            {:cont, {g2 ++ g, prepend_all(c, c2), sr2, next_byte_off}}
          end
        end
      )

    {Enum.reverse(gutters), Enum.reverse(contents), screen_row}
  end

  @spec prepend_all([DisplayList.draw()], [DisplayList.draw()]) :: [DisplayList.draw()]
  defp prepend_all(acc, []), do: acc
  defp prepend_all(acc, new_items), do: Enum.reduce(new_items, acc, fn item, a -> [item | a] end)

  @spec window_highlight(state(), Window.t()) :: Minga.Highlight.t() | nil
  defp window_highlight(state, window) do
    hl =
      if window.buffer == state.buffers.active do
        state.highlight.current
      else
        Map.get(state.highlight.cache, window.buffer, Minga.Highlight.from_theme(state.theme))
      end

    if hl.capture_names != [], do: hl, else: nil
  end

  @spec git_signs_for_window(state(), Window.t()) :: %{non_neg_integer() => atom()}
  defp git_signs_for_window(%{git_buffers: git_buffers}, %{buffer: buf}) when is_pid(buf) do
    case Map.get(git_buffers, buf) do
      nil -> %{}
      git_pid -> if Process.alive?(git_pid), do: GitBuffer.signs(git_pid), else: %{}
    end
  end

  @spec diagnostic_signs_for_window(state(), Window.t()) :: %{non_neg_integer() => atom()}
  defp diagnostic_signs_for_window(_state, %{buffer: buf}) when is_pid(buf) do
    case BufferServer.file_path(buf) do
      nil -> %{}
      path -> Diagnostics.severity_by_line(DocumentSync.path_to_uri(path))
    end
  end

  # ── Private helpers: visual selection ──────────────────────────────────────

  @typedoc """
  Represents the bounds of a visual selection for rendering.

  * `nil` — no active selection
  * `{:char, start_pos, end_pos}` — characterwise selection
  * `{:line, start_line, end_line}` — linewise selection
  """
  @type visual_selection ::
          nil
          | {:char, {non_neg_integer(), non_neg_integer()},
             {non_neg_integer(), non_neg_integer()}}
          | {:line, non_neg_integer(), non_neg_integer()}

  @spec visual_selection_bounds(state(), Document.position()) :: visual_selection()
  defp visual_selection_bounds(%{mode: :visual, mode_state: %VisualState{} = ms}, cursor) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type

    case visual_type do
      :char ->
        {start_pos, end_pos} = sort_positions(anchor, cursor)
        {:char, start_pos, end_pos}

      :line ->
        {anchor_line, _} = anchor
        {cursor_line, _} = cursor
        {:line, min(anchor_line, cursor_line), max(anchor_line, cursor_line)}
    end
  end

  defp visual_selection_bounds(_state, _cursor), do: nil

  @spec visual_selection_grapheme_bounds(
          state(),
          Document.position(),
          [String.t()],
          non_neg_integer()
        ) :: visual_selection()
  defp visual_selection_grapheme_bounds(state, cursor, lines, first_line) do
    case visual_selection_bounds(state, cursor) do
      nil ->
        nil

      {:line, _, _} = sel ->
        sel

      {:char, {sl, sc}, {el, ec}} ->
        {
          :char,
          {sl, byte_col_to_display(lines, sl, sc, first_line)},
          {el, byte_col_to_display_end(lines, el, ec, first_line)}
        }
    end
  end

  @spec byte_col_to_display(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp byte_col_to_display(lines, line, byte_col, first_line) do
    line_text = cursor_line_text(lines, line, first_line)
    Unicode.display_col(line_text, byte_col)
  end

  @spec byte_col_to_display_end(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp byte_col_to_display_end(lines, line, byte_col, first_line) do
    line_text = cursor_line_text(lines, line, first_line)
    next_byte = Unicode.next_grapheme_byte_offset(line_text, byte_col)
    Unicode.display_col(line_text, next_byte)
  end

  @spec sort_positions(Document.position(), Document.position()) ::
          {Document.position(), Document.position()}
  defp sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if {l1, c1} <= {l2, c2}, do: {p1, p2}, else: {p2, p1}
  end

  # ── Private helpers: chrome ────────────────────────────────────────────────

  @spec render_window_modeline(state(), WindowScroll.t()) ::
          {[DisplayList.draw()], [Minga.Editor.Modeline.click_region()]}
  defp render_window_modeline(state, %WindowScroll{win_layout: %{modeline: {_, _, _, 0}}}) do
    _ = state
    {[], []}
  end

  defp render_window_modeline(state, scroll) do
    %WindowScroll{
      win_layout: win_layout,
      is_active: is_active,
      snapshot: snapshot,
      cursor_line: cursor_line,
      cursor_col: cursor_col
    } = scroll

    {modeline_row, _mc, modeline_width, _mh} = win_layout.modeline
    {_row_off, col_off, _cw, _ch} = win_layout.content
    file_name = snapshot_display_name(snapshot)
    dirty_marker = if snapshot.dirty, do: " ● ", else: ""
    filetype = Map.get(snapshot, :filetype, :text)
    line_count = snapshot.line_count
    buf_count = length(state.buffers.list)
    buf_index = state.buffers.active_index + 1

    Modeline.render(
      modeline_row,
      modeline_width,
      %{
        mode: if(is_active, do: state.mode, else: :normal),
        mode_state: if(is_active, do: state.mode_state, else: nil),
        file_name: file_name,
        filetype: filetype,
        dirty_marker: dirty_marker,
        cursor_line: cursor_line,
        cursor_col: cursor_col,
        line_count: line_count,
        buf_index: buf_index,
        buf_count: buf_count,
        macro_recording:
          if(is_active, do: MacroRecorder.recording?(state.macro_recorder), else: false),
        agent_status: if(is_active, do: state.agent.status, else: nil),
        agent_theme_colors:
          if(is_active && state.agent.status, do: Theme.agent_theme(state.theme), else: nil)
      },
      state.theme,
      col_off
    )
  end

  @spec render_separators(WindowTree.t(), WindowTree.rect(), pos_integer(), Theme.t()) ::
          [DisplayList.draw()]
  defp render_separators(tree, screen_rect, _total_rows, theme) do
    separators = collect_separators(tree, screen_rect)

    for {col, start_row, end_row} <- separators, row <- start_row..end_row do
      DisplayList.draw(row, col, "│", fg: theme.editor.split_border_fg)
    end
  end

  @typep separator_span :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @spec collect_separators(WindowTree.t(), WindowTree.rect()) :: [separator_span()]
  defp collect_separators({:leaf, _}, _rect), do: []

  defp collect_separators(
         {:split, :vertical, left, right, size},
         {row, col, width, height}
       ) do
    usable = width - 1
    left_width = WindowTree.clamp_size(size, usable)
    right_width = max(usable - left_width, 1)
    separator_col = col + left_width

    [{separator_col, row, row + height - 1}] ++
      collect_separators(left, {row, col, left_width, height}) ++
      collect_separators(right, {row, separator_col + 1, right_width, height})
  end

  defp collect_separators(
         {:split, :horizontal, top, bottom, size},
         {row, col, width, height}
       ) do
    top_height = WindowTree.clamp_size(size, height)
    bottom_height = max(height - top_height, 1)

    collect_separators(top, {row, col, width, top_height}) ++
      collect_separators(bottom, {row + top_height, col, width, bottom_height})
  end

  @spec render_whichkey(state(), Viewport.t()) :: [DisplayList.draw()]
  defp render_whichkey(%{whichkey: %{show: true, node: node}, theme: theme}, viewport)
       when is_map(node) do
    bindings = WhichKey.bindings_from_node(node)
    lines = WhichKey.render_popup(bindings)

    popup_row = max(0, viewport.rows - 3 - length(lines))

    border =
      DisplayList.draw(popup_row, 0, String.duplicate("─", viewport.cols),
        fg: theme.popup.border_fg
      )

    content_draws =
      lines
      |> Enum.with_index(popup_row + 1)
      |> Enum.map(fn {line_text, row} ->
        padded = String.pad_trailing(line_text, viewport.cols)
        DisplayList.draw(row, 0, padded, fg: theme.popup.fg, bg: theme.popup.bg)
      end)

    [border | content_draws]
  end

  defp render_whichkey(_state, _viewport), do: []

  @spec snapshot_display_name(map()) :: String.t()
  defp snapshot_display_name(%{name: name} = snapshot) when is_binary(name) do
    ro = if Map.get(snapshot, :read_only, false), do: " [RO]", else: ""
    name <> ro
  end

  defp snapshot_display_name(snapshot) do
    base =
      case snapshot.file_path do
        nil -> "[scratch]"
        path -> Path.basename(path)
      end

    ro = if Map.get(snapshot, :read_only, false), do: " [RO]", else: ""
    base <> ro
  end

  # ── Private helpers: compose ───────────────────────────────────────────────

  # Merges modeline draws into a WindowFrame, applying grayscale dimming
  # for inactive windows (cursor == nil means inactive).
  @spec inject_modeline(WindowFrame.t(), %{non_neg_integer() => [DisplayList.draw()]}) ::
          WindowFrame.t()
  defp inject_modeline(wf, modeline_map) do
    is_active = wf.cursor != nil
    all_draws = Enum.flat_map(modeline_map, fn {_id, draws} -> draws end)

    dimmed =
      if is_active do
        all_draws
      else
        DisplayList.grayscale_draws(all_draws)
      end

    %{wf | modeline: DisplayList.draws_to_layer(dimmed)}
  end

  @spec resolve_cursor(
          state(),
          {non_neg_integer(), non_neg_integer()} | nil,
          non_neg_integer()
        ) :: {non_neg_integer(), non_neg_integer()}
  defp resolve_cursor(
         %{mode: :search, mode_state: mode_state},
         _cursor_info,
         minibuffer_row
       ) do
    search_col = Unicode.display_width(mode_state.input) + 1
    {minibuffer_row, search_col}
  end

  defp resolve_cursor(
         %{mode: :command, mode_state: mode_state},
         _cursor_info,
         minibuffer_row
       ) do
    cmd_col = Unicode.display_width(mode_state.input) + 1
    {minibuffer_row, cmd_col}
  end

  defp resolve_cursor(
         %{mode: :eval, mode_state: mode_state},
         _cursor_info,
         minibuffer_row
       ) do
    eval_col = Unicode.display_width(mode_state.input) + 6
    {minibuffer_row, eval_col}
  end

  defp resolve_cursor(_state, {row, col}, _minibuffer_row), do: {row, col}
  defp resolve_cursor(_state, nil, _minibuffer_row), do: {0, 0}

  @spec find_picker_cursor([Overlay.t()]) :: {non_neg_integer(), non_neg_integer()} | nil
  defp find_picker_cursor(overlays) do
    Enum.find_value(overlays, fn %Overlay{cursor: c} -> c end)
  end

  @spec agent_cursor_override_from_layout(
          state(),
          {non_neg_integer(), non_neg_integer()},
          atom(),
          Layout.t()
        ) ::
          {{non_neg_integer(), non_neg_integer()}, atom()}
  defp agent_cursor_override_from_layout(
         %{agent: %{panel: %{visible: true, input_focused: true}}} = state,
         _cursor,
         _shape,
         %{agent_panel: {row, col, _w, h}} = _layout
       )
       when h > 0 do
    panel = state.agent.panel
    {cursor_line, cursor_col} = panel.input_cursor
    input_row = row + h - @agent_input_height + 1 + cursor_line
    input_col = col + 2 + cursor_col
    {{input_row, input_col}, :beam}
  end

  defp agent_cursor_override_from_layout(_state, cursor, shape, _layout) do
    {cursor, shape}
  end

  # ── Private helpers: agent panel ───────────────────────────────────────────

  @spec render_agent_panel_from_layout(state(), Layout.t()) :: [DisplayList.draw()]
  defp render_agent_panel_from_layout(_state, %{agent_panel: nil}), do: []

  defp render_agent_panel_from_layout(state, %{agent_panel: rect}) do
    agent = state.agent

    messages =
      if agent.session do
        try do
          Session.messages(agent.session)
        catch
          :exit, _ -> []
        end
      else
        []
      end

    usage =
      if agent.session do
        try do
          Session.usage(agent.session)
        catch
          :exit, _ -> %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}
        end
      else
        %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}
      end

    panel_state = %{
      messages: messages,
      status: agent.status || :idle,
      input_lines: agent.panel.input_lines,
      input_cursor: agent.panel.input_cursor,
      scroll_offset: agent.panel.scroll_offset,
      spinner_frame: agent.panel.spinner_frame,
      usage: usage,
      model_name: agent.panel.model_name,
      thinking_level: agent.panel.thinking_level,
      auto_scroll: agent.panel.auto_scroll,
      display_start_index: agent.panel.display_start_index,
      error_message: agent.error,
      pending_approval: agent.pending_approval,
      mention_completion: agent.panel.mention_completion
    }

    ChatRenderer.render(rect, panel_state, state.theme)
  end
end
