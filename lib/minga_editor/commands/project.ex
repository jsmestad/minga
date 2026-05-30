defmodule MingaEditor.Commands.Project do
  @moduledoc """
  Project commands: switch project, find file in project, invalidate cache,
  add/remove known projects.
  """

  use MingaEditor.Commands.Provider

  alias MingaEditor.PickerUI
  alias MingaEditor.PromptUI
  alias MingaEditor.State, as: EditorState
  alias Minga.Mode
  alias Minga.Project

  @type state :: EditorState.t()

  @command_specs [
    {:project_find_file, "Find file in project", true},
    {:project_invalidate, "Invalidate project cache", true},
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
    EditorState.set_status(state, "Project file cache invalidated")
  catch
    :exit, _ -> EditorState.set_status(state, "No project active")
  end

  def execute(state, :project_add) do
    default = Project.resolve_root() |> Project.collapse_home()
    PromptUI.open(state, MingaEditor.UI.Prompt.ProjectAdd, default: default)
  end

  def execute(state, :project_remove) do
    PickerUI.open(state, MingaEditor.UI.Picker.ProjectRemoveSource)
  end

  commands(@command_specs)
end
