defmodule MingaEditor.Renderer do
  @moduledoc """
  Buffer and UI rendering for the editor.

  This module is the public API for rendering. It delegates to
  `RenderPipeline`, which decomposes rendering into seven named stages:
  Invalidation, Layout, Scroll, Content, Chrome, Compose, Emit.

  `render/1` returns the updated editor state with per-window render
  caches populated. Callers must use the returned state so that
  dirty-line tracking works across frames.

  Sub-modules handle focused rendering concerns:

  * `Renderer.Gutter`          — line number rendering
  * `Renderer.Composition`     — line content styling (conceals, virtual text, invisible chars)
  * `Renderer.SearchHighlight` — search/substitute highlight overlays
  * `Renderer.Caps`            — capability-aware rendering helpers
  * `Renderer.Regions`         — region definition commands
  """

  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.Server, as: RendererServer
  alias MingaEditor.State, as: EditorState

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @type visual_selection :: MingaEditor.Renderer.Context.visual_selection()

  @doc """
  Renders the current editor state and returns updated state.

  The returned state contains per-window render caches that enable
  dirty-line tracking on subsequent frames. Callers must use the
  returned state for the optimization to work.
  """
  @spec render(state()) :: state()
  def render(%EditorState{rendering: :disabled} = state), do: state

  def render(state) do
    state = EditorState.ensure_shell_available(state)
    EditorState.active_shell_module(state).render(state)
  end

  @doc """
  Pushes a render snapshot to the Renderer.Server for async rendering.
  Returns the editor state unchanged; the Renderer's `{:render_done, ...}`
  writeback will update caches and layout later.

  Falls back to synchronous render when no Renderer.Server is available
  (headless backend, or Editor started outside the supervisor in tests),
  or when the active shell cannot use the async RenderPipeline path.
  """
  @spec render_or_async(state()) :: state()
  def render_or_async(%EditorState{rendering: :disabled} = state), do: state
  def render_or_async(%{backend: :headless} = state), do: render(state)

  def render_or_async(%{renderer: pid} = state) when is_pid(pid) do
    state = EditorState.ensure_shell_available(state)

    if async_render?(state) do
      snapshot = Input.from_editor_state(state)
      seq = System.unique_integer([:positive, :monotonic])
      RendererServer.cast_snapshot(pid, snapshot, seq)
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
  def reset_connection(%EditorState{rendering: :disabled} = state), do: state
  def reset_connection(%{backend: :headless} = state), do: render(state)

  def reset_connection(%{renderer: pid} = state) when is_pid(pid) do
    state = EditorState.ensure_shell_available(state)

    if async_render?(state) do
      snapshot = Input.from_editor_state(state)
      seq = System.unique_integer([:positive, :monotonic])
      :ok = RendererServer.reset_connection(pid, snapshot, seq)
      state
    else
      render(state)
    end
  end

  def reset_connection(state), do: render(state)

  @spec async_render?(state()) :: boolean()
  defp async_render?(state), do: EditorState.active_shell_module(state).async_render?(state)

  @doc """
  Runs the full render pipeline (content, chrome, compose, emit).

  Called by Shell.Traditional.render for normal buffer rendering.
  """
  @spec render_buffer(state()) :: state()
  def render_buffer(state) do
    input = Input.from_editor_state(state)
    output = RenderPipeline.run(input)
    EditorState.apply_render_output(state, output)
  rescue
    e ->
      msg = Exception.message(e)
      trace = Exception.format_stacktrace(__STACKTRACE__) |> String.slice(0, 500)
      Minga.Log.warning(:render, "Render pipeline crashed: #{msg}\n#{trace}")
      state
  end
end
