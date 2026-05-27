defmodule MingaEditor.RenderModel.UI.GitStatusBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.GitStatus

  @spec build(map() | nil, boolean(), map() | nil) :: GitStatus.t()
  def build(nil, syncing, toast) do
    %GitStatus{
      repo_state: :not_a_repo,
      syncing: syncing,
      branch: "",
      ahead: 0,
      behind: 0,
      entries: [],
      entry_base_path: "",
      last_commit_message: "",
      stash_count: 0,
      git_toast: normalize_toast(toast)
    }
  end

  def build(%{} = panel_data, syncing, toast) do
    data = panel_to_map(panel_data)

    entries =
      (Map.get(data, :entries) || [])
      |> Enum.map(fn entry ->
        %{path: entry.path, status: entry.status, staged: entry.staged}
      end)

    %GitStatus{
      repo_state: Map.get(data, :repo_state, :normal),
      syncing: syncing,
      branch: Map.get(data, :branch) || "",
      ahead: Map.get(data, :ahead) || 0,
      behind: Map.get(data, :behind) || 0,
      entries: entries,
      entry_base_path: Map.get(data, :entry_base_path) || Map.get(data, :git_root) || "",
      last_commit_message: Map.get(data, :last_commit_message) || "",
      stash_count: Map.get(data, :stash_count) || 0,
      git_toast: normalize_toast(toast)
    }
  end

  @spec panel_to_map(map()) :: map()
  defp panel_to_map(%{__struct__: _module} = panel), do: Map.from_struct(panel)
  defp panel_to_map(panel), do: panel

  @spec normalize_toast(map() | nil) :: GitStatus.toast() | nil
  defp normalize_toast(nil), do: nil

  defp normalize_toast(%{message: message, level: level, action: action}) do
    %{message: message, level: level, action: action}
  end

  defp normalize_toast(_), do: nil
end
