defmodule MingaEditor.RenderPipeline do
  @moduledoc """
  Orchestrator for the rendering pipeline.

  Runs the render stages in sequence, each implemented in its own module or focused owner:

  1. **Layout** — computes screen rectangles via `Layout.put/1`.
  2. **Scroll** — applies pre-fetched per-window viewport and buffer data without process calls.
     See `RenderPipeline.Scroll`.
  3. **Content** — builds display list draws for each window's lines,
     gutter, and tildes. See `RenderPipeline.Content`.
  4. **Agent content** — builds agent chat window content and prompt chrome.
  5. **Chrome** — builds modeline, minibuffer, overlays, separators,
     file tree, agent panel, and region definitions.
     See `RenderPipeline.Chrome`.
  6. **Compose** — merges content + chrome into a `Frame` struct,
     resolves cursor position and shape.
     See `RenderPipeline.Compose`.
  7. **Emit** — converts frame to protocol commands and sends to the
     frontend. See `RenderPipeline.Emit`.

  ## Observability

  Each stage is wrapped in a `:telemetry` span (`[:minga, :render, :stage]`)
  with `%{stage: atom}` metadata. The full pipeline is wrapped in
  `[:minga, :render, :pipeline]`. The `Minga.Telemetry.DevHandler` routes
  durations through `Minga.Log.debug(:render, ...)` when `:log_level_render`
  is set to `:debug`. Attach custom handlers for histograms or alerting.
  """

  alias MingaEditor.FocusTree
  alias MingaEditor.Layout

  alias MingaEditor.RenderPipeline.BufferPrefetch
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.RenderPipeline.Classifier
  alias MingaEditor.RenderPipeline.Compose
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.WindowTree
  alias MingaEditor.Frontend.Emit
  alias MingaEditor.UI.FontRegistry
  alias Minga.Telemetry

  # ── Orchestrator ───────────────────────────────────────────────────────────

  @typedoc "Render pipeline input (narrow contract from EditorState)."
  @type input :: Input.t()

  @doc """
  Runs the full render pipeline for the given Input.

  Returns updated Input with per-window render caches populated. `Renderer.Server` retains renderer-private state and returns a focused receipt for atomic Editor integration.
  """
  @spec run(input()) :: input()
  def run(input) do
    FontRegistry.with_process_registry(input.font_registry, fn ->
      run_stages(input)
    end)
  end

  @spec run_stages(input()) :: input()
  defp run_stages(input) do
    window_count = window_count(input)

    # The render path (`:patch`/`:full`) and rows_rasterized are known only after
    # the Content stage runs, so the pipeline span reports them as stop metadata
    # (#2287). Both labels are observability only; the same transaction and wire
    # encodings are emitted on either path.
    Telemetry.span_with_stop_metadata(
      [:minga, :render, :pipeline],
      %{window_count: window_count},
      fn ->
        # Stage 1: Layout
        input =
          Telemetry.span([:minga, :render, :stage], %{stage: :layout}, fn ->
            compute_layout(input)
          end)

        layout = Layout.get(input)

        output = run_windows_pipeline(input, layout)

        {output,
         %{
           path: output.caches.frame_render_path,
           rows_rasterized: output.caches.frame_rows_rasterized
         }}
      end
    )
  end

  @doc """
  Runs the windows render pipeline stages: scroll, content, agent content,
  chrome, compose, and emit.

  Core rendering logic for buffer editing. Called directly by the
  pipeline dispatcher.
  """
  @spec run_windows_pipeline(input(), Layout.t()) :: input()
  def run_windows_pipeline(input, layout) do
    # Reset the per-frame rasterized-row counter before any window composes (#2287).
    input = Content.reset_rows_rasterized(input)

    # Pre-stage snapshot boundary: Buffer GenServer reads happen before the named render stages.
    {prefetched_scrolls, input} = BufferPrefetch.prefetch_scrolls(input, layout)

    # Classify the frame's render path now that prefetch has resolved per-window
    # invalidation (dirty lines, viewport, line count, epoch resets). Stashed
    # transiently so the pipeline span can tag it; classification labels the
    # frame, it never skips work the row-level content hashing decides
    # independently (#2287).
    input = put_render_path(input, Classifier.classify(input, prefetched_scrolls))

    # Stage 2: Scroll consumes pre-fetched per-window data without process calls.
    {scrolls, input} =
      Telemetry.span([:minga, :render, :stage], %{stage: :scroll}, fn ->
        Scroll.scroll_windows(input, layout, prefetched_scrolls)
      end)

    # Scroll updates per-window viewports; rebuild the tree so overlay hit regions match what chrome renders.
    input = %{input | focus_tree: FocusTree.from_state(input)}

    # Stage 3: Content (skips clean lines, updates window caches)
    {buffer_frames, cursor_info, input} =
      Telemetry.span([:minga, :render, :stage], %{stage: :content}, fn ->
        Content.build_content(input, scrolls)
      end)

    # Stage 4: Agent chat window content (buffer pipeline + prompt chrome)
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

    # Cache the correlated render's click regions through the Traditional input owner.
    input = %{input | shell_state: update_shell_click_regions(input.shell_state, chrome)}

    # Stage 6: Compose
    frame =
      Telemetry.span([:minga, :render, :stage], %{stage: :compose}, fn ->
        Compose.compose_windows(window_frames, chrome, cursor_info, input)
      end)

    # Stage 7: Emit
    Telemetry.span([:minga, :render, :stage], %{stage: :emit}, fn ->
      input = %{input | font_registry: FontRegistry.current_process_registry(input.font_registry)}
      ctx = MingaEditor.Frontend.Emit.Context.from_editor_state(input)

      {updated_caches, updated_font_registry, updated_message_store} =
        Emit.emit(frame, ctx, chrome, input.caches)

      %{
        input
        | caches: updated_caches,
          font_registry: updated_font_registry,
          message_store: updated_message_store
      }
    end)
  end

  @spec update_shell_click_regions(term(), Chrome.t()) :: term()
  defp update_shell_click_regions(%TraditionalState{} = shell_state, %Chrome{} = chrome) do
    TraditionalState.install_click_regions(
      shell_state,
      chrome.modeline_click_regions,
      chrome.tab_bar_click_regions
    )
  end

  defp update_shell_click_regions(shell_state, %Chrome{}), do: shell_state

  # ── Stage 1: Layout ────────────────────────────────────────────────────────

  @doc """
  Computes and caches the layout in editor state.

  Thin wrapper around `Layout.put/1`. Returns the updated state with
  the layout cached for downstream stages.
  """
  @spec compute_layout(input()) :: input()
  def compute_layout(input) do
    Layout.put(input)
  end

  @spec put_render_path(input(), Classifier.path()) :: input()
  defp put_render_path(input, path) do
    %{input | caches: %{input.caches | frame_render_path: path}}
  end

  @spec window_count(input()) :: non_neg_integer()
  defp window_count(%{workspace: %{windows: %{tree: nil}}}), do: 0

  defp window_count(%{workspace: %{windows: %{tree: tree}}}) do
    WindowTree.count(tree)
  end
end
