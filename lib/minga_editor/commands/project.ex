defmodule MingaEditor.Commands.Project do
  @moduledoc """
  Project commands: switch project, find file in project, invalidate cache,
  add/remove known projects.
  """

  use MingaEditor.Commands.Provider

  alias MingaEditor.PickerUI
  alias MingaEditor.PromptUI
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias Minga.Mode
  alias Minga.Project

  @type state :: EditorState.t()

  @command_specs [
    {:project_find_file, "Find file in project", true},
    {:project_invalidate, "Invalidate project cache", true},
    {:project_close, "Close project", false},
    {:project_add, "Add project", false},
    {:project_remove, "Remove project", false},
    {:project_switch, "Switch project", false},
    {:project_recent_files, "Recent files", false}
  ]

  @spec execute(state(), Mode.command()) :: state()

  def execute(state, :project_find_file) do
    PickerUI.open(state, MingaEditor.UI.Picker.FileSource)
  end

  def execute(state, :project_recent_files) do
    PickerUI.open(state, MingaEditor.UI.Picker.RecentFileSource)
  end

  def execute(state, :project_switch) do
    PickerUI.open(state, MingaEditor.UI.Picker.ProjectSource)
  end

  def execute(state, :project_invalidate) do
    Project.invalidate()
    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "Project file cache invalidated")
  catch
    :exit, _ -> MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "No project active")
  end

  def execute(state, :project_close) do
    Project.close()

    state
    |> MingaEditor.Commands.FileTree.close()
    |> clear_file_tree_root()
  end

  def execute(state, :project_add) do
    default = project_add_default()
    PromptUI.open(state, MingaEditor.UI.Prompt.ProjectAdd, default: default)
  end

  def execute(state, :project_remove) do
    PickerUI.open(state, MingaEditor.UI.Picker.ProjectRemoveSource)
  end

  @spec clear_file_tree_root(state()) :: state()
  defp clear_file_tree_root(state) do
    file_tree = FileTreeState.set_project_root(state.workspace.file_tree, nil)
    %{state | workspace: SessionState.set_file_tree(state.workspace, file_tree)}
  end

  @spec project_add_default() :: String.t()
  defp project_add_default do
    case Project.resolve_root() do
      root when is_binary(root) -> Project.collapse_home(root)
      nil -> ""
    end
  end

  commands(@command_specs)
end
