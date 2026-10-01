defmodule MingaAgent.Tools.FetchOutput do
  @moduledoc """
  Fetches one bounded byte or item page from an immutable retained output.

  The reference is resolved only by the record-scoped artifact owner. This
  tool never replays the source tool or reads the original source.
  """

  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tools.OutputLimit

  @max_bytes 51_200
  @max_items 100

  @doc "Fetches the requested retained range through the supplied tool context."
  @spec execute(Context.t(), map()) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  def execute(%Context{} = context, args) when is_map(args) do
    with {:ok, reference} <- reference(args["reference"]),
         :ok <- validate_media_type(reference),
         {:ok, range} <- range(reference, args),
         {:ok, fetched} <- Context.fetch_output(context, reference, range),
         :ok <- validate_text(fetched.bytes),
         {:ok, output} <- output(fetched) do
      Output.result(output)
    end
  end

  @spec reference(term()) :: {:ok, Reference.t()} | {:error, :invalid_reference}
  defp reference(reference) when is_map(reference) do
    Reference.new(
      token: reference["token"],
      media_type: reference["media_type"],
      bytes: reference["bytes"],
      items: reference["items"],
      sha256: reference["sha256"]
    )
  end

  defp reference(_reference), do: {:error, :invalid_reference}

  @spec range(Reference.t(), map()) :: {:ok, Range.t()} | {:error, :invalid_range}
  defp range(%Reference{} = reference, args) do
    unit = unit(args["unit"])
    start = args["start"] || 0
    count = args["count"]
    build_range(reference, unit, start, count)
  end

  @spec build_range(Reference.t(), :bytes | :items | :invalid, term(), term()) ::
          {:ok, Range.t()} | {:error, :invalid_range}
  defp build_range(%Reference{bytes: total}, :bytes, start, count)
       when is_integer(start) and start >= 0 and is_integer(count) and count >= 0 and
              count <= @max_bytes do
    Range.new(:page, :bytes, start, count, total)
  end

  defp build_range(%Reference{items: total}, :items, start, count)
       when is_integer(total) and is_integer(start) and start >= 0 and is_integer(count) and
              count >= 0 and count <= @max_items do
    Range.new(:page, :items, start, count, total)
  end

  defp build_range(_reference, _unit, _start, _count), do: {:error, :invalid_range}

  @spec unit(term()) :: :bytes | :items | :invalid
  defp unit("bytes"), do: :bytes
  defp unit("items"), do: :items
  defp unit(_unit), do: :invalid

  @spec validate_media_type(Reference.t()) :: :ok | {:error, :unsupported_binary_output}
  defp validate_media_type(%Reference{media_type: "image/" <> _format}),
    do: {:error, :unsupported_binary_output}

  defp validate_media_type(%Reference{}), do: :ok

  @spec validate_text(binary()) :: :ok | {:error, :unsupported_binary_output}
  defp validate_text(bytes) do
    if String.valid?(bytes), do: :ok, else: {:error, :unsupported_binary_output}
  end

  @spec output(term()) :: {:ok, Output.t()} | {:error, :invalid_output}
  defp output(fetched) do
    view = OutputLimit.utf8_prefix(fetched.bytes, @max_bytes)

    presentation =
      if byte_size(view) == byte_size(fetched.bytes),
        do: :complete,
        else: {:truncated, byte_size(fetched.bytes) - byte_size(view)}

    Output.new(view, fetched.capture, fetched.selection,
      reference: fetched.reference,
      presentation: presentation
    )
  end
end
