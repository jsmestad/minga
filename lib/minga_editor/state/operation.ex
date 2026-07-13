defmodule MingaEditor.State.Operation do
  @moduledoc "Serializable semantic feedback for one correlated asynchronous operation."

  alias MingaEditor.State.OperationProgress
  alias MingaEditor.State.OperationQueue

  @type id :: pos_integer()
  @type kind ::
          :external_format
          | :git_stage
          | :git_unstage
          | :git_discard
          | :git_stage_all
          | :git_unstage_all
          | :git_commit
          | :lsp_references
          | :lsp_rename
  @type resource :: String.t()
  @type active_status :: :pending | :queued | :running
  @type terminal_status :: :success | :error | :timeout | :canceled | :stale
  @type status :: active_status() | terminal_status()

  @enforce_keys [:id, :kind, :resource, :status, :message, :cancelable?, :order]
  @derive JSON.Encoder
  defstruct [
    :id,
    :kind,
    :resource,
    :status,
    :message,
    :queue,
    :progress,
    :order,
    cancelable?: false
  ]

  @type t :: %__MODULE__{
          id: id(),
          kind: kind(),
          resource: resource(),
          status: status(),
          message: String.t(),
          queue: OperationQueue.t() | nil,
          progress: OperationProgress.t() | nil,
          cancelable?: boolean(),
          order: pos_integer()
        }

  @kinds [
    :external_format,
    :git_stage,
    :git_unstage,
    :git_discard,
    :git_stage_all,
    :git_unstage_all,
    :git_commit,
    :lsp_references,
    :lsp_rename
  ]
  @terminal_statuses [:success, :error, :timeout, :canceled, :stale]

  @doc "Builds a pending operation with stable identity and deterministic order."
  @spec new(id(), kind(), resource(), String.t(), boolean(), pos_integer()) :: t()
  def new(id, kind, resource, message, cancelable?, order)
      when is_integer(id) and id > 0 and kind in @kinds and is_binary(resource) and
             is_binary(message) and is_boolean(cancelable?) and is_integer(order) and order > 0 do
    %__MODULE__{
      id: id,
      kind: kind,
      resource: resource,
      status: :pending,
      message: message,
      queue: nil,
      progress: nil,
      cancelable?: cancelable?,
      order: order
    }
  end

  @doc "Marks an active operation queued with scheduler-authored metadata."
  @spec queued(t(), String.t(), OperationQueue.t()) :: t()
  def queued(%__MODULE__{} = operation, message, %OperationQueue{} = queue)
      when is_binary(message) do
    transition_active(operation, :queued, message, queue)
  end

  @doc "Marks an active operation running and clears queue metadata."
  @spec running(t(), String.t()) :: t()
  def running(%__MODULE__{} = operation, message) when is_binary(message) do
    transition_active(operation, :running, message, nil)
  end

  @doc "Records valid domain-authored progress on an active operation."
  @spec report_progress(t(), OperationProgress.t()) :: t()
  def report_progress(%__MODULE__{} = operation, %OperationProgress{} = progress) do
    if active?(operation), do: %{operation | progress: progress}, else: operation
  end

  @doc "Finishes an active operation and clears active-only queue and cancellation state."
  @spec finish(t(), terminal_status(), String.t()) :: t()
  def finish(%__MODULE__{} = operation, status, message)
      when status in @terminal_statuses and is_binary(message) do
    if active?(operation) do
      %{operation | status: status, message: message, queue: nil, cancelable?: false}
    else
      operation
    end
  end

  @doc "Returns whether the operation can still receive lifecycle updates."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: status}), do: status in [:pending, :queued, :running]

  @doc "Returns whether the operation has reached a semantic terminal status."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses

  @spec transition_active(t(), active_status(), String.t(), OperationQueue.t() | nil) :: t()
  defp transition_active(operation, status, message, queue) do
    if active?(operation) do
      %{operation | status: status, message: message, queue: queue}
    else
      operation
    end
  end
end
