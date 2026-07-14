defmodule MingaEditor.Shell.Traditional.TodoSearchWorkflow do
  @moduledoc """
  Owns opening and scheduling the TODO-search picker workflow.
  """

  alias Minga.Project.Root
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.TodoSearch
  alias MingaEditor.PickerUI
  alias MingaEditor.UI.Picker.TodoSearchSource

  @doc "Opens the TODO picker and admits its repository scan to the effect scheduler."
  @spec open(MingaEditor.State.t()) :: MingaEditor.State.t()
  def open(state) do
    {state, revision} = PickerUI.open_loading(state, TodoSearchSource)
    schedule(state, workspace_root(state), revision)
  end

  defp schedule(state, nil, revision) do
    apply_failure(state, revision, "No directory workspace active")
  end

  defp schedule(%{effect_scheduler: nil} = state, _root, revision) do
    apply_failure(state, revision, "TODO search scheduler unavailable")
  end

  defp schedule(state, root, revision) do
    case EffectScheduler.schedule(state.effect_scheduler, TodoSearch.request(root, revision)) do
      {:ok, _request_id, _disposition} ->
        state

      {:error, reason} ->
        apply_failure(state, revision, "TODO search not scheduled: #{inspect(reason)}")
    end
  catch
    :exit, reason ->
      apply_failure(state, revision, "TODO search scheduler unavailable: #{inspect(reason)}")
  end

  @spec workspace_root(MingaEditor.State.t()) :: String.t() | nil
  defp workspace_root(%{workspace: %{file_tree: %{project_root: file_tree_root}}}) do
    resolve_workspace_root(file_tree_root, active_workspace_root())
  end

  @spec resolve_workspace_root(String.t() | nil, Root.t() | nil) :: String.t() | nil
  defp resolve_workspace_root(path, %Root{path: path} = root), do: authorized_path(root)

  defp resolve_workspace_root(path, _active_root) when is_binary(path) do
    case Root.directory(path) do
      {:ok, root} -> authorized_path(root)
      {:error, _reason} -> nil
    end
  end

  defp resolve_workspace_root(nil, %Root{} = root), do: authorized_path(root)
  defp resolve_workspace_root(nil, nil), do: nil

  @spec active_workspace_root() :: Root.t() | nil
  defp active_workspace_root do
    Minga.Project.workspace_root()
  catch
    :exit, _reason -> nil
  end

  @spec authorized_path(Root.t()) :: String.t() | nil
  defp authorized_path(root) do
    case Root.inventory_path(root) do
      {:ok, path} -> path
      {:error, _reason} -> nil
    end
  end

  defp apply_failure(state, revision, message) do
    {:ok, state} =
      PickerUI.apply_fetch_result(state, TodoSearchSource, revision, {:error, message})

    state
  end
end
