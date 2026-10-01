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
         {:ok, range} <- range(reference, args),
         {:ok, fetched} <- Context.fetch_output(context, reference, range),
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

  @spec output(term()) :: {:ok, Output.t()} | {:error, :invalid_output}
  defp output(fetched) do
    view = fetched_view(fetched.bytes, fetched.selection.unit, fetched.reference.media_type)

    Output.new(view, fetched.capture, fetched.selection,
      reference: fetched.reference,
      presentation: :complete
    )
  end

  @spec fetched_view(binary(), :bytes | :items, String.t()) :: String.t()
  defp fetched_view(bytes, :items, _media_type) when is_binary(bytes) do
    if String.valid?(bytes), do: bytes, else: base64_view(bytes)
  end

  defp fetched_view(bytes, :bytes, "text/" <> _subtype) when is_binary(bytes) do
    if String.valid?(bytes) and :binary.match(bytes, <<0>>) == :nomatch,
      do: OutputLimit.utf8_prefix(bytes, @max_bytes),
      else: base64_view(bytes)
  end

  defp fetched_view(bytes, :bytes, _media_type) when is_binary(bytes), do: base64_view(bytes)

  @spec base64_view(binary()) :: String.t()
  defp base64_view(bytes), do: "[base64; bytes=#{byte_size(bytes)}]\n" <> Base.encode64(bytes)
end
