defmodule MingaAgent.ArtifactStore.Integrity do
  @moduledoc "Pure rolling payload and fixed-block integrity state for one open capture."

  alias MingaAgent.ArtifactStore.Limits

  @type file_kind :: :blob | :index
  @type block_row :: {file_kind(), non_neg_integer(), binary()}
  @type seal_result :: {:ok, String.t(), [block_row()]} | {:error, :rebuild_required}

  @opaque t :: %__MODULE__{
            payload_context: term(),
            blob_context: term(),
            blob_bytes: non_neg_integer(),
            blob_number: non_neg_integer(),
            index_context: term(),
            index_bytes: non_neg_integer(),
            index_number: non_neg_integer(),
            pending: [block_row()],
            rebuild: boolean()
          }

  @enforce_keys [
    :payload_context,
    :blob_context,
    :blob_bytes,
    :blob_number,
    :index_context,
    :index_bytes,
    :index_number,
    :pending,
    :rebuild
  ]
  defstruct @enforce_keys

  @doc "Starts clean rolling integrity state for an empty capture."
  @spec new() :: t()
  def new do
    %__MODULE__{
      payload_context: hash_init(),
      blob_context: hash_init(),
      blob_bytes: 0,
      blob_number: 0,
      index_context: hash_init(),
      index_bytes: 0,
      index_number: 0,
      pending: [],
      rebuild: false
    }
  end

  @doc "Records bytes only after both append writes completed successfully."
  @spec record_append(t(), binary(), binary()) :: t()
  def record_append(%__MODULE__{rebuild: false} = integrity, payload, encoded_offsets)
      when is_binary(payload) and is_binary(encoded_offsets) do
    payload_context = :crypto.hash_update(integrity.payload_context, payload)

    {blob_context, blob_bytes, blob_number, pending} =
      feed_blocks(
        :blob,
        integrity.blob_context,
        integrity.blob_bytes,
        integrity.blob_number,
        integrity.pending,
        payload
      )

    {index_context, index_bytes, index_number, pending} =
      feed_blocks(
        :index,
        integrity.index_context,
        integrity.index_bytes,
        integrity.index_number,
        pending,
        encoded_offsets
      )

    %__MODULE__{
      integrity
      | payload_context: payload_context,
        blob_context: blob_context,
        blob_bytes: blob_bytes,
        blob_number: blob_number,
        index_context: index_context,
        index_bytes: index_bytes,
        index_number: index_number,
        pending: pending
    }
  end

  def record_append(%__MODULE__{rebuild: true} = integrity, _payload, _encoded_offsets),
    do: integrity

  @doc "Returns full blocks awaiting the matching durable progress mutation."
  @spec pending_rows(t()) :: [block_row()]
  def pending_rows(%__MODULE__{pending: pending}), do: Enum.reverse(pending)

  @doc "Clears rows only after progress and its checkpoint are acknowledged."
  @spec commit_rows(t()) :: t()
  def commit_rows(%__MODULE__{} = integrity), do: %__MODULE__{integrity | pending: []}

  @doc "Forces the one-pass disk rebuild path after an ambiguous write or metadata outcome."
  @spec mark_rebuild(t()) :: t()
  def mark_rebuild(%__MODULE__{} = integrity), do: %__MODULE__{integrity | rebuild: true}

  @doc "Reports whether terminal facts must be rebuilt from the canonical disk prefix."
  @spec rebuild?(t()) :: boolean()
  def rebuild?(%__MODULE__{rebuild: rebuild}), do: rebuild

  @doc "Finalizes the whole payload digest and any nonempty partial block rows."
  @spec seal(t()) :: seal_result()
  def seal(%__MODULE__{rebuild: true}), do: {:error, :rebuild_required}

  def seal(%__MODULE__{} = integrity) do
    pending =
      integrity.pending
      |> seal_partial(:blob, integrity.blob_number, integrity.blob_bytes, integrity.blob_context)
      |> seal_partial(
        :index,
        integrity.index_number,
        integrity.index_bytes,
        integrity.index_context
      )
      |> Enum.reverse()

    digest = integrity.payload_context |> :crypto.hash_final() |> Base.encode16(case: :lower)
    {:ok, digest, pending}
  end

  @spec feed_blocks(
          file_kind(),
          term(),
          non_neg_integer(),
          non_neg_integer(),
          [block_row()],
          binary()
        ) :: {term(), non_neg_integer(), non_neg_integer(), [block_row()]}
  defp feed_blocks(_kind, context, bytes, number, pending, <<>>),
    do: {context, bytes, number, pending}

  defp feed_blocks(kind, context, bytes, number, pending, data) do
    available = Limits.integrity_block_bytes() - bytes
    take = min(available, byte_size(data))
    <<part::binary-size(^take), rest::binary>> = data
    next_context = :crypto.hash_update(context, part)
    next_bytes = bytes + take

    if next_bytes == Limits.integrity_block_bytes() do
      row = {kind, number, :crypto.hash_final(next_context)}
      feed_blocks(kind, hash_init(), 0, number + 1, [row | pending], rest)
    else
      feed_blocks(kind, next_context, next_bytes, number, pending, rest)
    end
  end

  @spec seal_partial([block_row()], file_kind(), non_neg_integer(), non_neg_integer(), term()) ::
          [block_row()]
  defp seal_partial(pending, _kind, _number, 0, _context), do: pending

  defp seal_partial(pending, kind, number, _bytes, context),
    do: [{kind, number, :crypto.hash_final(context)} | pending]

  @spec hash_init() :: term()
  defp hash_init, do: :crypto.hash_init(:sha256)
end
