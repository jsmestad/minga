defmodule MingaEditor.UI.Picker.ProjectSource do
  @moduledoc """
  Picker source for switching between known projects.

  Lists all known projects from `Minga.Project`. Selecting a project switches
  the current project root and then opens the file finder scoped to that root.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.FileTree.Freshness, as: FileTreeFreshness
  alias MingaEditor.PickerUI
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.FileSource
  alias MingaEditor.UI.Picker.Item

  alias Minga.Project
  alias Minga.Project.Root
  alias Minga.Project.WorkspaceSnapshot

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch project"

  @impl true
  @spec layout() :: MingaEditor.UI.Picker.Source.layout()
  def layout, do: :centered

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_ctx) do
    Project.known_projects()
    |> Enum.with_index()
    |> Enum.map(fn {root, _idx} ->
      label = Path.basename(root)
      %Item{id: root, label: label, description: root}
    end)
  catch
    :exit, _ -> []
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: root_path}, state) do
    case Root.directory(root_path) do
      {:ok, root} -> activate_project(root, state)
      {:error, _reason} -> state
    end
  catch
    :exit, _ -> state
  end

  @spec activate_project(Root.t(), term()) :: term()
  defp activate_project(%Root{} = root, state) do
    case Project.activate(Project, root) do
      {:ok, %WorkspaceSnapshot{root: installed_root}} ->
        state
        |> FileTreeFreshness.update_project_root(installed_root.path)
        |> PickerUI.open(FileSource, %{project_root: installed_root})

      {:error, _reason} ->
        state
    end
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state
end
