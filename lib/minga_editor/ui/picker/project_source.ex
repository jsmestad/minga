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
  alias MingaEditor.UI.Picker.Empty
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
    |> Enum.map(fn root ->
      label = Path.basename(root)
      %Item{id: root, label: label, description: root}
    end)
  catch
    :exit, _ -> []
  end

  @doc """
  With no known projects, says how Minga learns them and offers to add a folder or open a file; with a query that matches none, says so and offers the same.
  """
  @impl true
  @spec empty(Empty.request()) :: Empty.t()
  def empty(%{query: query, total: total}) do
    {title, why} =
      case {total, String.trim(query)} do
        {0, _query} ->
          {"No projects yet.", "Minga remembers folders you open."}

        {_total, name} ->
          {"No project matches #{Empty.quoted(name)}.", "Minga remembers folders you open."}
      end

    %Empty{
      typing?: total > 0,
      title: title,
      why: why,
      rows: [
        Empty.command_row(:project_add, "Add a folder"),
        Empty.command_row(:find_file, "Open a file")
      ]
    }
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {:next_step, _step}} = item, state), do: Empty.run_command(item, state)

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
end
