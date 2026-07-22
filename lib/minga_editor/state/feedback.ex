defmodule MingaEditor.State.Feedback do
  @moduledoc """
  Cross-shell user feedback owned by the Editor.

  Native notifications and long-running operation feedback share lifecycle at
  the editor boundary while shell-specific notices and overlays remain in the
  active shell state.
  """

  alias MingaEditor.State.Operation
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.OperationQueue
  alias MingaEditor.UI.Notification
  alias MingaEditor.UI.NotificationCenter

  @type t :: %__MODULE__{
          notifications: NotificationCenter.t(),
          operation_feedback: OperationFeedback.t()
        }

  defstruct notifications: NotificationCenter.new(),
            operation_feedback: OperationFeedback.new()

  @doc "Adds or replaces a native notification."
  @spec upsert_notification(t(), Notification.t()) :: t()
  def upsert_notification(%__MODULE__{} = feedback, %Notification{} = notification) do
    %{feedback | notifications: NotificationCenter.upsert(feedback.notifications, notification)}
  end

  @doc "Dismisses a native notification by id."
  @spec dismiss_notification(t(), String.t()) :: t()
  def dismiss_notification(%__MODULE__{} = feedback, id) when is_binary(id),
    do: %{feedback | notifications: NotificationCenter.dismiss(feedback.notifications, id)}

  @doc "Dismisses a notification only when its timer correlation still matches."
  @spec dismiss_notification(t(), String.t(), reference()) :: t()
  def dismiss_notification(%__MODULE__{} = feedback, id, dismiss_ref) when is_binary(id),
    do: %{
      feedback
      | notifications: NotificationCenter.dismiss(feedback.notifications, id, dismiss_ref)
    }

  @doc "Commits operation feedback produced by its focused owner."
  @spec accept_operation_feedback(t(), OperationFeedback.t()) :: t()
  def accept_operation_feedback(%__MODULE__{} = feedback, %OperationFeedback{} = operations),
    do: %{feedback | operation_feedback: operations}

  @doc "Applies a scheduler-authored queued transition to the owned operation feedback."
  @spec queue_operation(t(), Operation.id(), String.t(), integer(), integer()) ::
          {:ok, t()} | {:error, OperationQueue.error()}
  def queue_operation(%__MODULE__{} = feedback, id, message, position, total) do
    case OperationFeedback.queued(feedback.operation_feedback, id, message, position, total) do
      {:ok, operations} -> {:ok, accept_operation_feedback(feedback, operations)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Applies a running transition to the owned operation feedback."
  @spec run_operation(t(), Operation.id(), String.t()) :: t()
  def run_operation(%__MODULE__{} = feedback, id, message) do
    accept_operation_feedback(
      feedback,
      OperationFeedback.running(feedback.operation_feedback, id, message)
    )
  end

  @doc "Finishes an active operation in the owned operation feedback."
  @spec finish_operation(t(), Operation.id(), Operation.terminal_status(), String.t()) :: t()
  def finish_operation(%__MODULE__{} = feedback, id, status, message) do
    accept_operation_feedback(
      feedback,
      OperationFeedback.finish(feedback.operation_feedback, id, status, message)
    )
  end
end
