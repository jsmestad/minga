defmodule MingaEditor.Effects.Feedback do
  @moduledoc false

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.Operation
  alias MingaEditor.State.OperationQueue

  @spec queued(EditorState.t(), Operation.id(), String.t(), OperationQueue.t()) :: EditorState.t()
  def queued(state, id, message, %OperationQueue{position: position, total: total}) do
    {:ok, feedback} = Feedback.queue_operation(state.feedback, id, message, position, total)

    %{state | feedback: feedback}
  end

  @spec running(EditorState.t(), Operation.id(), String.t()) :: EditorState.t()
  def running(state, id, message) do
    %{state | feedback: Feedback.run_operation(state.feedback, id, message)}
  end

  @spec finished(EditorState.t(), Operation.id(), Operation.terminal_status(), String.t()) ::
          EditorState.t()
  def finished(state, id, status, message) do
    %{state | feedback: Feedback.finish_operation(state.feedback, id, status, message)}
  end
end
