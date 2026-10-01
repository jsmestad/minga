defmodule MingaAgent.ArtifactStore.ActiveCapture do
  @moduledoc "Open file handles and counters owned by ArtifactStore for one capture."

  alias MingaAgent.ArtifactStorage.Files
  alias MingaAgent.ArtifactStore.Integrity

  @type t :: %__MODULE__{
          id: String.t(),
          media_type: String.t(),
          mode: :bytes | :items,
          data_io: Files.io_device(),
          index_io: Files.io_device(),
          owner_pid: pid(),
          monitor: reference(),
          bytes: non_neg_integer(),
          items: non_neg_integer(),
          charged_bytes: non_neg_integer(),
          charged_items: non_neg_integer(),
          reserved_data: non_neg_integer(),
          marked: atom() | nil,
          integrity: Integrity.t()
        }

  @enforce_keys [
    :id,
    :media_type,
    :mode,
    :data_io,
    :index_io,
    :owner_pid,
    :monitor,
    :bytes,
    :items,
    :charged_bytes,
    :charged_items,
    :reserved_data,
    :integrity
  ]
  defstruct @enforce_keys ++ [marked: nil]

  @doc "Builds an active capture after both admitted files exist."
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs), do: struct!(__MODULE__, attrs)

  @doc "Records a fully successful append and advances its rolling integrity facts."
  @spec record_append(t(), binary(), binary(), non_neg_integer(), non_neg_integer()) :: t()
  def record_append(%__MODULE__{} = active, payload, encoded_offsets, newly_charged, items) do
    %__MODULE__{
      active
      | bytes: active.bytes + byte_size(payload),
        items: active.items + items,
        charged_bytes: active.charged_bytes + newly_charged,
        charged_items: active.charged_items + items,
        integrity: Integrity.record_append(active.integrity, payload, encoded_offsets)
    }
  end

  @doc "Records quota reserved for an append that did not fully reach both files."
  @spec reserve(t(), non_neg_integer(), non_neg_integer()) :: t()
  def reserve(%__MODULE__{} = active, newly_charged, charged_items) do
    %__MODULE__{
      active
      | charged_bytes: active.charged_bytes + newly_charged,
        charged_items: active.charged_items + charged_items
    }
  end


  @doc "Returns sealed full blocks awaiting their progress mutation."
  @spec pending_integrity_rows(t()) :: [Integrity.block_row()]
  def pending_integrity_rows(%__MODULE__{} = active),
    do: Integrity.pending_rows(active.integrity)
  @doc "Clears sealed rows after their progress checkpoint is acknowledged."
  @spec commit_integrity_rows(t()) :: t()
  def commit_integrity_rows(%__MODULE__{} = active),
    do: %__MODULE__{active | integrity: Integrity.commit_rows(active.integrity)}

  @doc "Requires bounded disk rebuilding before this capture can become terminal."
  @spec mark_integrity_rebuild(t()) :: t()
  def mark_integrity_rebuild(%__MODULE__{} = active),
    do: %__MODULE__{active | integrity: Integrity.mark_rebuild(active.integrity)}

  @doc "Returns whether the capture needs its canonical disk prefix rebuilt."
  @spec integrity_rebuild?(t()) :: boolean()
  def integrity_rebuild?(%__MODULE__{} = active), do: Integrity.rebuild?(active.integrity)

  @doc "Seals clean rolling integrity without reading the payload again."
  @spec seal_integrity(t()) :: Integrity.seal_result()
  def seal_integrity(%__MODULE__{} = active), do: Integrity.seal(active.integrity)

  @doc "Marks a terminal incomplete reason after an append refusal."
  @spec mark(t(), atom()) :: t()
  def mark(%__MODULE__{} = active, reason), do: %__MODULE__{active | marked: reason}

  @doc "Closes both handles and demonitor its owner."
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = active) do
    Process.demonitor(active.monitor, [:flush])
    Files.close(active.data_io)
    Files.close(active.index_io)
    :ok
  end

  @doc "Closes both handles after or while consuming the owner's matching monitor."
  @spec close_after_down(t()) :: :ok
  def close_after_down(%__MODULE__{} = active) do
    Process.demonitor(active.monitor, [:flush])
    Files.close(active.data_io)
    Files.close(active.index_io)
    :ok
  end
end
