defmodule MingaEditor.Renderer do
  @moduledoc """
  Buffer and UI rendering for the editor.

  This module is the public API for rendering. It delegates to
  `RenderPipeline`, which decomposes rendering into seven named stages:
  Invalidation, Layout, Scroll, Content, Chrome, Compose, Emit.

  Every rendering path uses `Renderer.Server` as the persistent owner of window caches, resident content, and frontend acknowledgement state. The Editor submits typed, cache-free intents and applies only focused editor-owned receipts.

  Sub-modules handle focused rendering concerns:

  * `Renderer.Gutter`          — line number rendering
  * `Renderer.Composition`     — line content styling (conceals, virtual text, invisible chars)
  * `Renderer.SearchHighlight` — search/substitute highlight overlays
  * `Renderer.Caps`            — capability-aware rendering helpers
  * `Renderer.Regions`         — region definition commands
  """

  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.Server, as: RendererServer
  alias MingaEditor.State, as: EditorState

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @type visual_selection :: MingaEditor.Renderer.Context.visual_selection()

  @doc """
  Renders the current editor state and returns updated state.

  Persistent render state remains in `Renderer.Server`. The returned editor state contains only editor-owned observations from the focused render receipt.
  """
  @spec render(state()) :: state()
  def render(%EditorState{frontend: %{rendering: :disabled}} = state), do: state

  def render(state) do
    state = MingaEditor.Shell.Workflow.ensure_available(state)
    MingaEditor.Shell.Runtime.module(state.shell_runtime).render(state)
  end

  @doc """
  Pushes a typed, cache-free render intent to `Renderer.Server` for asynchronous rendering. The focused receipt later updates only editor-owned layout, focus, and interaction observations.

  Headless and other synchronous paths use a persistent unnamed `Renderer.Server`, so they preserve the same renderer-owned state boundary without copying caches into the Editor.
  """
  @spec render_or_async(state()) :: state()
  def render_or_async(%EditorState{frontend: %{rendering: :disabled}} = state), do: state
  def render_or_async(%EditorState{frontend: %{backend: :headless}} = state), do: render(state)

  def render_or_async(%EditorState{render: %{renderer: pid}} = state) when is_pid(pid) do
    state = MingaEditor.Shell.Workflow.ensure_available(state)

    if async_render?(state) do
      {correlation, revision} =
        MingaEditor.State.RenderCorrelation.submit(state.render.render_correlation)

      state = %{
        state
        | render: MingaEditor.State.Render.accept_correlation(state.render, correlation)
      }

      intent = Intent.from_editor_state(state, revision)
      seq = System.unique_integer([:positive, :monotonic])
      RendererServer.cast_snapshot(pid, intent, seq)
      state
    else
      render(state)
    end
  end

  def render_or_async(state), do: render(state)

  @doc """
  Renders the first frame for a newly ready frontend connection.

  Async renderers synchronously abandon credit owned by the replaced connection
  before preparing a base-zero keyframe in a fresh recovery generation. Other
  rendering paths keep their normal synchronous behavior.
  """
  @spec reset_connection(state()) :: state()
  def reset_connection(%EditorState{frontend: %{rendering: :disabled}} = state), do: state

  def reset_connection(%EditorState{frontend: %{backend: :headless}} = state) do
    {state, renderer} = ensure_synchronous_renderer(state)

    {correlation, revision} =
      MingaEditor.State.RenderCorrelation.submit(state.render.render_correlation)

    state = %{
      state
      | render: MingaEditor.State.Render.accept_correlation(state.render, correlation)
    }

    intent = Intent.from_editor_state(state, revision)
    seq = System.unique_integer([:positive, :monotonic])

    case RendererServer.reset_sync(renderer, intent, seq) do
      {:ok, receipt} -> EditorState.integrate_synchronous_renderer_receipt(state, receipt)
      {:error, error} -> log_synchronous_error(state, seq, error)
    end
  end

  def reset_connection(%EditorState{render: %{renderer: pid}} = state) when is_pid(pid) do
    state = MingaEditor.Shell.Workflow.ensure_available(state)

    if async_render?(state) do
      {correlation, revision} =
        MingaEditor.State.RenderCorrelation.submit(state.render.render_correlation)

      state = %{
        state
        | render: MingaEditor.State.Render.accept_correlation(state.render, correlation)
      }

      intent = Intent.from_editor_state(state, revision)
      seq = System.unique_integer([:positive, :monotonic])
      :ok = RendererServer.reset_connection(pid, intent, seq)
      state
    else
      render(state)
    end
  end

  def reset_connection(state), do: render(state)

  @spec async_render?(state()) :: boolean()
  defp async_render?(state),
    do: MingaEditor.Shell.Runtime.module(state.shell_runtime).async_render?(state)

  @doc """
  Runs the full render pipeline (content, chrome, compose, emit).

  Called by Shell.Traditional.render for normal buffer rendering.
  """
  @spec render_buffer(state()) :: state()
  def render_buffer(state) do
    {state, renderer} = ensure_synchronous_renderer(state)
    seq = System.unique_integer([:positive, :monotonic])
    intent = Intent.from_editor_state(state)

    case RendererServer.render_sync(renderer, intent, seq) do
      {:ok, receipt} -> EditorState.integrate_synchronous_renderer_receipt(state, receipt)
      {:error, error} -> log_synchronous_error(state, seq, error)
    end
  end

  @spec ensure_synchronous_renderer(state()) :: {state(), pid()}
  defp ensure_synchronous_renderer(%EditorState{render: %{renderer: renderer}} = state)
       when is_pid(renderer),
       do: {state, renderer}

  defp ensure_synchronous_renderer(%EditorState{} = state) do
    {:ok, renderer} =
      RendererServer.start_link(name: nil, editor_pid: nil, require_ack?: false)

    {%{state | render: MingaEditor.State.Render.connect_renderer(state.render, renderer)},
     renderer}
  end

  @spec log_synchronous_error(state(), non_neg_integer(), Exception.t()) :: state()
  defp log_synchronous_error(state, seq, error) do
    Minga.Log.warning(
      :render,
      "Synchronous renderer frame #{seq} dropped: #{Exception.message(error)}"
    )

    state
  end
end
