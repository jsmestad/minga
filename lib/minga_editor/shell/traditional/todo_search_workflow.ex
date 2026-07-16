defmodule MingaEditor.Shell.Traditional.TodoSearchWorkflow do
  @moduledoc """
  Owns opening and scheduling the TODO-search picker workflow.
  """

  alias Minga.Project.WorkspaceSnapshot
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.TodoSearch
  alias MingaEditor.PickerUI
  alias MingaEditor.UI.Picker.TodoSearchSource

  @doc "Opens the TODO picker and admits its repository scan to the effect scheduler."
  @spec open(MingaEditor.State.t()) :: MingaEditor.State.t()
  def open(state) do
    {state, revision} = PickerUI.open_loading(state, TodoSearchSource)
    schedule(state, active_workspace_snapshot(), revision)
  end

  @spec schedule(MingaEditor.State.t(), WorkspaceSnapshot.t() | nil, reference()) ::
          MingaEditor.State.t()
  defp schedule(state, nil, revision) do
    apply_failure(state, revision, "No directory workspace active")
  end

  defp schedule(%{effect_scheduler: nil} = state, _snapshot, revision) do
    apply_failure(state, revision, "TODO search scheduler unavailable")
  end

  defp schedule(state, %WorkspaceSnapshot{} = snapshot, revision) do
    case EffectScheduler.schedule(state.effect_scheduler, TodoSearch.request(snapshot, revision)) do
      {:ok, _request_id, _disposition} ->
        state

      {:error, reason} ->
        apply_failure(state, revision, "TODO search not scheduled: #{inspect(reason)}")
    end
  catch
    :exit, reason ->
      apply_failure(state, revision, "TODO search scheduler unavailable: #{inspect(reason)}")
  end

  @spec active_workspace_snapshot() :: WorkspaceSnapshot.t() | nil
  defp active_workspace_snapshot do
    Minga.Project.snapshot()
  catch
    :exit, _reason -> nil
  end

  @spec apply_failure(MingaEditor.State.t(), reference(), String.t()) :: MingaEditor.State.t()
  defp apply_failure(state, revision, message) do
    {:ok, state} =
      PickerUI.apply_fetch_result(state, TodoSearchSource, revision, {:error, message})

    state
  end
end
