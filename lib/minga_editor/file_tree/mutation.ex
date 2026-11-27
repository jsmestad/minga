defmodule MingaEditor.FileTree.Mutation do
  @moduledoc "Keeps foreground filesystem mutations and editor shutdown out of a running file-tree operation."

  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState

  @doc "Returns a busy notice if a file-tree operation has not reached its terminal outcome."
  @spec require_idle(EditorState.t()) :: {:ok, EditorState.t()} | {:blocked, EditorState.t()}
  def require_idle(state) do
    if EffectScheduler.active_activity?(state.effect_scheduler, :file_tree_mutation) do
      {:blocked,
       NoticeWorkflow.publish(
         state,
         "File tree operation in progress. Try again when it finishes."
       )}
    else
      {:ok, state}
    end
  end

  @doc "Admits at most one filesystem operation, without queuing work during native quit."
  @spec schedule(EditorState.t(), struct()) :: EffectScheduler.admission()
  def schedule(%EditorState{session: %{application_quit: :idle}, effect_scheduler: nil}, _effect),
    do: {:error, :scheduler_unavailable}

  def schedule(
        %EditorState{session: %{application_quit: :idle}, effect_scheduler: scheduler},
        effect
      ) do
    request =
      Request.new(effect, :file_tree_mutation, Policy.fifo(0), activity: :file_tree_mutation)

    EffectScheduler.schedule(scheduler, request)
  catch
    :exit, _reason -> {:error, :scheduler_unavailable}
  end

  def schedule(%EditorState{}, _effect), do: {:error, :application_quitting}
end
