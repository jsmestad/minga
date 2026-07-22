defmodule MingaEditor.RenderPipeline.TestHelpers do
  @moduledoc """
  Shared helpers for render pipeline stage tests.

  Provides `base_state/1` to construct a minimal `EditorState` with
  a single buffer window, suitable for testing individual pipeline stages.
  """

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.RenderModel.Cursor
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.ComposedFrame
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.BufferPrefetch
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.Renderer.BufferChanges
  alias MingaEditor.Renderer.State, as: RendererState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Registry, as: ShellRegistry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Appearance
  alias MingaEditor.State.ExtensionSurfaces
  alias MingaEditor.State.Frontend, as: FrontendState
  alias MingaEditor.State.Interaction
  alias MingaEditor.State.Parser, as: ParserState
  alias MingaEditor.State.{Buffers, Windows}
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.UI.Theme

  @doc """
  Constructs a minimal EditorState for pipeline stage tests.

  ## Options

  * `:rows` — viewport rows (default: 24)
  * `:cols` — viewport cols (default: 80)
  * `:content` — buffer content (default: "line one\\nline two\\nline three")
  """
  @spec base_state(keyword()) :: EditorState.t()
  def base_state(opts \\ []) do
    rows = Keyword.get(opts, :rows, 24)
    cols = Keyword.get(opts, :cols, 80)
    content = Keyword.get(opts, :content, "line one\nline two\nline three")
    filetype = Keyword.get(opts, :filetype, :elixir)

    sidebar_registry = Keyword.get_lazy(opts, :sidebar_registry, &private_sidebar_registry/0)

    {:ok, buf} = BufferProcess.start_link(content: content, filetype: filetype)

    win_id = 1
    window = Window.new(win_id, buf, rows, cols)

    vp = Viewport.new(rows, cols)
    ShellRegistry.seed_builtin()
    shell_entry = ShellRegistry.get(:traditional)

    %EditorState{
      frontend:
        FrontendState.new(
          backend: Keyword.get(opts, :backend, :headless),
          rendering: Keyword.get(opts, :rendering, :enabled),
          port_manager: Keyword.get(opts, :port_manager, self()),
          terminal_viewport: vp,
          capabilities: Keyword.get(opts, :capabilities, %Capabilities{})
        ),
      parser: ParserState.new(Keyword.get(opts, :parser_manager, Minga.Parser.Manager)),
      effect_scheduler: Keyword.get(opts, :effect_scheduler),
      session: Keyword.get(opts, :session, %MingaEditor.State.Session{}),
      extension_surfaces: ExtensionSurfaces.new(sidebar_registry: sidebar_registry),
      workspace: %MingaEditor.Session.State{
        editing: VimState.new(),
        buffers: %Buffers{active: buf, list: [buf], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => window},
          active: win_id,
          next_id: win_id + 1
        }
      },
      interaction: Interaction.new(),
      shell_runtime: Runtime.new(shell_entry, %ShellState{}),
      appearance: Appearance.select_theme(%Appearance{}, Theme.get!(:doom_one))
    }
  end

  @spec private_sidebar_registry() :: Sidebar.table()
  defp private_sidebar_registry do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    {:ok, _pid} = Sidebar.start_link(name: table, notify: false)
    table
  end

  @doc """
  Constructs a GUI-capable EditorState for pipeline stage tests.

  Same as `base_state/1` but with `frontend_type: :native_gui` capabilities.
  """
  @spec gui_state(keyword()) :: EditorState.t()
  def gui_state(opts \\ []) do
    capabilities = %Capabilities{frontend_type: :native_gui, semantic_ui: true}
    base_state(Keyword.put(opts, :capabilities, capabilities))
  end

  @doc """
  Generates content with `n` lines for testing scrolling and large buffers.
  """
  @spec long_content(pos_integer()) :: String.t()
  def long_content(n) do
    Enum.map_join(1..n, "\n", fn i -> "line #{i}: content here for testing" end)
  end

  @doc """
  Updates window tracking fields as if a render pass completed at the given
  viewport top. Ensures gutter_w and buf_version are consistent across frames.
  """
  @spec simulate_scroll(EditorState.t(), non_neg_integer()) :: EditorState.t()
  def simulate_scroll(state, new_top) do
    win_id = state.workspace.windows.active
    window = Map.get(state.workspace.windows.map, win_id)

    viewport = Viewport.put_top(window.viewport, new_top)
    updated_window = Window.observe_render(window, viewport, 1)

    new_map = Map.put(state.workspace.windows.map, win_id, updated_window)

    %{
      state
      | workspace:
          SessionState.set_windows(state.workspace, %{state.workspace.windows | map: new_map})
    }
  end

  @doc """
  Seeds the initial tracking state so the first frame has consistent values.
  Without this, the sentinel values (-1) cause spurious gutter-width mismatches.
  """
  @spec seed_state(EditorState.t(), non_neg_integer()) :: EditorState.t()
  def seed_state(state, viewport_top) do
    simulate_scroll(state, viewport_top)
  end

  @spec run_scroll_stage(EditorState.t(), Layout.t()) ::
          {map(), MingaEditor.RenderPipeline.Input.t()}
  def run_scroll_stage(%EditorState{} = state, layout) do
    renderer = RendererState.new(editor_pid: nil, pipeline: &MingaEditor.RenderPipeline.run/1)
    {_renderer, input} = BufferChanges.prepare(renderer, Intent.from_editor_state(state))
    {prefetched, input} = BufferPrefetch.prefetch_scrolls(input, layout)
    Scroll.scroll_windows(input, layout, prefetched)
  end

  @doc """
  Builds a `ComposedFrame` with a single window's semantic model for testing
  the Emit stage. Runs the real Content stage so the frame carries a genuine
  `RenderModel.Window`.
  """
  @spec build_frame_with_window(EditorState.t(), keyword()) :: ComposedFrame.t()
  def build_frame_with_window(state, _opts) do
    state = MingaEditor.WindowFocus.remember_active_cursor(state)
    state = MingaEditor.RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = run_scroll_stage(state, layout)
    {contents, cursor_info, _state} = Content.build_content(state, scrolls)

    windows = Enum.flat_map(contents, fn content -> content.models end)
    cursor = cursor_info || Cursor.new(0, 0, :block)

    ComposedFrame.new(windows, cursor)
  end

  @doc """
  Runs the render pipeline with Input conversion.

  Builds Input from EditorState, runs the pipeline, and applies the
  output back to EditorState. Drop-in replacement for the old
  `RenderPipeline.run(state)` pattern in tests.
  """
  @spec run_pipeline(EditorState.t()) :: EditorState.t()
  def run_pipeline(state), do: MingaEditor.Renderer.render_buffer(state)
end
