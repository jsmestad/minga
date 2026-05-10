defmodule MingaEditor.RenderPipeline do
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

  Each stage is wrapped in a `:telemetry` span (`[:minga, :render, :stage]`)
  with `%{stage: atom}` metadata. The full pipeline is wrapped in
  `[:minga, :render, :pipeline]`. The `Minga.Telemetry.DevHandler` routes
  durations through `Minga.Log.debug(:render, ...)` when `:log_level_render`
  is set to `:debug`. Attach custom handlers for histograms or alerting.
  """

  alias MingaEditor.FocusTree
  alias MingaEditor.Layout

  alias MingaEditor.RenderPipeline.Compose
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.WindowTree
  alias MingaEditor.Frontend.Emit
  alias Minga.Telemetry

  # The Invalidation type lives in its own module
  # (MingaEditor.RenderPipeline.Invalidation) carrying first-class
  # per-window and per-region dirty info. Stage 1's producer always
  # returns full_redraw: true today; the consumers' dirty-bit gating
  # is the Phase 1/2 follow-up work in #1431.

  # ── Orchestrator ───────────────────────────────────────────────────────────

  @typedoc "Render pipeline input (narrow contract from EditorState)."
  @type input :: Input.t()

  @doc """
  Runs the full render pipeline for the given Input.

  Returns updated Input with per-window render caches populated.
  The caller applies mutations back to EditorState via
  `EditorState.apply_render_output/2`.
  """
  @spec run(input()) :: input()
  def run(input) do
    window_count = window_count(input)

    Telemetry.span([:minga, :render, :pipeline], %{window_count: window_count}, fn ->
      # Pre-pipeline: sync cursor
      input = Input.sync_active_window_cursor(input)

      # Stage 1: Invalidation (global triggers: visual selection, search, theme)
      input =
        Telemetry.span([:minga, :render, :stage], %{stage: :invalidation}, fn ->
          invalidate(input)
        end)

      # Stage 2: Layout
      input =
        Telemetry.span([:minga, :render, :stage], %{stage: :layout}, fn ->
          compute_layout(input)
        end)

      layout = Layout.get(input)

      run_windows_pipeline(input, layout)
    end)
  end

  @doc """
  Runs the windows render pipeline stages: scroll, content, chrome,
  compose, and emit.

  Core rendering logic for buffer editing. Called directly by the
  pipeline dispatcher.
  """
  @spec run_windows_pipeline(input(), Layout.t()) :: input()
  def run_windows_pipeline(input, layout) do
    # Stage 3: Scroll (also runs per-window invalidation detection)
    {scrolls, input} =
      Telemetry.span([:minga, :render, :stage], %{stage: :scroll}, fn ->
        Scroll.scroll_windows(input, layout)
      end)

    # Scroll updates per-window viewports; rebuild the tree so overlay hit regions match what chrome renders.
    input = %{input | focus_tree: FocusTree.from_state(input)}

    # Stage 4: Content (skips clean lines, updates window caches)
    {buffer_frames, cursor_info, input} =
      Telemetry.span([:minga, :render, :stage], %{stage: :content}, fn ->
        Content.build_content(input, scrolls)
      end)

    # Stage 4b: Agent chat window content (buffer pipeline + prompt chrome)
    {agent_chat_frames, agent_cursor, input} =
      Telemetry.span([:minga, :render, :stage], %{stage: :agent_content}, fn ->
        Content.build_agent_chat_content(input, layout)
      end)

    # If the agent chat window set a cursor, use it (overrides buffer cursor).
    cursor_info = if agent_cursor != nil, do: agent_cursor, else: cursor_info

    window_frames = buffer_frames ++ agent_chat_frames

    # Stage 5: Chrome (skip rebuild when inputs unchanged)
    chrome_fp = Input.chrome_fingerprint(input, scrolls)
    prev_chrome_fp = input.caches.chrome_prev_fingerprint
    prev_chrome = input.caches.chrome_prev_result

    chrome =
      if chrome_fp == prev_chrome_fp and prev_chrome != nil do
        Minga.Log.debug(:render, "[render:chrome] skipped (fingerprint unchanged)")
        prev_chrome
      else
        Telemetry.span([:minga, :render, :stage], %{stage: :chrome}, fn ->
          input.shell.build_chrome(input, layout, scrolls, cursor_info)
        end)
      end

    input = %{
      input
      | caches: %{input.caches | chrome_prev_fingerprint: chrome_fp, chrome_prev_result: chrome}
    }

    # Cache click regions on input for mouse hit-testing write-back
    ss = input.shell_state

    input = %{
      input
      | shell_state: %{
          ss
          | modeline_click_regions: chrome.modeline_click_regions,
            tab_bar_click_regions: chrome.tab_bar_click_regions
        }
    }

    # Stage 6: Compose
    frame =
      Telemetry.span([:minga, :render, :stage], %{stage: :compose}, fn ->
        Compose.compose_windows(window_frames, chrome, cursor_info, input)
      end)

    # Stage 7: Emit
    Telemetry.span([:minga, :render, :stage], %{stage: :emit}, fn ->
      ctx = MingaEditor.Frontend.Emit.Context.from_editor_state(input)
      updated_caches = Emit.emit(frame, ctx, chrome, input.caches)
      %{input | caches: updated_caches}
    end)
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
  @spec invalidate(input()) :: input()
  def invalidate(input) do
    input
  end

  # ── Stage 2: Layout ────────────────────────────────────────────────────────

  @doc """
  Computes and caches the layout in editor state.

  Thin wrapper around `Layout.put/1`. Returns the updated state with
  the layout cached for downstream stages.
  """
  @spec compute_layout(input()) :: input()
  def compute_layout(input) do
    Layout.put(input)
  end

  @spec window_count(input()) :: non_neg_integer()
  defp window_count(%{workspace: %{windows: %{tree: nil}}}), do: 0

  defp window_count(%{workspace: %{windows: %{tree: tree}}}) do
    WindowTree.count(tree)
  end
end
