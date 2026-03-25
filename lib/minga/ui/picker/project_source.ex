defmodule Minga.UI.Picker.ProjectSource do
  @moduledoc """
  Picker source for switching between known projects.

  Lists all known projects from `Minga.Project`. Selecting a project switches
  the current project root and then opens the file finder scoped to that root.
  """

  @behaviour Minga.UI.Picker.Source

  alias Minga.UI.Picker.Item

  alias Minga.Project

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch project"

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(_context) do
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
    Project.switch(root_path)

    # After switching project, open the file finder scoped to the new root.
    # We use a pending_command pattern so the Editor dispatches it after
    # the picker closes.
    Map.put(state, :pending_command, :project_find_file)
  catch
    :exit, _ -> state
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state
end
