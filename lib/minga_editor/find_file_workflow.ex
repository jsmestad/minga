defmodule MingaEditor.FindFileWorkflow do
  @moduledoc "General Find file entry workflow for project search and filesystem browsing."

  alias Minga.Project
  alias Minga.Project.WorkspaceSnapshot
  alias MingaEditor.PickerUI
  alias MingaEditor.State
  alias MingaEditor.UI.Picker.DirectorySource
  alias MingaEditor.UI.Picker.FileSource
  alias MingaEditor.UI.Picker.FilesystemContext
  alias MingaEditor.UI.Picker.FilesystemQuery
  alias MingaEditor.UI.Picker.FindFileSession

  @doc "Opens general Find file from one captured launch directory and Home anchor."
  @spec open(State.t()) :: State.t()
  def open(%State{} = state) do
    launch_directory = File.cwd!()
    home_directory = Path.expand("~")

    case project_snapshot() do
      {:ok, %WorkspaceSnapshot{} = workspace} ->
        session = FindFileSession.new(launch_directory, home_directory, workspace)
        PickerUI.open(state, FileSource, FindFileSession.project_context(session))

      {:ok, nil} ->
        session = FindFileSession.new(launch_directory, home_directory, nil)
        context = FilesystemContext.new(FilesystemQuery.initial(session))
        PickerUI.open(state, DirectorySource, context)

      {:error, reason} ->
        PickerUI.open(state, FileSource, %{project_error: project_error(reason)})
    end
  end

  @spec project_snapshot() :: {:ok, WorkspaceSnapshot.t() | nil} | {:error, term()}
  defp project_snapshot do
    {:ok, Project.snapshot(Project)}
  catch
    :exit, reason -> {:error, reason}
  end

  @spec project_error(term()) :: String.t()
  defp project_error(_reason), do: "Project service is unavailable"
end
