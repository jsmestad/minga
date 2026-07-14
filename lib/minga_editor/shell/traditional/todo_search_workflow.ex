defmodule MingaEditor.Shell.Traditional.TodoSearchWorkflow do
  @moduledoc """
  Owns opening and scheduling the TODO-search picker workflow.
  """

  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.TodoSearch
  alias MingaEditor.PickerUI
  alias MingaEditor.UI.Picker.TodoSearchSource

  @doc "Opens the TODO picker and admits its repository scan to the effect scheduler."
  @spec open(MingaEditor.State.t()) :: MingaEditor.State.t()
  def open(state) do
    {state, revision} = PickerUI.open_loading(state, TodoSearchSource)
    schedule(state, Minga.Project.resolve_root(), revision)
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

  defp apply_failure(state, revision, message) do
    {:ok, state} =
      PickerUI.apply_fetch_result(state, TodoSearchSource, revision, {:error, message})

    state
  end
end
