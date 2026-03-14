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

  Each stage logs its name and elapsed time via `Minga.Log.debug(:render, ...)`.
  Set `:log_level_render` to `:debug` to see per-stage timing. At the
  default level (`:info`), these calls are suppressed.
  """

  alias Minga.Agent.View.Renderer, as: ViewRenderer
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Config.Options
  alias Minga.Editor.CompletionUI
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, Frame, Overlay, WindowFrame}
  alias Minga.Editor.FoldMap
  alias Minga.Editor.FoldMap.VisibleLines
  alias Minga.Editor.Layout
  alias Minga.Editor.Modeline
  alias Minga.Editor.PickerUI
  alias Minga.Editor.Renderer.Caps
  alias Minga.Editor.Renderer.Gutter
  alias Minga.Editor.Renderer.Minibuffer
  alias Minga.Editor.Renderer.Regions
  alias Minga.Editor.Renderer.SearchHighlight
  alias Minga.Editor.RenderPipeline.ChromeHelpers
  alias Minga.Editor.RenderPipeline.ComposeHelpers
  alias Minga.Editor.RenderPipeline.ContentHelpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Title
  alias Minga.Editor.TreeRenderer
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Popup.Lifecycle, as: PopupLifecycle
  alias Minga.Port.Manager, as: PortManager
  alias Minga.Port.Protocol

  # Agent input area = 3 rows (border + text + padding); cursor goes on the text row.

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
      :buf_version,
      visible_line_map: nil
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
            buf_version: non_neg_integer(),
            visible_line_map: [Minga.Editor.FoldMap.VisibleLines.line_entry()] | nil
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
              tab_bar: [],
              tab_bar_click_regions: [],
              minibuffer: [],
              separators: [],
              file_tree: [],
              agent_panel: [],
              overlays: [],
              regions: []

    @type t :: %__MODULE__{
            modeline_draws: %{non_neg_integer() => [DisplayList.draw()]},
            modeline_click_regions: [Minga.Editor.Modeline.click_region()],
            tab_bar: [DisplayList.draw()],
            tab_bar_click_regions: [Minga.Editor.TabBarRenderer.click_region()],
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

    dispatch_to_surface(state, layout)
  end

  # All rendering goes through the windows pipeline. Agent chat is rendered
  # as a window content type within the same pipeline (Stage 4b).
  @spec dispatch_to_surface(state(), Layout.t()) :: state()
  defp dispatch_to_surface(state, layout) do
    run_windows_pipeline(state, layout)
  end

  @doc """
  Runs the windows render pipeline stages: scroll, content, chrome,
  compose, and emit.

  Core rendering logic for buffer editing. Called directly by the
  pipeline dispatcher.
  """
  @spec run_windows_pipeline(state(), Layout.t()) :: state()
  def run_windows_pipeline(state, layout) do
    # Stage 3: Scroll (also runs per-window invalidation detection)
    {scrolls, state} = timed(:scroll, fn -> scroll_windows(state, layout) end)

    # Stage 4: Content (skips clean lines, updates window caches)
    {buffer_frames, cursor_info, state} =
      timed(:content, fn -> build_content(state, scrolls) end)

    # Stage 4b: Agent chat window content (rendered separately from buffers)
    agent_chat_frames =
      timed(:agent_content, fn -> build_agent_chat_content(state, layout) end)

    # If the agent chat window set a cursor, use it (overrides buffer cursor).
    cursor_info =
      Enum.reduce(agent_chat_frames, cursor_info, fn wf, acc ->
        if wf.cursor != nil, do: wf.cursor, else: acc
      end)

    window_frames = buffer_frames ++ agent_chat_frames

    # Stage 5: Chrome
    chrome = timed(:chrome, fn -> build_chrome(state, layout, scrolls, cursor_info) end)

    # Cache click regions on state for mouse hit-testing
    state = %{state | modeline_click_regions: chrome.modeline_click_regions}
    state = %{state | tab_bar_click_regions: chrome.tab_bar_click_regions}

    # Stage 6: Compose
    frame =
      timed(:compose, fn -> compose_windows(window_frames, chrome, cursor_info, state) end)

    # Stage 7: Emit
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

      if window == nil or window.buffer == nil or Content.agent_chat?(window.content) do
        # Skip nil windows and agent chat windows (rendered separately)
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
    wrap_on = wrap_enabled?(window.buffer)
    fold_map = window.fold_map
    viewport = Viewport.new(content_height, content_width, 0)

    # When folds are active, scroll in visible-line coordinates.
    # The cursor's buffer line must be mapped to visible-line space
    # so the viewport doesn't try to scroll to a hidden line.
    visible_cursor_line =
      if FoldMap.empty?(fold_map) do
        cursor_line
      else
        FoldMap.buffer_to_visible(fold_map, cursor_line)
      end

    viewport = Viewport.scroll_to_cursor(viewport, {visible_cursor_line, 0}, window.buffer)
    visible_rows = Viewport.content_rows(viewport)

    # Map viewport visible range back to buffer lines
    {vis_first, _vis_last} = Viewport.visible_range(viewport)

    first_line =
      if FoldMap.empty?(fold_map) do
        vis_first
      else
        FoldMap.visible_to_buffer(fold_map, vis_first)
      end

    # Compute which buffer lines are visible at each screen row
    line_count_approx = BufferServer.line_count(window.buffer)

    visible_line_map =
      VisibleLines.compute(fold_map, first_line, visible_rows, line_count_approx)

    # Fetch buffer data: need to cover all visible buffer lines
    {fetch_first, fetch_count} =
      case visible_line_map do
        nil ->
          fetch_rows = if wrap_on, do: visible_rows + div(visible_rows, 2), else: visible_rows
          {first_line, fetch_rows}

        entries ->
          case VisibleLines.buffer_range(entries) do
            nil ->
              {first_line, visible_rows}

            {buf_first, buf_last} ->
              {buf_first, buf_last - buf_first + 1}
          end
      end

    snapshot = BufferServer.render_snapshot(window.buffer, fetch_first, fetch_count)
    lines = snapshot.lines
    line_count = snapshot.line_count

    # Cursor byte → display col
    cursor_line_text = cursor_line_text(lines, cursor_line, first_line)
    cursor_col = Unicode.display_col(cursor_line_text, cursor_byte_col)

    # Gutter dimensions
    line_number_style = BufferServer.get_option(window.buffer, :line_numbers)

    {has_sign_column, gutter_w} =
      gutter_dimensions(state, window.buffer, line_number_style, line_count)

    content_w = max(viewport.cols - gutter_w, 1)

    # Horizontal scroll (disabled when wrapping)
    viewport = scroll_horizontal(viewport, cursor_line, cursor_col, wrap_on, window.buffer)

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
      buf_version: snapshot.version,
      visible_line_map: visible_line_map
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
          {[WindowFrame.t()], Cursor.t() | nil, state()}
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
          {WindowFrame.t(), Cursor.t() | nil, state()}
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
      ContentHelpers.build_render_ctx(state, window, %{
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
    ctx_fp = ContentHelpers.context_fingerprint(render_ctx, is_active)
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
      window: window,
      buffer: window.buffer,
      visible_line_map: scroll.visible_line_map,
      fold_map: window.fold_map
    }

    {gutter_draws, line_draws, rows_used, window} =
      if wrap_on do
        # Wrapping and folding are mutually exclusive for now.
        # Strip fold-specific keys so the type matches line_render_opts.
        wrap_opts = Map.drop(line_opts, [:visible_line_map, :fold_map])
        {g, l, r} = ContentHelpers.render_lines_wrapped(lines, visible_rows, wrap_opts)
        {g, l, r, window}
      else
        ContentHelpers.render_lines_nowrap(lines, line_opts)
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
    buf_cursor =
      if is_active do
        # When folds are active, viewport.top is in visible-line coordinates.
        # Convert cursor_line from buffer to visible for correct screen position.
        visible_cursor =
          if FoldMap.empty?(window.fold_map) do
            cursor_line
          else
            FoldMap.buffer_to_visible(window.fold_map, cursor_line)
          end

        cr = visible_cursor - viewport.top + row_off
        cc = gutter_w + cursor_col - viewport.left + col_off
        Cursor.new(cr, cc, Modeline.cursor_shape(state.vim.mode))
      else
        nil
      end

    win_frame = %WindowFrame{
      rect: {0, 0, content_width, content_height},
      gutter: DisplayList.draws_to_layer(gutter_draws),
      lines: DisplayList.draws_to_layer(line_draws),
      tilde_lines: DisplayList.draws_to_layer(tilde_draws),
      modeline: %{},
      cursor: buf_cursor
    }

    cursor_info = buf_cursor

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

  # ── Stage 4b: Agent chat content ───────────────────────────────────────────

  @doc """
  Builds display list draws for agent chat windows.

  Finds windows with `{:agent_chat, _}` content in the layout, renders
  the agent chat content into their rects, and returns `WindowFrame`
  structs. Buffer windows are skipped (handled by `build_content/2`).

  Returns an empty list if no agent chat windows exist.
  """
  @spec build_agent_chat_content(state(), Layout.t()) :: [WindowFrame.t()]
  def build_agent_chat_content(state, layout) do
    layout.window_layouts
    |> Enum.flat_map(fn {win_id, win_layout} ->
      window = Map.get(state.windows.map, win_id)

      case window do
        %Window{content: {:agent_chat, _buf}} ->
          [render_agent_chat_window(state, window, win_layout)]

        _ ->
          []
      end
    end)
  end

  # Minimum sidebar width (cols). Below this threshold, the agent chat
  # renders in compact mode (chat+input only, no sidebar).
  @sidebar_min_cols 20

  @spec render_agent_chat_window(state(), Window.t(), Layout.window_layout()) :: WindowFrame.t()
  defp render_agent_chat_window(state, _window, win_layout) do
    {_row_off, _col_off, width, height} = win_layout.content

    # Compute the sidebar split from the content rect and chat_width_pct.
    # This is an agent-specific layout concern, so it lives here in the
    # agent content stage (4b), not in the generic Layout module.
    sidebar = compute_agent_sidebar(state, win_layout.content)

    {draws, chat_rect} =
      case sidebar do
        {chat_rect, sidebar_rect} ->
          {ViewRenderer.render_with_sidebar(state, chat_rect, sidebar_rect), chat_rect}

        nil ->
          {ViewRenderer.render_in_rect(state, win_layout.content), win_layout.content}
      end

    # Cursor position within the chat input area.
    agent_cursor =
      case ViewRenderer.cursor_position_in_rect(state, chat_rect) do
        {row, col} -> Cursor.new(row, col, :beam)
        nil -> nil
      end

    # Use {0, 0} for the rect origin. The agent renderer's draws already
    # use absolute screen coordinates (they include row_off/col_off from
    # the rect passed to render_with_sidebar / render_in_rect). Buffer
    # windows also use {0, 0} for the same reason. DisplayList.to_commands
    # offsets draws by the frame rect origin, so using {0, 0} avoids
    # double-offsetting.
    %WindowFrame{
      rect: {0, 0, width, height},
      gutter: %{},
      lines: DisplayList.draws_to_layer(draws),
      tilde_lines: %{},
      modeline: %{},
      cursor: agent_cursor
    }
  end

  # Splits a content rect into chat (left) and sidebar (right) rects
  # if there's enough horizontal space. Returns {chat_rect, sidebar_rect}
  # or nil if the sidebar doesn't fit.
  @spec compute_agent_sidebar(state(), Layout.rect()) :: {Layout.rect(), Layout.rect()} | nil
  defp compute_agent_sidebar(state, {row, col, width, height}) do
    chat_width_pct = AgentAccess.agentic(state).chat_width_pct
    chat_width = max(div(width * chat_width_pct, 100), 20)
    sidebar_width = width - chat_width - 1

    if sidebar_width >= @sidebar_min_cols do
      sidebar_col = col + chat_width + 1
      {{row, col, chat_width, height}, {row, sidebar_col, sidebar_width, height}}
    else
      nil
    end
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

    # Modeline per buffer window
    {modeline_draws, modeline_click_regions} =
      Enum.reduce(scrolls, {%{}, []}, fn {win_id, scroll}, {draws_acc, regions_acc} ->
        {draws, regions} = ChromeHelpers.render_window_modeline(state, scroll)
        {Map.put(draws_acc, win_id, draws), regions ++ regions_acc}
      end)

    # Modeline per agent chat window (skipped in scrolls, rendered here)
    {modeline_draws, modeline_click_regions} =
      layout.window_layouts
      |> Enum.reduce({modeline_draws, modeline_click_regions}, fn {win_id, win_layout},
                                                                  {draws_acc, regions_acc} ->
        window = Map.get(state.windows.map, win_id)

        if window != nil and Content.agent_chat?(window.content) do
          {draws, regions} = ChromeHelpers.render_agent_modeline(state, win_layout)
          {Map.put(draws_acc, win_id, draws), regions ++ regions_acc}
        else
          {draws_acc, regions_acc}
        end
      end)

    # Separators (vertical split borders)
    separator_draws =
      if EditorState.split?(state) do
        ChromeHelpers.render_separators(
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
    agent_draws = ChromeHelpers.render_agent_panel_from_layout(state, layout)

    # Minibuffer
    {minibuffer_row, _mbc, _mbw, _mbh} = layout.minibuffer
    minibuffer_draw = Minibuffer.render(state, minibuffer_row, full_viewport.cols)

    # Overlays
    render_overlays_flag = Caps.render_overlays?(state.capabilities)
    {picker_draws, picker_cursor} = PickerUI.render(state, full_viewport)

    whichkey_draws =
      if render_overlays_flag, do: ChromeHelpers.render_whichkey(state, full_viewport), else: []

    completion_draws =
      case cursor_info do
        %Cursor{row: cur_row, col: cur_col} ->
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

    # Float popup overlays (from the popup system)
    float_overlays = PopupLifecycle.render_float_overlays(state)

    overlays =
      (float_overlays ++
         [
           %Overlay{draws: whichkey_draws},
           %Overlay{draws: completion_draws},
           %Overlay{draws: picker_draws, cursor: picker_cursor}
         ])
      |> Enum.reject(fn %Overlay{draws: d} -> d == [] end)

    # Tab bar
    {tab_bar_draws, tab_bar_regions} = ChromeHelpers.render_tab_bar(state, layout)

    # Region definitions
    regions = Regions.define_regions(layout)

    %Chrome{
      modeline_draws: modeline_draws,
      modeline_click_regions: modeline_click_regions,
      tab_bar: tab_bar_draws,
      tab_bar_click_regions: tab_bar_regions,
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



  # ── Stage 6: Compose ──────────────────────────────────────────────────────

  @doc \"""
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
        ComposeHelpers.inject_modeline(wf, chrome.modeline_draws)
      end)

    # Resolve cursor from window frames, overlays, and fallbacks.
    # Priority (highest first): picker overlay → agent panel → active WindowFrame → fallback.
    {minibuffer_row, _, _, _} = layout.minibuffer
    picker_cursor = ComposeHelpers.find_picker_cursor(chrome.overlays)

    # Build the final cursor. Priority (highest first):
    # picker overlay → minibuffer (command/search/eval) → agent panel →
    # active WindowFrame → fallback.
    #
    # Minibuffer modes must override the window frame cursor because the
    # window frame still carries the buffer cursor from before entering
    # command/search/eval mode.
    active_wf_cursor = Enum.find_value(window_frames, fn wf -> wf.cursor end)
    minibuffer_result = ComposeHelpers.resolve_cursor(state, cursor_info, minibuffer_row)
    minibuffer_mode? = state.vim.mode in [:command, :search, :eval]

    cursor =
      resolve_frame_cursor(
        picker_cursor,
        if(minibuffer_mode?, do: minibuffer_result),
        ComposeHelpers.agent_cursor_from_layout(state, layout),
        active_wf_cursor,
        minibuffer_result,
        Modeline.cursor_shape(state.vim.mode)
      )

    %Frame{
      cursor: cursor,
      tab_bar: chrome.tab_bar,
      windows: window_frames,
      file_tree: chrome.file_tree,
      separators: chrome.separators,
      agent_panel: chrome.agent_panel,
      minibuffer: chrome.minibuffer,
      overlays: chrome.overlays,
      regions: chrome.regions
    }
  end

  # Resolves the final frame cursor from the priority chain.
  # Each argument is checked in order; the first non-nil wins.
  # Priority: picker → minibuffer → agent panel → window frame → fallback.
  @spec resolve_frame_cursor(
          {non_neg_integer(), non_neg_integer()} | nil,
          {non_neg_integer(), non_neg_integer()} | nil,
          Cursor.t() | nil,
          Cursor.t() | nil,
          {non_neg_integer(), non_neg_integer()},
          Cursor.shape()
        ) :: Cursor.t()
  defp resolve_frame_cursor({row, col}, _, _, _, _, _), do: Cursor.new(row, col, :beam)
  defp resolve_frame_cursor(nil, {row, col}, _, _, _, _), do: Cursor.new(row, col, :beam)
  defp resolve_frame_cursor(nil, nil, %Cursor{} = c, _, _, _), do: c
  defp resolve_frame_cursor(nil, nil, nil, %Cursor{} = c, _, _), do: c

  defp resolve_frame_cursor(nil, nil, nil, nil, {row, col}, shape) do
    Cursor.new(row, col, shape)
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
    Minga.Log.debug(:render, "[render:#{stage}] #{elapsed}µs")
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

    # Prepend [!] when any agent tab needs attention
    title =
      if state.tab_bar && TabBar.any_attention?(state.tab_bar) do
        "[!] " <> title
      else
        title
      end

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

  @spec scroll_horizontal(Viewport.t(), non_neg_integer(), non_neg_integer(), boolean(), pid()) ::
          Viewport.t()
  defp scroll_horizontal(vp, cursor_line, _cursor_col, true = _wrap_on, buf) do
    Viewport.scroll_to_cursor(%{vp | left: 0}, {cursor_line, 0}, buf)
  end

  defp scroll_horizontal(vp, cursor_line, cursor_col, false = _wrap_on, buf) do
    Viewport.scroll_to_cursor(vp, {cursor_line, cursor_col}, buf)
  end

  @spec wrap_enabled?(pid()) :: boolean()
  defp wrap_enabled?(buf) do
    BufferServer.get_option(buf, :wrap)
  catch
    :exit, _ -> false
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
end
