defmodule MingaEditor.State.LSP.PendingRequests do
  @moduledoc """
  Pure indexes for Editor-global LSP request correlations.

  One response reference has exactly one semantic owner. Formatting keeps extra Buffer and newest indexes for cancellation while all request variants share the `by_ref` authority.
  """

  alias MingaEditor.State.LSP.FormatOperation

  defstruct by_ref: %{}, format_by_buffer: %{}, newest_formats: []

  @type response_kind :: MingaEditor.State.LSP.response_kind()
  @type operation_kind :: :references | :rename
  @type request ::
          {:response, response_kind()}
          | {:hover_mouse, non_neg_integer(), non_neg_integer(), pid(), non_neg_integer(),
             non_neg_integer(), non_neg_integer()}
          | {:semantic_tokens, pid()}
          | {:operation, operation_kind(), MingaEditor.State.Operation.id(),
             MingaEditor.State.Tab.id() | nil}
          | {:format, FormatOperation.t()}

  @type t :: %__MODULE__{
          by_ref: %{reference() => request()},
          format_by_buffer: %{pid() => reference()},
          newest_formats: [reference()]
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec track_response(t(), reference(), response_kind()) :: {:ok, t()} | {:error, :duplicate_ref}
  def track_response(%__MODULE__{} = pending, ref, kind) when is_reference(ref) do
    track_request(pending, ref, {:response, kind})
  end

  @spec track_hover_mouse(
          t(),
          reference(),
          non_neg_integer(),
          non_neg_integer(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, t()} | {:error, :duplicate_ref}
  def track_hover_mouse(
        %__MODULE__{} = pending,
        ref,
        row,
        col,
        buffer,
        buffer_line,
        buffer_col,
        version
      )
      when is_reference(ref) and is_integer(row) and row >= 0 and is_integer(col) and col >= 0 and
             is_pid(buffer) and is_integer(buffer_line) and buffer_line >= 0 and
             is_integer(buffer_col) and buffer_col >= 0 and is_integer(version) and version >= 0 do
    track_request(
      pending,
      ref,
      {:hover_mouse, row, col, buffer, buffer_line, buffer_col, version}
    )
  end

  @spec track_semantic_tokens(t(), reference(), pid()) :: {:ok, t()} | {:error, :duplicate_ref}
  def track_semantic_tokens(%__MODULE__{} = pending, ref, buffer)
      when is_reference(ref) and is_pid(buffer) do
    track_request(pending, ref, {:semantic_tokens, buffer})
  end

  @spec track_operation(
          t(),
          reference(),
          operation_kind(),
          MingaEditor.State.Operation.id(),
          MingaEditor.State.Tab.id() | nil
        ) :: {:ok, t()} | {:error, :duplicate_ref}
  def track_operation(%__MODULE__{} = pending, ref, kind, operation_id, tab_id)
      when is_reference(ref) and kind in [:references, :rename] and is_integer(operation_id) and
             operation_id > 0 and (is_nil(tab_id) or (is_integer(tab_id) and tab_id > 0)) do
    track_request(pending, ref, {:operation, kind, operation_id, tab_id})
  end

  @spec track_format(t(), FormatOperation.t()) ::
          {:ok, t()} | {:error, :duplicate_ref | :buffer_busy}
  def track_format(%__MODULE__{} = pending, %FormatOperation{} = operation) do
    track_format_ref(Map.fetch(pending.by_ref, operation.ref), pending, operation)
  end

  @spec take(t(), reference()) :: {:ok, request(), t()} | :error
  def take(%__MODULE__{} = pending, ref) when is_reference(ref) do
    case Map.pop(pending.by_ref, ref) do
      {nil, _by_ref} ->
        :error

      {{:format, %FormatOperation{} = operation} = request, by_ref} ->
        {:ok, request, drop_format_indexes(%{pending | by_ref: by_ref}, operation, ref)}

      {request, by_ref} ->
        {:ok, request, %{pending | by_ref: by_ref}}
    end
  end

  @spec take_operations_for_tab(t(), MingaEditor.State.Tab.id()) :: {[request()], t()}
  def take_operations_for_tab(%__MODULE__{} = pending, tab_id)
      when is_integer(tab_id) and tab_id > 0 do
    {requests, by_ref} =
      Enum.reduce(pending.by_ref, {[], %{}}, fn
        {_ref, {:operation, _kind, _operation_id, ^tab_id} = request}, {requests, by_ref} ->
          {[request | requests], by_ref}

        {ref, request}, {requests, by_ref} ->
          {requests, Map.put(by_ref, ref, request)}
      end)

    {Enum.reverse(requests), %{pending | by_ref: by_ref}}
  end

  @spec fetch(t(), reference()) :: {:ok, request()} | :error
  def fetch(%__MODULE__{} = pending, ref) when is_reference(ref),
    do: Map.fetch(pending.by_ref, ref)

  @spec fetch_format(t(), reference()) :: {:ok, FormatOperation.t()} | :error
  def fetch_format(%__MODULE__{} = pending, ref) when is_reference(ref) do
    case Map.fetch(pending.by_ref, ref) do
      {:ok, {:format, operation}} -> {:ok, operation}
      _ -> :error
    end
  end

  @spec format_for_buffer(t(), pid()) :: FormatOperation.t() | nil
  def format_for_buffer(%__MODULE__{} = pending, buffer) when is_pid(buffer) do
    with {:ok, ref} <- Map.fetch(pending.format_by_buffer, buffer),
         {:ok, operation} <- fetch_format(pending, ref) do
      operation
    else
      _ -> nil
    end
  end

  @spec newest_format(t()) :: FormatOperation.t() | nil
  def newest_format(%__MODULE__{newest_formats: [ref | _]} = pending) do
    case fetch_format(pending, ref) do
      {:ok, operation} -> operation
      :error -> nil
    end
  end

  def newest_format(%__MODULE__{}), do: nil

  @spec drop_format(t(), reference()) :: t()
  def drop_format(%__MODULE__{} = pending, ref) when is_reference(ref) do
    case Map.pop(pending.by_ref, ref) do
      {{:format, %FormatOperation{} = operation}, by_ref} ->
        drop_format_indexes(%{pending | by_ref: by_ref}, operation, ref)

      _ ->
        pending
    end
  end

  @spec format_active?(t(), reference()) :: boolean()
  def format_active?(%__MODULE__{} = pending, ref) when is_reference(ref),
    do: match?({:ok, %FormatOperation{}}, fetch_format(pending, ref))

  defp track_request(%__MODULE__{} = pending, ref, request) do
    if Map.has_key?(pending.by_ref, ref),
      do: {:error, :duplicate_ref},
      else: {:ok, %{pending | by_ref: Map.put(pending.by_ref, ref, request)}}
  end

  defp track_format_ref({:ok, _request}, %__MODULE__{}, %FormatOperation{}),
    do: {:error, :duplicate_ref}

  defp track_format_ref(:error, %__MODULE__{} = pending, %FormatOperation{} = operation) do
    track_format_buffer(Map.fetch(pending.format_by_buffer, operation.buffer), pending, operation)
  end

  defp track_format_buffer({:ok, _ref}, %__MODULE__{}, %FormatOperation{}),
    do: {:error, :buffer_busy}

  defp track_format_buffer(:error, %__MODULE__{} = pending, %FormatOperation{} = operation) do
    {:ok,
     %__MODULE__{
       pending
       | by_ref: Map.put(pending.by_ref, operation.ref, {:format, operation}),
         format_by_buffer: Map.put(pending.format_by_buffer, operation.buffer, operation.ref),
         newest_formats: [operation.ref | pending.newest_formats]
     }}
  end

  defp drop_format_indexes(%__MODULE__{} = pending, %FormatOperation{} = operation, ref) do
    %__MODULE__{
      pending
      | format_by_buffer: Map.delete(pending.format_by_buffer, operation.buffer),
        newest_formats: List.delete(pending.newest_formats, ref)
    }
  end
end
