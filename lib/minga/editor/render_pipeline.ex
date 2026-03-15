defmodule Minga.Editor.RenderPipeline do
  @moduledoc """
  Orchestrator for the rendering pipeline.

  Runs seven named stages in sequence, each implemented in its own module:

  1. **Invalidation** — decides what needs redrawing (currently a stub).
  2. **Layout** — computes screen rectangles via `Layout.put/1`.
  3. **Scroll** — per-window viewport adjustment + buffer data fetch.
     See `RenderPipeline.Scroll`.
  4. **Content** — builds display list draws for each window's lines,
     gutter, and tildes. See `RenderPipeline.Content`.
  5. **Chrome** — builds modeline, minibuffer, overlays, separators,
     file tree, agent panel, and region definitions.
     See `RenderPipeline.Chrome`.
  6. **Compose** — merges content + chrome into a `Frame` struct,
     resolves cursor position and shape.
     See `RenderPipeline.Compose`.
  7. **Emit** — converts frame to protocol commands and sends to the
     Zig port. See `RenderPipeline.Emit`.

  ## Observability

  Each stage logs its name and elapsed time via `Minga.Log.debug(:render, ...)`.
  Set `:log_level_render` to `:debug` to see per-stage timing. At the
  default level (`:info`), these calls are suppressed.
  """

  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline.Chrome
  alias Minga.Editor.RenderPipeline.Compose
  alias Minga.Editor.RenderPipeline.Content
  alias Minga.Editor.RenderPipeline.Emit
  alias Minga.Editor.RenderPipeline.Scroll
  alias Minga.Editor.State, as: EditorState

  # ── Invalidation stub ──────────────────────────────────────────────────────

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
    {scrolls, state} = timed(:scroll, fn -> Scroll.scroll_windows(state, layout) end)

    # Stage 4: Content (skips clean lines, updates window caches)
    {buffer_frames, cursor_info, state} =
      timed(:content, fn -> Content.build_content(state, scrolls) end)

    # Stage 4b: Agent chat window content (buffer pipeline + prompt chrome)
    {agent_chat_frames, agent_cursor, state} =
      timed(:agent_content, fn -> Content.build_agent_chat_content(state, layout) end)

    # If the agent chat window set a cursor, use it (overrides buffer cursor).
    cursor_info = if agent_cursor != nil, do: agent_cursor, else: cursor_info

    window_frames = buffer_frames ++ agent_chat_frames

    # Stage 5: Chrome
    chrome =
      timed(:chrome, fn -> Chrome.build_chrome(state, layout, scrolls, cursor_info) end)

    # Cache click regions on state for mouse hit-testing
    state = %{state | modeline_click_regions: chrome.modeline_click_regions}
    state = %{state | tab_bar_click_regions: chrome.tab_bar_click_regions}

    # Stage 6: Compose
    frame =
      timed(:compose, fn ->
        Compose.compose_windows(window_frames, chrome, cursor_info, state)
      end)

    # Stage 7: Emit
    timed(:emit, fn -> Emit.emit(frame, state) end)

    state
  end

  # ── Stage 1: Invalidation ─────────────────────────────────────────────────

  @doc """
  Invalidation stage (Stage 1). Currently a pass-through.

  All invalidation is handled by two mechanisms downstream:

  * **Structural invalidation** in `Scroll.scroll_windows/2`: viewport scroll,
    gutter width, line count, buffer version changes detected via
    `Window.detect_invalidation/5`.

  * **Context invalidation** in `Content.build_content/2`: visual
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
end
