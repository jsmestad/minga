defmodule MingaEditor.RenderModel.UI.GitStatusBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.GitStatus
  alias MingaEditor.Shell.Traditional.GitToast

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

    %GitStatus{
      repo_state: Map.get(data, :repo_state, :normal),
      syncing: syncing,
      branch: Map.get(data, :branch) || "",
      ahead: Map.get(data, :ahead) || 0,
      behind: Map.get(data, :behind) || 0,
      entries: wire_entries(Map.get(data, :entries) || []),
      entry_base_path: Map.get(data, :entry_base_path) || Map.get(data, :git_root) || "",
      last_commit_message: Map.get(data, :last_commit_message) || "",
      stash_count: Map.get(data, :stash_count) || 0,
      git_toast: normalize_toast(toast)
    }
  end

  @spec panel_to_map(map()) :: map()
  defp panel_to_map(%{__struct__: _module} = panel), do: Map.from_struct(panel)
  defp panel_to_map(panel), do: panel

  # Normalize each source entry into the wire-shaped map the generated
  # encode_git_status_entry/1 consumes. All derivation lives here (ruling 4): the
  # path_hash and the multi-field section predicate that used to live in the
  # encoder become plain fields.
  @spec wire_entries([map()]) :: [GitStatus.wire_entry()]
  defp wire_entries(entries) do
    Enum.map(entries, fn entry ->
      %{
        path_hash: :erlang.phash2(entry.path, 0xFFFFFFFF),
        section: section(entry),
        status: entry.status,
        path: entry.path
      }
    end)
  end

  # The section byte, formerly encode_status_section/1's multi-clause predicate.
  @spec section(map()) :: non_neg_integer()
  defp section(%{staged: true}), do: 0
  defp section(%{status: :untracked}), do: 2
  defp section(%{status: :conflict}), do: 3
  defp section(_entry), do: 1

  # Normalize a raw toast into the non-nullable wire map (presence byte plus the
  # conditional level/action/message tail). A nil action maps to :none.
  @spec normalize_toast(map() | nil) :: GitStatus.wire_toast()
  defp normalize_toast(nil), do: %{present: 0}

  defp normalize_toast(%GitToast{message: message, level: level, action: action})
       when is_binary(message) and level in [:info, :success, :warning, :error] do
    %{present: 1, level: level, action: action || :none, message: message}
  end

  defp normalize_toast(%{message: message, level: level, action: action})
       when is_binary(message) and level in [:info, :success, :warning, :error] do
    %{present: 1, level: level, action: action || :none, message: message}
  end

  defp normalize_toast(_toast), do: %{present: 0}
end
