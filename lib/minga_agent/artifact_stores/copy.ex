defmodule MingaAgent.ArtifactStores.Copy do
  @moduledoc """
  Performs bounded, quota-admitted copies between record-scoped stores.

  Source references are never reused in the target record. The target capture
  reserves its declared size before source bytes are fetched, and copying uses
  bounded pages so a fork does not materialize a retained blob in memory.
  """

  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStore.CaptureSpec
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Attachment
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference

  @chunk_bytes 65_536

  @type error_reason :: {:artifact_copy_failed, term()}
  @typep delivery_key :: {:delivery, String.t(), String.t()}
  @typep copy_context ::
           {ArtifactStore.server(), ArtifactStore.server(), Output.capture_status(), String.t(),
            tuple()}
  @typep copy_accumulator ::
           {:ok, %{String.t() => Reference.t()}, [Reference.t()], [delivery_key()]}

  @doc "Copies every reference reachable from an output and rewrites it for the target record."
  @spec output(
          ArtifactStore.server(),
          ArtifactStore.server(),
          Output.t(),
          String.t()
        ) :: {:ok, Output.t()} | {:error, error_reason()}
  def output(store, store, %Output{} = output, _copy_id), do: {:ok, output}

  def output(source, target, %Output{} = output, copy_id)
      when is_binary(copy_id) and byte_size(copy_id) > 0 do
    operation_key = operation_pin_key(copy_id)

    case copy_references(
           source,
           target,
           Output.references(output),
           output.capture,
           copy_id,
           operation_key
         ) do
      {:ok, references} ->
        :ok = release_operation_pin(target, operation_key)
        {:ok, rewrite_output(output, references)}

      {:error, reason, deliveries} ->
        cleanup_failed_operation(target, operation_key, deliveries)
        {:error, {:artifact_copy_failed, reason}}
    end
  end

  @spec copy_references(
          ArtifactStore.server(),
          ArtifactStore.server(),
          [Reference.t()],
          Output.capture_status(),
          String.t(),
          tuple()
        ) ::
          {:ok, %{String.t() => Reference.t()}}
          | {:error, term(), [delivery_key()]}
  defp copy_references(source, target, references, capture_status, copy_id, operation_key) do
    context = {source, target, capture_status, copy_id, operation_key}

    references
    |> Enum.uniq_by(& &1.token)
    |> Enum.reduce_while({:ok, %{}, [], []}, &copy_reference_step(context, &1, &2))
    |> case do
      {:ok, copied, _pinned, _deliveries} -> {:ok, copied}
      {:error, reason, deliveries} -> {:error, reason, deliveries}
    end
  end

  @spec copy_reference_step(copy_context(), Reference.t(), copy_accumulator()) ::
          {:cont, copy_accumulator()} | {:halt, {:error, term(), [delivery_key()]}}
  defp copy_reference_step(
         {source, target, capture_status, copy_id, operation_key},
         reference,
         {:ok, copied, pinned, deliveries}
       ) do
    case copy_reference(source, target, reference, capture_status, copy_id) do
      {:ok, target_reference, created_delivery} ->
        pin_copied_reference(
          target,
          operation_key,
          reference,
          target_reference,
          created_delivery,
          {:ok, copied, pinned, deliveries}
        )

      {:error, reason} ->
        {:halt, {:error, reason, deliveries}}
    end
  end

  @spec pin_copied_reference(
          ArtifactStore.server(),
          tuple(),
          Reference.t(),
          Reference.t(),
          delivery_key() | nil,
          copy_accumulator()
        ) :: {:cont, copy_accumulator()} | {:halt, {:error, term(), [delivery_key()]}}
  defp pin_copied_reference(
         target,
         operation_key,
         source_reference,
         target_reference,
         created_delivery,
         {:ok, copied, pinned, deliveries}
       ) do
    next_pinned = [target_reference | pinned]

    case ArtifactStore.pin(target, operation_key, next_pinned) do
      :ok ->
        next_deliveries = add_created_delivery(deliveries, created_delivery)

        {:cont,
         {:ok, Map.put(copied, source_reference.token, target_reference), next_pinned,
          next_deliveries}}

      {:error, reason} ->
        {:halt, {:error, reason, add_created_delivery(deliveries, created_delivery)}}
    end
  end

  @spec add_created_delivery([delivery_key()], delivery_key() | nil) :: [delivery_key()]
  defp add_created_delivery(deliveries, nil), do: deliveries
  defp add_created_delivery(deliveries, delivery), do: [delivery | deliveries]

  @spec copy_reference(
          ArtifactStore.server(),
          ArtifactStore.server(),
          Reference.t(),
          Output.capture_status(),
          String.t()
        ) :: {:ok, Reference.t(), delivery_key() | nil} | {:error, term()}
  defp copy_reference(source, target, reference, capture_status, copy_id) do
    delivery_key = copy_delivery_key(copy_id, reference)

    case ArtifactStore.lookup_delivery(target, delivery_key) do
      {:ok, stored} ->
        with {:ok, copied} <- verify_copied_reference(stored.reference, reference) do
          {:ok, copied, nil}
        end

      {:error, :unknown_delivery} ->
        copy_new_reference(source, target, reference, capture_status, delivery_key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec copy_new_reference(
          ArtifactStore.server(),
          ArtifactStore.server(),
          Reference.t(),
          Output.capture_status(),
          delivery_key()
        ) :: {:ok, Reference.t(), delivery_key()} | {:error, term()}
  defp copy_new_reference(source, target, reference, capture_status, delivery_key) do
    mode = if reference.items == nil, do: :bytes, else: :items

    with {:ok, spec} <-
           CaptureSpec.new(
             media_type: reference.media_type,
             mode: mode,
             expected_bytes: reference.bytes,
             owner_pid: self(),
             delivery_key: delivery_key
           ),
         {:ok, capture} <- ArtifactStore.begin(target, spec) do
      copy_started_reference(
        source,
        target,
        capture,
        reference,
        capture_status,
        delivery_key
      )
    end
  end

  @spec copy_started_reference(
          ArtifactStore.server(),
          ArtifactStore.server(),
          term(),
          Reference.t(),
          Output.capture_status(),
          delivery_key()
        ) :: {:ok, Reference.t(), delivery_key()} | {:error, term()}
  defp copy_started_reference(source, target, capture, reference, capture_status, delivery_key) do
    result =
      with :ok <- copy_content(source, target, capture, reference),
           {:ok, stored} <- ArtifactStore.finish(target, capture, capture_status),
           {:ok, copied} <- verify_copied_reference(stored.reference, reference) do
        {:ok, copied, delivery_key}
      end

    case result do
      {:ok, _copied, _delivery_key} = ok ->
        ok

      {:error, reason} ->
        cleanup_failed_capture(target, capture, delivery_key)
        {:error, reason}
    end
  end

  @spec cleanup_failed_capture(ArtifactStore.server(), term(), delivery_key()) :: :ok
  defp cleanup_failed_capture(target, capture, delivery_key) do
    case ArtifactStore.cancel(target, capture) do
      :ok -> :ok
      {:error, :capture_not_open} -> release_delivery_and_cleanup(target, delivery_key)
      {:error, _reason} -> :ok
    end
  end

  @spec copy_content(ArtifactStore.server(), ArtifactStore.server(), term(), Reference.t()) ::
          :ok | {:error, term()}
  defp copy_content(source, target, capture, %Reference{items: nil} = reference),
    do: copy_byte_pages(source, target, capture, reference, 0)

  defp copy_content(source, target, capture, %Reference{} = reference),
    do: copy_item_pages(source, target, capture, reference, 0)

  @spec copy_byte_pages(
          ArtifactStore.server(),
          ArtifactStore.server(),
          term(),
          Reference.t(),
          non_neg_integer()
        ) :: :ok | {:error, term()}
  defp copy_byte_pages(_source, _target, _capture, reference, offset)
       when offset == reference.bytes,
       do: :ok

  defp copy_byte_pages(source, target, capture, reference, offset) do
    count = min(@chunk_bytes, reference.bytes - offset)
    {:ok, range} = Range.new(:page, :bytes, offset, count, reference.bytes)

    with {:ok, fetched} <- ArtifactStore.fetch(source, reference, range),
         {:ok, _progress} <- ArtifactStore.append(target, capture, fetched.bytes, item_ends: []) do
      copy_byte_pages(source, target, capture, reference, offset + count)
    end
  end

  @spec copy_item_pages(
          ArtifactStore.server(),
          ArtifactStore.server(),
          term(),
          Reference.t(),
          non_neg_integer()
        ) :: :ok | {:error, term()}
  defp copy_item_pages(_source, _target, _capture, reference, index)
       when index == reference.items,
       do: :ok

  defp copy_item_pages(source, target, capture, reference, index) do
    {:ok, range} = Range.new(:page, :items, index, 1, reference.items)

    with {:ok, fetched} <- ArtifactStore.fetch(source, reference, range),
         {:ok, _progress} <-
           ArtifactStore.append(target, capture, fetched.bytes,
             item_ends: [byte_size(fetched.bytes)]
           ) do
      copy_item_pages(source, target, capture, reference, index + 1)
    end
  end

  @spec verify_copied_reference(Reference.t(), Reference.t()) ::
          {:ok, Reference.t()} | {:error, :copy_integrity_mismatch}
  defp verify_copied_reference(copied, source) do
    if copied.token != source.token and copied.media_type == source.media_type and
         copied.bytes == source.bytes and copied.items == source.items and
         copied.sha256 == source.sha256 do
      {:ok, copied}
    else
      {:error, :copy_integrity_mismatch}
    end
  end

  @spec cleanup_failed_operation(ArtifactStore.server(), tuple(), [delivery_key()]) :: :ok
  defp cleanup_failed_operation(target, operation_key, deliveries) do
    :ok = release_operation_pin(target, operation_key)
    Enum.each(deliveries, &release_delivery_and_cleanup(target, &1))
    _ = ArtifactStore.cleanup_unreferenced(target)
    :ok
  end

  @spec release_operation_pin(ArtifactStore.server(), tuple()) :: :ok
  defp release_operation_pin(target, operation_key) do
    case ArtifactStore.release(target, operation_key) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  @spec release_delivery_and_cleanup(ArtifactStore.server(), delivery_key()) :: :ok
  defp release_delivery_and_cleanup(target, delivery_key) do
    _ = ArtifactStore.release(target, delivery_key)
    _ = ArtifactStore.cleanup_unreferenced(target)
    :ok
  end

  @spec rewrite_output(Output.t(), %{String.t() => Reference.t()}) :: Output.t()
  defp rewrite_output(%Output{} = output, references) do
    rewritten_reference = rewrite_reference(output.reference, references)

    attachments =
      Enum.map(output.attachments, fn %Attachment{} = attachment ->
        %{attachment | reference: rewrite_reference(attachment.reference, references)}
      end)

    %{output | reference: rewritten_reference, attachments: attachments}
  end

  @spec rewrite_reference(Reference.t() | nil, %{String.t() => Reference.t()}) ::
          Reference.t() | nil
  defp rewrite_reference(nil, _references), do: nil
  defp rewrite_reference(%Reference{token: token}, references), do: Map.fetch!(references, token)

  @spec operation_pin_key(String.t()) :: {:task, String.t(), String.t()}
  defp operation_pin_key(copy_id), do: {:task, "artifact-copy", Reference.digest(copy_id)}

  @spec copy_delivery_key(String.t(), Reference.t()) :: delivery_key()
  defp copy_delivery_key(copy_id, reference) do
    operation = Reference.digest(copy_id)
    artifact = Reference.digest(reference.token)
    {:delivery, operation, artifact}
  end
end
