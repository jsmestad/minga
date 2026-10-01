defmodule MingaAgent.Tool.Output.Codec do
  @moduledoc "Versioned JSON-safe persistence for tool output facts and references, never captured blob bytes."

  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Attachment
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tool.Output.Revision

  @type decode_error :: :invalid_output | :unsupported_output_version

  @doc "Encodes the public output contract without provider objects or artifact filesystem paths."
  @spec encode(Output.t()) :: map()
  def encode(%Output{} = output) do
    %{
      "output_version" => 1,
      "view" => output.view,
      "capture" => encode_capture(output.capture),
      "selection" => encode_range(output.selection),
      "presentation" => encode_presentation(output.presentation),
      "reference" => encode_reference(output.reference),
      "revision" => encode_revision(output.revision),
      "attachments" => Enum.map(output.attachments, &encode_attachment/1)
    }
  end

  @doc "Decodes through the owning constructors, rejecting unknown versions and invalid tagged states."
  @spec decode(term()) :: {:ok, Output.t()} | {:error, decode_error()}
  def decode(%{"output_version" => 1, "view" => view} = encoded) do
    with {:ok, capture} <- decode_capture(encoded["capture"]),
         {:ok, selection} <- decode_range(encoded["selection"]),
         {:ok, presentation} <- decode_presentation(encoded["presentation"]),
         {:ok, reference} <- decode_reference(encoded["reference"]),
         {:ok, revision} <- decode_revision(encoded["revision"]),
         {:ok, attachments} <- decode_attachments(encoded["attachments"]),
         {:ok, output} <-
           Output.new(view, capture, selection,
             presentation: presentation,
             reference: reference,
             revision: revision,
             attachments: attachments
           ) do
      {:ok, output}
    else
      _ -> {:error, :invalid_output}
    end
  end

  def decode(%{"output_version" => version}) when version != 1,
    do: {:error, :unsupported_output_version}

  def decode(_), do: {:error, :invalid_output}

  @spec encode_capture(Output.capture_status()) :: map()
  defp encode_capture(:complete), do: %{"status" => "complete"}

  defp encode_capture({:incomplete, reason}),
    do: %{"status" => "incomplete", "reason" => Atom.to_string(reason)}

  @spec encode_presentation(Output.presentation_status()) :: map()
  defp encode_presentation(:complete), do: %{"status" => "complete"}

  defp encode_presentation({:truncated, bytes}),
    do: %{"status" => "truncated", "omitted_bytes" => encode_total(bytes)}

  @spec encode_total(Range.total()) :: non_neg_integer() | String.t()
  defp encode_total(:unknown), do: "unknown"
  defp encode_total(value), do: value

  @spec encode_range(Range.t()) :: map()
  defp encode_range(%Range{} = range) do
    %{
      "kind" => Atom.to_string(range.kind),
      "unit" => Atom.to_string(range.unit),
      "start" => range.start,
      "count" => range.count,
      "total" => encode_total(range.total)
    }
  end

  @spec encode_reference(Reference.t() | nil) :: map() | nil
  defp encode_reference(nil), do: nil

  defp encode_reference(%Reference{} = reference) do
    %{
      "token" => reference.token,
      "media_type" => reference.media_type,
      "bytes" => reference.bytes,
      "items" => reference.items,
      "sha256" => reference.sha256
    }
  end

  @spec encode_revision(Revision.t() | nil) :: map() | nil
  defp encode_revision(nil), do: nil

  defp encode_revision(%Revision{} = revision) do
    %{
      "source_kind" => Atom.to_string(revision.source_kind),
      "source_id" => revision.source_id,
      "scope" => encode_range(revision.scope),
      "generation" => revision.generation,
      "sha256" => revision.sha256
    }
  end

  @spec encode_attachment(Attachment.t()) :: map()
  defp encode_attachment(%Attachment{} = attachment) do
    %{
      "kind" => "image",
      "reference" => encode_reference(attachment.reference),
      "media_type" => attachment.media_type,
      "filename" => attachment.filename
    }
  end

  @spec decode_capture(term()) :: {:ok, Output.capture_status()} | {:error, :invalid_output}
  defp decode_capture(%{"status" => "complete"}), do: {:ok, :complete}

  defp decode_capture(%{"status" => "incomplete", "reason" => reason}) do
    with {:ok, reason} <- existing_tag(reason), do: {:ok, {:incomplete, reason}}
  end

  defp decode_capture(_), do: {:error, :invalid_output}

  @spec decode_presentation(term()) ::
          {:ok, Output.presentation_status()} | {:error, :invalid_output}
  defp decode_presentation(%{"status" => "complete"}), do: {:ok, :complete}

  defp decode_presentation(%{"status" => "truncated", "omitted_bytes" => bytes}),
    do: {:ok, {:truncated, decode_total(bytes)}}

  defp decode_presentation(_), do: {:error, :invalid_output}

  @spec decode_total(term()) :: term()
  defp decode_total("unknown"), do: :unknown
  defp decode_total(value), do: value

  @spec decode_range(term()) :: {:ok, Range.t()} | {:error, term()}
  defp decode_range(%{
         "kind" => kind,
         "unit" => unit,
         "start" => start,
         "count" => count,
         "total" => total
       }) do
    with {:ok, kind} <- existing_tag(kind), {:ok, unit} <- existing_tag(unit) do
      Range.new(kind, unit, start, count, decode_total(total))
    end
  end

  defp decode_range(_), do: {:error, :invalid_output}

  @spec decode_reference(term()) :: {:ok, Reference.t() | nil} | {:error, term()}
  defp decode_reference(nil), do: {:ok, nil}

  defp decode_reference(
         %{"token" => token, "media_type" => media_type, "bytes" => bytes, "sha256" => digest} =
           encoded
       ) do
    Reference.new(
      token: token,
      media_type: media_type,
      bytes: bytes,
      items: encoded["items"],
      sha256: digest
    )
  end

  defp decode_reference(_), do: {:error, :invalid_output}

  @spec decode_revision(term()) :: {:ok, Revision.t() | nil} | {:error, term()}
  defp decode_revision(nil), do: {:ok, nil}

  defp decode_revision(
         %{"source_kind" => kind, "source_id" => id, "scope" => scope, "sha256" => digest} =
           encoded
       ) do
    with {:ok, kind} <- existing_tag(kind), {:ok, scope} <- decode_range(scope) do
      Revision.new(
        source_kind: kind,
        source_id: id,
        scope: scope,
        sha256: digest,
        generation: encoded["generation"]
      )
    end
  end

  defp decode_revision(_), do: {:error, :invalid_output}

  @spec decode_attachments(term()) :: {:ok, [Attachment.t()]} | {:error, term()}
  defp decode_attachments(attachments) when is_list(attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, acc} ->
      case decode_attachment(attachment) do
        {:ok, attachment} -> {:cont, {:ok, [attachment | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> restore_order()
  end

  defp decode_attachments(_), do: {:error, :invalid_output}

  @spec restore_order({:ok, [Attachment.t()]} | {:error, term()}) ::
          {:ok, [Attachment.t()]} | {:error, term()}
  defp restore_order({:ok, reversed}), do: {:ok, Enum.reverse(reversed)}
  defp restore_order({:error, _} = error), do: error

  @spec decode_attachment(term()) :: {:ok, Attachment.t()} | {:error, term()}
  defp decode_attachment(%{
         "kind" => "image",
         "reference" => encoded,
         "media_type" => media_type,
         "filename" => filename
       }) do
    case decode_reference(encoded) do
      {:ok, %Reference{media_type: ^media_type} = reference} ->
        Attachment.image(reference, filename)

      _other ->
        {:error, :invalid_output}
    end
  end

  defp decode_attachment(_), do: {:error, :invalid_output}

  @spec existing_tag(term()) :: {:ok, atom()} | {:error, :invalid_output}
  defp existing_tag(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, :invalid_output}
  end

  defp existing_tag(_), do: {:error, :invalid_output}
end
