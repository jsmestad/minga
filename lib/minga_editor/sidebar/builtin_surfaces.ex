defmodule MingaEditor.Sidebar.BuiltinSurfaces do
  @moduledoc """
  Registers built-in editor features as sidebar surfaces.

  The feature modules still own their domain state and content payloads. This module projects that state into the shared `MingaEditor.Extension.Sidebar` registry so GUI and TUI chrome have one source of truth for sidebar identity, visibility, focus, width, and action routing.
  """

  alias MingaEditor.Commands
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Layout
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.Session.State
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @builtin_source :builtin
  @observatory_id "observatory"

  @doc "Registers built-in sidebar surfaces that do not have their own feature adapter."
  @spec register_contributions(Sidebar.table()) :: :ok | {:error, term()}
  def register_contributions(sidebar_registry \\ Sidebar.default_table()),
    do: sync_observatory(false, sidebar_registry)

  @doc "Synchronizes BEAM Observatory sidebar surface metadata from shell visibility state."
  @spec sync_observatory(boolean(), Sidebar.table()) :: :ok | {:error, term()}
  def sync_observatory(visible?, sidebar_registry \\ Sidebar.default_table())
      when is_boolean(visible?) do
    result =
      Sidebar.register(sidebar_registry, @builtin_source, %{
        id: @observatory_id,
        display_name: "BEAM Observatory",
        description: "Runtime process tree",
        placement: :left,
        priority: 30,
        preferred_width: 52,
        visible?: visible?,
        focused?: visible?,
        semantic_kind: "observatory",
        icon: "network",
        action_handler: {__MODULE__, :handle_observatory_action}
      })

    focus_if_visible(result, visible?, @observatory_id, sidebar_registry)
  end

  @doc "Handles native sidebar actions for the BEAM Observatory surface."
  @spec handle_observatory_action(EditorState.t(), String.t(), map()) :: EditorState.t()
  def handle_observatory_action(%EditorState{} = state, "toggle", _context) do
    state
    |> Commands.execute(:toggle_beam_observatory)
    |> normalize_command_result()
  end

  def handle_observatory_action(%EditorState{} = state, "activate", _context) do
    if SidebarWorkflow.observatory_visible?(state) do
      focus_observatory(state)
    else
      state
      |> Commands.execute(:toggle_beam_observatory)
      |> normalize_command_result()
    end
  end

  def handle_observatory_action(%EditorState{} = state, _action, _context), do: state

  @spec focus_if_visible(:ok | {:error, term()}, boolean(), String.t(), Sidebar.table()) ::
          :ok | {:error, term()}
  defp focus_if_visible(:ok, true, id, sidebar_registry),
    do: Sidebar.focus_left(sidebar_registry, id)

  defp focus_if_visible(:ok, false, _id, _sidebar_registry), do: :ok
  defp focus_if_visible({:error, _reason} = error, _visible?, _id, _sidebar_registry), do: error

  @spec focus_observatory(EditorState.t()) :: EditorState.t()
  defp focus_observatory(state) do
    file_tree = FileTreeState.unfocus(state.workspace.file_tree)
    workspace = State.set_file_tree(state.workspace, file_tree)
    state = %{state | workspace: State.set_keymap_scope(workspace, :editor)}

    state
    |> SidebarWorkflow.select(@observatory_id)
    |> Layout.invalidate()
  end

  @spec normalize_command_result(EditorState.t() | {EditorState.t(), term()}) :: EditorState.t()
  defp normalize_command_result({state, _effect}), do: state
  defp normalize_command_result(state), do: state
end
