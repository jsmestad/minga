defmodule Minga.Shell.Traditional do
  @moduledoc """
  Traditional tab-based editor shell.

  The default presentation shell: tab bar, file tree sidebar, split
  windows, modeline, picker, agent panel, and which-key popup. This is
  the UX that ships today.

  Presentation fields live in `Minga.Shell.Traditional.State`. The
  Editor GenServer stores this as `state.shell_state` and dispatches
  presentation events through the `Minga.Shell` behaviour callbacks.

  ## Migration status

  Fields are being migrated from `Minga.Editor.State` into
  `Shell.Traditional.State` in batches. See `BIG_REFACTOR_PLAN.md`
  Phase F for the full plan.

  Batch 1 (current): `nav_flash`, `hover_popup`, `dashboard`, `status_msg`
  """

  @behaviour Minga.Shell

  alias Minga.Shell.Traditional.State, as: ShellState

  @impl true
  @spec init(keyword()) :: Minga.Shell.shell_state()
  def init(_opts) do
    %ShellState{}
  end

  @impl true
  @spec handle_event(ShellState.t(), Minga.Workspace.State.t(), term()) ::
          {ShellState.t(), Minga.Workspace.State.t()}
  def handle_event(shell_state, workspace, _event) do
    {shell_state, workspace}
  end

  @impl true
  @spec handle_gui_action(ShellState.t(), Minga.Workspace.State.t(), term()) ::
          {ShellState.t(), Minga.Workspace.State.t()}
  def handle_gui_action(shell_state, workspace, _action) do
    {shell_state, workspace}
  end

  @impl true
  @spec compute_layout(term()) :: Minga.Editor.Layout.t()
  def compute_layout(editor_state) do
    Minga.Editor.Layout.compute(editor_state)
  end

  @impl true
  @spec build_chrome(term(), Minga.Editor.Layout.t(), map(), term()) ::
          Minga.Editor.RenderPipeline.Chrome.t()
  def build_chrome(editor_state, layout, scrolls, cursor_info) do
    Minga.Editor.RenderPipeline.Chrome.build_chrome(editor_state, layout, scrolls, cursor_info)
  end

  @impl true
  @spec render(term()) :: term()
  def render(%{workspace: %{buffers: %{active: nil}}} = editor_state) do
    Minga.Editor.Renderer.render_dashboard(editor_state)
  end

  def render(editor_state) do
    Minga.Editor.Renderer.render_buffer(editor_state)
  end

  @impl true
  @spec input_handlers(ShellState.t()) :: %{overlay: [module()], surface: [module()]}
  def input_handlers(_shell_state) do
    %{
      overlay: Minga.Input.overlay_handlers(),
      surface: Minga.Input.surface_handlers()
    }
  end
end
