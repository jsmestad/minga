defmodule MingaEditor.State.LSP.FormatOperations do
  @moduledoc """
  Pure indexes for current Editor-global LSP formatting operations.

  One operation may be current per Buffer. The newest active operation is tracked for Esc cancellation while requests for unrelated buffers remain independent.
  """

  alias MingaEditor.State.LSP.FormatOperation

  defstruct by_ref: %{}, by_buffer: %{}, newest_first: []

  @type t :: %__MODULE__{
          by_ref: %{reference() => FormatOperation.t()},
          by_buffer: %{pid() => reference()},
          newest_first: [reference()]
        }

  @doc "Returns an empty operation collection."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Tracks an operation when its Buffer has no current request."
  @spec track(t(), FormatOperation.t()) :: {:ok, t()} | {:error, :buffer_busy}
  def track(%__MODULE__{} = operations, %FormatOperation{} = operation) do
    case Map.fetch(operations.by_buffer, operation.buffer) do
      {:ok, _ref} ->
        {:error, :buffer_busy}

      :error ->
        {:ok,
         %__MODULE__{
           operations
           | by_ref: Map.put(operations.by_ref, operation.ref, operation),
             by_buffer: Map.put(operations.by_buffer, operation.buffer, operation.ref),
             newest_first: [operation.ref | operations.newest_first]
         }}
    end
  end

  @doc "Fetches an operation by its external request reference."
  @spec fetch(t(), reference()) :: {:ok, FormatOperation.t()} | :error
  def fetch(%__MODULE__{} = operations, ref) when is_reference(ref) do
    Map.fetch(operations.by_ref, ref)
  end

  @doc "Returns the operation for one Buffer."
  @spec for_buffer(t(), pid()) :: FormatOperation.t() | nil
  def for_buffer(%__MODULE__{} = operations, buffer) when is_pid(buffer) do
    case Map.fetch(operations.by_buffer, buffer) do
      {:ok, ref} -> Map.get(operations.by_ref, ref)
      :error -> nil
    end
  end

  @doc "Returns the newest active operation."
  @spec newest(t()) :: FormatOperation.t() | nil
  def newest(%__MODULE__{newest_first: [ref | _]} = operations),
    do: Map.get(operations.by_ref, ref)

  def newest(%__MODULE__{}), do: nil

  @doc "Drops an operation by request reference."
  @spec drop(t(), reference()) :: t()
  def drop(%__MODULE__{} = operations, ref) when is_reference(ref) do
    case Map.pop(operations.by_ref, ref) do
      {nil, _by_ref} ->
        operations

      {%FormatOperation{} = operation, by_ref} ->
        %__MODULE__{
          operations
          | by_ref: by_ref,
            by_buffer: Map.delete(operations.by_buffer, operation.buffer),
            newest_first: List.delete(operations.newest_first, ref)
        }
    end
  end
end
