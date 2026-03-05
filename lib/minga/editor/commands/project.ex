defmodule Minga.Editor.Commands.Project do
  @moduledoc """
  Project commands: switch project, find file in project, invalidate cache,
  add/remove known projects.
  """

  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode
  alias Minga.Project

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()

  def execute(state, :project_find_file) do
    PickerUI.open(state, Minga.Picker.FileSource)
  end

  def execute(state, :project_recent_files) do
    PickerUI.open(state, Minga.Picker.RecentFileSource)
  end

  def execute(state, :project_switch) do
    PickerUI.open(state, Minga.Picker.ProjectSource)
  end

  def execute(state, :project_invalidate) do
    Project.invalidate()
    %{state | status_msg: "Project file cache invalidated"}
  catch
    :exit, _ -> %{state | status_msg: "No project active"}
  end

  def execute(state, :project_add) do
    root = project_root()

    case root do
      nil ->
        %{state | status_msg: "No project root detected"}

      path ->
        Project.add(path)
        %{state | status_msg: "Added project: #{Path.basename(path)}"}
    end
  catch
    :exit, _ -> state
  end

  def execute(state, :project_remove) do
    root = project_root()

    case root do
      nil ->
        %{state | status_msg: "No project root detected"}

      path ->
        Project.remove(path)
        %{state | status_msg: "Removed project: #{Path.basename(path)}"}
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
end
