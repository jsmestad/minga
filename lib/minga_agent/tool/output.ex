defmodule MingaAgent.Tool.Output do
  @moduledoc "Separates capture completeness, requested bounds, model-visible presentation, and durable captured bytes."

  alias MingaAgent.Tool.Output.Attachment
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tool.Output.Revision

  @incomplete_reasons [
    :capture_byte_limit,
    :session_disk_quota,
    :root_disk_quota,
    :session_item_quota,
    :root_item_quota,
    :disk_full,
    :interrupted,
    :source_changed,
    :legacy_unclassified,
    :timeout,
    :capture_failed
  ]

  @type incomplete_reason ::
          :capture_byte_limit
          | :session_disk_quota
          | :root_disk_quota
          | :session_item_quota
          | :root_item_quota
          | :disk_full
          | :interrupted
          | :source_changed
          | :legacy_unclassified
          | :timeout
          | :capture_failed
  @type capture_status :: :complete | {:incomplete, incomplete_reason()}
  @type presentation_status :: :complete | {:truncated, pos_integer() | :unknown}
  @type t :: %__MODULE__{
          view: String.t(),
          capture: capture_status(),
          selection: Range.t(),
          presentation: presentation_status(),
          reference: Reference.t() | nil,
          revision: Revision.t() | nil,
          attachments: [Attachment.t()]
        }

  @enforce_keys [:view, :capture, :selection, :presentation]
  defstruct [:view, :capture, :selection, :presentation, :reference, :revision, attachments: []]

  @doc "Constructs an output with explicit capture and presentation facts. Truncated presentation requires recoverable captured bytes."
  @spec new(String.t(), capture_status(), Range.t(), keyword()) ::
          {:ok, t()} | {:error, :invalid_output}
  def new(view, capture, selection, opts \\ [])

  def new(view, capture, %Range{} = selection, opts) when is_binary(view) and is_list(opts) do
    reference = Keyword.get(opts, :reference)
    revision = Keyword.get(opts, :revision)
    attachments = Keyword.get(opts, :attachments, [])
    presentation = Keyword.get(opts, :presentation, :complete)

    with true <- String.valid?(view),
         :ok <- validate_capture(capture, selection),
         :ok <- validate_presentation(presentation, reference),
         :ok <- validate_reference(reference),
         :ok <- validate_revision(revision),
         :ok <- validate_attachments(attachments) do
      {:ok,
       %__MODULE__{
         view: view,
         capture: capture,
         selection: selection,
         presentation: presentation,
         reference: reference,
         revision: revision,
         attachments: attachments
       }}
    else
      _ -> {:error, :invalid_output}
    end
  end

  def new(_, _, _, _), do: {:error, :invalid_output}

  @doc "An incomplete capture is a tool error even if its retained prefix can be fetched."
  @spec result(t()) :: {:ok, t()} | {:error, t()}
  def result(%__MODULE__{capture: :complete} = output), do: {:ok, output}
  def result(%__MODULE__{capture: {:incomplete, _}} = output), do: {:error, output}

  @doc "Returns each durable reference reachable from this output, including retained image bytes."
  @spec references(t()) :: [Reference.t()]
  def references(%__MODULE__{reference: reference, attachments: attachments}) do
    primary = if reference == nil, do: [], else: [reference]
    Enum.uniq_by(primary ++ Enum.map(attachments, & &1.reference), & &1.token)
  end

  @spec validate_capture(term(), Range.t()) :: :ok | {:error, :invalid_output}
  defp validate_capture(:complete, %Range{kind: kind}) when kind in [:full, :requested, :page],
    do: :ok

  defp validate_capture({:incomplete, reason}, %Range{kind: kind})
       when reason in @incomplete_reasons and kind in [:captured_prefix, :requested, :page],
       do: :ok

  defp validate_capture(_, _), do: {:error, :invalid_output}

  @spec validate_presentation(term(), term()) :: :ok | {:error, :invalid_output}
  defp validate_presentation(:complete, _), do: :ok
  defp validate_presentation({:truncated, :unknown}, %Reference{}), do: :ok

  defp validate_presentation({:truncated, bytes}, %Reference{})
       when is_integer(bytes) and bytes > 0, do: :ok

  defp validate_presentation(_, _), do: {:error, :invalid_output}

  @spec validate_reference(term()) :: :ok | {:error, :invalid_output}
  defp validate_reference(nil), do: :ok
  defp validate_reference(%Reference{}), do: :ok
  defp validate_reference(_), do: {:error, :invalid_output}

  @spec validate_revision(term()) :: :ok | {:error, :invalid_output}
  defp validate_revision(nil), do: :ok
  defp validate_revision(%Revision{}), do: :ok
  defp validate_revision(_), do: {:error, :invalid_output}

  @spec validate_attachments(term()) :: :ok | {:error, :invalid_output}
  defp validate_attachments(attachments) when is_list(attachments) do
    if Enum.all?(attachments, &match?(%Attachment{}, &1)),
      do: :ok,
      else: {:error, :invalid_output}
  end

  defp validate_attachments(_), do: {:error, :invalid_output}
end
