defmodule MingaAgent.Providers.Native.OutputHydration do
  @moduledoc """
  Projects retained tool-result images into one transient ReqLLM request.

  Durable messages retain only attachment references. Supported exact routes
  receive canonical tool-result messages with hydrated image parts; unsupported
  restored history receives explicit limitation text without fetching bytes.
  """

  alias MingaAgent.ArtifactStore
  alias MingaAgent.Tool.Limitation
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Attachment
  alias MingaAgent.Tool.Output.Range
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @fetch_page_bytes 64 * 1_024

  @type delivery :: MingaAgent.ModelSelection.image_tool_result_delivery()
  @type error_reason :: {:artifact_integrity_error, term()}

  @doc "Reports whether durable messages contain retained tool-result image attachments."
  @spec required?([Message.t()]) :: boolean()
  def required?(messages) when is_list(messages), do: attachments?(messages)

  @doc "Builds the transient outbound message list for one exact delivery decision."
  @spec hydrate([Message.t()], ArtifactStore.server() | nil, delivery()) ::
          {:ok, [Message.t()]} | {:error, error_reason()}
  def hydrate(messages, store, delivery) when is_list(messages) do
    hydrate_required(required?(messages), messages, store, delivery)
  end

  @spec hydrate_required(boolean(), [Message.t()], ArtifactStore.server() | nil, delivery()) ::
          {:ok, [Message.t()]} | {:error, error_reason()}
  defp hydrate_required(false, messages, _store, _delivery), do: {:ok, messages}

  defp hydrate_required(true, messages, _store, {:unsupported, reason}) do
    {:ok, Enum.map(messages, &project_unsupported_message(&1, reason))}
  end

  defp hydrate_required(true, _messages, nil, :supported),
    do: {:error, {:artifact_integrity_error, :retention_unavailable}}

  defp hydrate_required(true, messages, store, :supported),
    do: hydrate_messages(messages, store, [])

  @spec attachments?([Message.t()]) :: boolean()
  defp attachments?(messages) do
    Enum.any?(messages, fn
      %Message{role: :tool, metadata: %{output: %Output{attachments: [_ | _]}}} -> true
      _message -> false
    end)
  end

  @spec project_unsupported_message(
          Message.t(),
          :model_image_input | :tool_result_transport
        ) :: Message.t()
  defp project_unsupported_message(
         %Message{
           role: :tool,
           metadata: %{output: %Output{attachments: [_ | _] = attachments}}
         } = message,
         reason
       ) do
    limitations =
      Enum.map_join(attachments, "\n", fn attachment ->
        attachment
        |> limitation(reason)
        |> Limitation.message()
      end)

    content = normalize_content(message.content) ++ [ContentPart.text(limitations)]

    metadata =
      message.metadata
      |> Map.put(:is_error, true)
      |> Map.put(:image_tool_result_delivery, {:unsupported, reason})

    Context.tool_result_message(message.name, message.tool_call_id, content, metadata)
  end

  defp project_unsupported_message(%Message{} = message, _reason), do: message

  @spec limitation(Attachment.t(), :model_image_input | :tool_result_transport) :: Limitation.t()
  defp limitation(%Attachment{} = attachment, reason) do
    Limitation.image_delivery(reason, attachment.filename, attachment.media_type)
  end

  @spec hydrate_messages([Message.t()], ArtifactStore.server(), [Message.t()]) ::
          {:ok, [Message.t()]} | {:error, error_reason()}
  defp hydrate_messages([], _store, hydrated), do: {:ok, Enum.reverse(hydrated)}

  defp hydrate_messages([message | rest], store, hydrated) do
    case hydrate_message(message, store) do
      {:ok, hydrated_message} -> hydrate_messages(rest, store, [hydrated_message | hydrated])
      {:error, reason} -> {:error, reason}
    end
  end

  @spec hydrate_message(Message.t(), ArtifactStore.server()) ::
          {:ok, Message.t()} | {:error, error_reason()}
  defp hydrate_message(
         %Message{role: :tool, metadata: %{output: %Output{attachments: attachments}}} = message,
         store
       ) do
    with {:ok, parts} <- hydrate_attachments(attachments, store, []) do
      content = normalize_content(message.content) ++ parts

      {:ok,
       Context.tool_result_message(
         message.name,
         message.tool_call_id,
         content,
         message.metadata
       )}
    end
  end

  defp hydrate_message(%Message{} = message, _store), do: {:ok, message}

  @spec hydrate_attachments([Attachment.t()], ArtifactStore.server(), [ContentPart.t()]) ::
          {:ok, [ContentPart.t()]} | {:error, error_reason()}
  defp hydrate_attachments([], _store, parts), do: {:ok, Enum.reverse(parts)}

  defp hydrate_attachments([attachment | rest], store, parts) do
    case hydrate_attachment(attachment, store) do
      {:ok, part} -> hydrate_attachments(rest, store, [part | parts])
      {:error, reason} -> {:error, reason}
    end
  end

  @spec hydrate_attachment(Attachment.t(), ArtifactStore.server()) ::
          {:ok, ContentPart.t()} | {:error, error_reason()}
  defp hydrate_attachment(%Attachment{} = attachment, store) do
    with {:ok, bytes} <- fetch_attachment(store, attachment.reference, 0, []) do
      metadata = %{filename: attachment.filename}
      {:ok, ContentPart.image(bytes, attachment.media_type, metadata)}
    end
  end

  @spec fetch_attachment(
          ArtifactStore.server(),
          MingaAgent.Tool.Output.Reference.t(),
          non_neg_integer(),
          [binary()]
        ) :: {:ok, binary()} | {:error, error_reason()}
  defp fetch_attachment(_store, reference, offset, pages) when offset == reference.bytes do
    {:ok, pages |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp fetch_attachment(store, reference, offset, pages) when offset < reference.bytes do
    count = min(@fetch_page_bytes, reference.bytes - offset)
    {:ok, range} = Range.new(:page, :bytes, offset, count, reference.bytes)

    case ArtifactStore.fetch(store, reference, range) do
      {:ok, fetched} when byte_size(fetched.bytes) == count ->
        fetch_attachment(store, reference, offset + count, [fetched.bytes | pages])

      {:ok, _fetched} ->
        {:error, {:artifact_integrity_error, :unexpected_page_size}}

      {:error, reason} ->
        {:error, {:artifact_integrity_error, reason}}
    end
  end

  @spec normalize_content(term()) :: [ContentPart.t()]
  defp normalize_content(content) when is_list(content), do: content
  defp normalize_content(content) when is_binary(content), do: [ContentPart.text(content)]
  defp normalize_content(_content), do: []
end
