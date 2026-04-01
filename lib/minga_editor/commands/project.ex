defmodule MingaEditor.Commands.Project do
  @moduledoc """
  Project commands: switch project, find file in project, invalidate cache,
  add/remove known projects.
  """

  @behaviour Minga.Command.Provider

  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias Minga.Mode
  alias Minga.Project

  @type state :: EditorState.t()

  @command_specs [
    {:project_find_file, "Find file in project", true},
    {:project_invalidate, "Invalidate project cache", true},
    {:project_add, "Add project", true},
    {:project_remove, "Remove project", true},
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
    root = project_root()

    case root do
      nil ->
        EditorState.set_status(state, "No project root detected")

      path ->
        Project.add(path)
        EditorState.set_status(state, "Added project: #{Path.basename(path)}")
    end
  catch
    :exit, _ -> state
  end

  def execute(state, :project_remove) do
    root = project_root()

    case root do
      nil ->
        EditorState.set_status(state, "No project root detected")

      path ->
        Project.remove(path)
        EditorState.set_status(state, "Removed project: #{Path.basename(path)}")
    end
  catch
    :exit, _ -> state
  end

  @spec project_root() :: String.t() | nil
  defp project_root do
    Project.root()
  catch
    :exit, _ -> nil
  end

  @impl Minga.Command.Provider
  def __commands__ do
    Enum.map(@command_specs, fn {name, desc, requires_buffer} ->
      %Minga.Command{
        name: name,
        description: desc,
        requires_buffer: requires_buffer,
        execute: fn state -> execute(state, name) end
      }
    end)
  end
end
