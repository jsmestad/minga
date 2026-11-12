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
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @fetch_page_bytes 64 * 1_024

  @type delivery :: MingaAgent.ModelSelection.image_tool_result_delivery()
  @type error_reason :: {:artifact_integrity_error, term()}

  @doc "Reports whether one durable message contains retained tool-result image attachments."
  @spec required?(Message.t()) :: boolean()
  def required?(%Message{role: :tool, metadata: %{output: %Output{attachments: [_ | _]}}}),
    do: true

  def required?(%Message{}), do: false

  @doc "Hydrates one transient message for the exact route without changing its durable value."
  @spec hydrate(Message.t(), ArtifactStore.server() | nil, delivery()) ::
          {:ok, Message.t()} | {:error, error_reason()}
  def hydrate(
        %Message{role: :tool, metadata: %{output: %Output{attachments: [_ | _]}}} = message,
        _store,
        {:unsupported, reason}
      ),
      do: {:ok, project_unsupported_message(message, reason)}

  def hydrate(
        %Message{role: :tool, metadata: %{output: %Output{attachments: [_ | _]}}},
        nil,
        :supported
      ),
      do: {:error, {:artifact_integrity_error, :retention_unavailable}}

  def hydrate(
        %Message{role: :tool, metadata: %{output: %Output{attachments: [_ | _]}}} = message,
        store,
        :supported
      ),
      do: hydrate_message(message, store)

  def hydrate(%Message{} = message, _store, _delivery), do: {:ok, message}

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

    %{message | content: content, metadata: metadata}
  end

  @spec limitation(Attachment.t(), :model_image_input | :tool_result_transport) :: Limitation.t()
  defp limitation(%Attachment{} = attachment, reason) do
    Limitation.image_delivery(reason, attachment.filename, attachment.media_type)
  end

  @spec hydrate_message(Message.t(), ArtifactStore.server()) ::
          {:ok, Message.t()} | {:error, error_reason()}
  defp hydrate_message(
         %Message{role: :tool, metadata: %{output: %Output{attachments: attachments}}} = message,
         store
       ) do
    with {:ok, parts} <- hydrate_attachments(attachments, store, []) do
      content = normalize_content(message.content) ++ parts

      {:ok, %{message | content: content}}
    end
  end

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
