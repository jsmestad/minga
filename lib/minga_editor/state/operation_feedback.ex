defmodule MingaEditor.State.OperationFeedback do
  @moduledoc """
  Editor-global, bounded owner for identity-keyed asynchronous operation feedback.

  Selection is deterministic: the newest active operation wins; when none are
  active, the newest retained terminal operation wins. Starting another
  operation for the same resource marks the older active operation stale.
  """

  alias MingaEditor.State.Operation
  alias MingaEditor.State.OperationProgress
  alias MingaEditor.State.OperationQueue

  @default_limit 32

  @enforce_keys [:limit, :next_id, :operations]
  defstruct limit: @default_limit, next_id: 1, operations: %{}

  @type t :: %__MODULE__{
          limit: pos_integer(),
          next_id: pos_integer(),
          operations: %{optional(Operation.id()) => Operation.t()}
        }
  @doc "Builds an empty feedback store with an explicit positive retention bound."
  @spec new() :: t()
  @spec new(pos_integer()) :: t()
  def new(limit \\ @default_limit)

  def new(limit) when is_integer(limit) and limit > 0 do
    %__MODULE__{limit: limit, next_id: 1, operations: %{}}
  end

  @doc "Starts an operation and returns its updated store and monotonic wire identity."
  @spec start(t(), Operation.kind(), Operation.resource(), String.t()) :: {t(), Operation.t()}
  @spec start(t(), Operation.kind(), Operation.resource(), String.t(), keyword()) ::
          {t(), Operation.t()}
  def start(%__MODULE__{} = feedback, kind, resource, message, opts \\ []) do
    id = feedback.next_id
    cancelable? = Keyword.get(opts, :cancelable?, true)
    replace? = Keyword.get(opts, :replace?, true)
    operations = replace_operations(feedback.operations, resource, replace?)

    operation = Operation.new(id, kind, resource, message, cancelable?, id)

    feedback =
      feedback
      |> Map.put(:next_id, id + 1)
      |> Map.put(:operations, Map.put(operations, id, operation))
      |> enforce_limit()

    {feedback, operation}
  end

  @doc "Applies a scheduler-authored queued transition if the identity is still active."
  @spec queued(t(), Operation.id(), String.t(), integer(), integer()) ::
          {:ok, t()} | {:error, OperationQueue.error()}
  def queued(%__MODULE__{} = feedback, id, message, position, total) do
    case OperationQueue.new(position, total) do
      {:ok, queue} -> {:ok, queue_active(feedback, id, message, queue)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Applies a running transition if the identity is still active."
  @spec running(t(), Operation.id(), String.t()) :: t()
  def running(%__MODULE__{} = feedback, id, message) do
    run_active(feedback, id, message)
  end

  @doc "Records validated domain progress if the identity is still active."
  @spec report_progress(t(), Operation.id(), integer(), integer()) ::
          {:ok, t()} | {:error, OperationProgress.error()}
  def report_progress(%__MODULE__{} = feedback, id, current, total) do
    case OperationProgress.new(current, total) do
      {:ok, progress} ->
        {:ok, progress_active(feedback, id, progress)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Finishes an active identity with one of the semantic terminal statuses."
  @spec finish(t(), Operation.id(), Operation.terminal_status(), String.t()) :: t()
  def finish(%__MODULE__{} = feedback, id, status, message) do
    finish_active(feedback, id, status, message)
  end

  @doc "Marks an active identity timed out."
  @spec timeout(t(), Operation.id(), String.t()) :: t()
  def timeout(%__MODULE__{} = feedback, id, message), do: finish(feedback, id, :timeout, message)

  @doc "Marks an active identity canceled."
  @spec cancel(t(), Operation.id(), String.t()) :: t()
  def cancel(%__MODULE__{} = feedback, id, message), do: finish(feedback, id, :canceled, message)

  @doc "Marks an active identity stale."
  @spec stale(t(), Operation.id(), String.t()) :: t()
  def stale(%__MODULE__{} = feedback, id, message), do: finish(feedback, id, :stale, message)

  @doc "Dismisses one retained identity; a missing identity is an identity-safe no-op."
  @spec dismiss(t(), Operation.id()) :: t()
  def dismiss(%__MODULE__{} = feedback, id) do
    %{feedback | operations: Map.delete(feedback.operations, id)}
  end

  @doc "Returns an operation by identity."
  @spec fetch(t(), Operation.id()) :: {:ok, Operation.t()} | :error
  def fetch(%__MODULE__{} = feedback, id), do: Map.fetch(feedback.operations, id)

  @doc "Returns the number of retained operations."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = feedback), do: map_size(feedback.operations)

  @doc "Returns whether the correlated operation can still receive lifecycle updates."
  @spec active?(t(), Operation.id()) :: boolean()
  def active?(%__MODULE__{} = feedback, id) when is_integer(id) and id > 0 do
    case fetch(feedback, id) do
      {:ok, operation} -> Operation.active?(operation)
      :error -> false
    end
  end

  @doc "Selects the newest active operation, otherwise the newest retained terminal operation."
  @spec selected(t()) :: Operation.t() | nil
  def selected(%__MODULE__{} = feedback) do
    feedback.operations
    |> Map.values()
    |> Enum.reduce(nil, &select_candidate/2)
  end

  @spec select_candidate(Operation.t(), Operation.t() | nil) :: Operation.t()
  defp select_candidate(operation, nil), do: operation

  defp select_candidate(
         %Operation{status: status} = operation,
         %Operation{status: selected_status}
       )
       when status in [:pending, :queued, :running] and
              selected_status not in [:pending, :queued, :running],
       do: operation

  defp select_candidate(
         %Operation{status: status, order: order} = operation,
         %Operation{status: selected_status, order: selected_order}
       )
       when status in [:pending, :queued, :running] and
              selected_status in [:pending, :queued, :running] and order > selected_order,
       do: operation

  defp select_candidate(
         %Operation{status: status, order: order} = operation,
         %Operation{status: selected_status, order: selected_order}
       )
       when status not in [:pending, :queued, :running] and
              selected_status not in [:pending, :queued, :running] and order > selected_order,
       do: operation

  defp select_candidate(_operation, selected), do: selected

  @spec replace_operations(%{Operation.id() => Operation.t()}, Operation.resource(), boolean()) ::
          %{Operation.id() => Operation.t()}
  defp replace_operations(operations, _resource, false), do: operations

  defp replace_operations(operations, resource, true) do
    Map.new(operations, fn {operation_id, operation} ->
      {operation_id, replace_matching(operation, resource)}
    end)
  end

  @spec replace_matching(Operation.t(), Operation.resource()) :: Operation.t()
  defp replace_matching(%Operation{resource: resource} = operation, resource) do
    Operation.finish(operation, :stale, "Replaced by a newer operation")
  end

  defp replace_matching(operation, _resource), do: operation

  @spec queue_active(t(), Operation.id(), String.t(), OperationQueue.t()) :: t()
  defp queue_active(%__MODULE__{} = feedback, id, message, %OperationQueue{} = queue) do
    case Map.fetch(feedback.operations, id) do
      {:ok, operation} ->
        update_operation(feedback, id, Operation.queued(operation, message, queue))

      :error ->
        feedback
    end
  end

  @spec run_active(t(), Operation.id(), String.t()) :: t()
  defp run_active(%__MODULE__{} = feedback, id, message) do
    case Map.fetch(feedback.operations, id) do
      {:ok, operation} -> update_operation(feedback, id, Operation.running(operation, message))
      :error -> feedback
    end
  end

  @spec progress_active(t(), Operation.id(), OperationProgress.t()) :: t()
  defp progress_active(%__MODULE__{} = feedback, id, %OperationProgress{} = progress) do
    case Map.fetch(feedback.operations, id) do
      {:ok, operation} ->
        update_operation(feedback, id, Operation.report_progress(operation, progress))

      :error ->
        feedback
    end
  end

  @spec finish_active(t(), Operation.id(), Operation.terminal_status(), String.t()) :: t()
  defp finish_active(%__MODULE__{} = feedback, id, status, message) do
    case Map.fetch(feedback.operations, id) do
      {:ok, operation} ->
        update_operation(feedback, id, Operation.finish(operation, status, message))

      :error ->
        feedback
    end
  end

  @spec update_operation(t(), Operation.id(), Operation.t()) :: t()
  defp update_operation(%__MODULE__{} = feedback, id, %Operation{} = operation) do
    if Map.has_key?(feedback.operations, id) do
      feedback
      |> Map.put(:operations, Map.put(feedback.operations, id, operation))
      |> enforce_limit()
    else
      feedback
    end
  end

  @spec enforce_limit(t()) :: t()
  defp enforce_limit(%__MODULE__{} = feedback) do
    terminals =
      feedback.operations
      |> Map.values()
      |> Enum.filter(&Operation.terminal?/1)
      |> Enum.sort_by(& &1.order)

    eviction_count =
      min(max(map_size(feedback.operations) - feedback.limit, 0), length(terminals))

    operations =
      terminals
      |> Enum.take(eviction_count)
      |> Enum.reduce(feedback.operations, fn operation, operations ->
        Map.delete(operations, operation.id)
      end)

    %{feedback | operations: operations}
  end
end
