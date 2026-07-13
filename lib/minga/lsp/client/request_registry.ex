defmodule Minga.LSP.Client.RequestRegistry do
  @moduledoc "Pure correlation indexes for pending and recently canceled LSP requests."

  defstruct pending: %{}, ids_by_ref: %{}, ids_by_monitor: %{}, canceled_ids: %{}

  @typedoc "Caller for a pending request: a GenServer reply target, an async caller, or nil."
  @type pending_from :: GenServer.from() | {:async, pid(), reference()} | nil

  @typedoc "A pending request awaiting a response."
  @type pending_entry :: %{
          method: String.t(),
          from: pending_from(),
          timer: reference() | nil,
          request_ref: reference() | nil,
          caller_monitor: reference() | nil
        }

  @type t :: %__MODULE__{
          pending: %{integer() => pending_entry()},
          ids_by_ref: %{reference() => integer()},
          ids_by_monitor: %{reference() => integer()},
          canceled_ids: %{integer() => reference()}
        }

  @doc "Returns an empty request registry."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Tracks one pending request across all correlation indexes."
  @spec put(t(), integer(), pending_entry()) :: t()
  def put(%__MODULE__{} = registry, id, entry) when is_integer(id) and is_map(entry) do
    %__MODULE__{
      registry
      | pending: Map.put(registry.pending, id, entry),
        ids_by_ref: maybe_put(registry.ids_by_ref, entry.request_ref, id),
        ids_by_monitor: maybe_put(registry.ids_by_monitor, entry.caller_monitor, id)
    }
  end

  @doc "Fetches a pending request by JSON-RPC id."
  @spec fetch(t(), integer()) :: {:ok, pending_entry()} | :error
  def fetch(%__MODULE__{} = registry, id), do: Map.fetch(registry.pending, id)

  @doc "Returns the JSON-RPC id for an opaque caller request reference."
  @spec id_for_ref(t(), reference()) :: {:ok, integer()} | :error
  def id_for_ref(%__MODULE__{} = registry, ref), do: Map.fetch(registry.ids_by_ref, ref)

  @doc "Returns the JSON-RPC id owned by a caller monitor."
  @spec id_for_monitor(t(), reference()) :: {:ok, integer()} | :error
  def id_for_monitor(%__MODULE__{} = registry, monitor) do
    Map.fetch(registry.ids_by_monitor, monitor)
  end

  @doc "Drops one pending request from every correlation index."
  @spec pop(t(), integer()) :: {pending_entry() | nil, t()}
  def pop(%__MODULE__{} = registry, id) do
    case Map.pop(registry.pending, id) do
      {nil, _pending} ->
        {nil, registry}

      {entry, pending} ->
        updated = %__MODULE__{
          registry
          | pending: pending,
            ids_by_ref: maybe_delete(registry.ids_by_ref, entry.request_ref),
            ids_by_monitor: maybe_delete(registry.ids_by_monitor, entry.caller_monitor)
        }

        {entry, updated}
    end
  end

  @doc "Tracks a bounded canceled-request tombstone timer."
  @spec put_canceled(t(), integer(), reference()) :: t()
  def put_canceled(%__MODULE__{} = registry, id, timer) do
    %{registry | canceled_ids: Map.put(registry.canceled_ids, id, timer)}
  end

  @doc "Drops a canceled-request tombstone without returning it."
  @spec drop_canceled(t(), integer()) :: t()
  def drop_canceled(%__MODULE__{} = registry, id) do
    %{registry | canceled_ids: Map.delete(registry.canceled_ids, id)}
  end

  @doc "Pops a canceled-request tombstone timer."
  @spec pop_canceled(t(), integer()) :: {reference() | nil, t()}
  def pop_canceled(%__MODULE__{} = registry, id) do
    {timer, canceled_ids} = Map.pop(registry.canceled_ids, id)
    {timer, %{registry | canceled_ids: canceled_ids}}
  end

  @spec maybe_put(map(), reference() | nil, integer()) :: map()
  defp maybe_put(index, nil, _id), do: index
  defp maybe_put(index, key, id), do: Map.put(index, key, id)

  @spec maybe_delete(map(), reference() | nil) :: map()
  defp maybe_delete(index, nil), do: index
  defp maybe_delete(index, key), do: Map.delete(index, key)
end
