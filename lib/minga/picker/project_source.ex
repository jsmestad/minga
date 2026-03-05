defmodule Minga.Picker.ProjectSource do
  @moduledoc """
  Picker source for switching between known projects.

  Lists all known projects from `Minga.Project`. Selecting a project switches
  the current project root and then opens the file finder scoped to that root.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Project

  require Logger

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch project"

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(_context) do
    Project.known_projects()
    |> Enum.with_index()
    |> Enum.map(fn {root, idx} ->
      label = Path.basename(root)
      {idx, label, root}
    end)
  catch
    :exit, _ -> []
  end

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select({_idx, _label, root_path}, state) do
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
