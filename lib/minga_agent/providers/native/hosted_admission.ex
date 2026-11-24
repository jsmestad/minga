defmodule MingaAgent.Providers.Native.HostedAdmission do
  @moduledoc """
  Admission gate for hosted-route requests (OpenAI, Anthropic, Codex via ReqLLM).

  JSON-encodes the messages and tool declarations, computes a byte-based
  upper-bound token count, assesses capacity against the policy limits, and
  delegates the admit/refuse decision to a caller-supplied authorize callback.
  The gate runs synchronously before the streaming request is dispatched.

  Images are not measured by their encoded bytes on routes whose provider
  documents a per-image maximum: each image counts that maximum instead.
  Other providers keep the byte measure.
  """

  alias MingaAgent.ModelSelection.Policy.Limits
  alias MingaAgent.ModelSelection.Policy.RequestCapacity
  alias MingaAgent.ModelSelection.Route
  alias ReqLLM.Message.ContentPart

  # Documented per-image maxima after the provider's own resizing.
  # Anthropic: 4,784 visual tokens on the high-resolution tier (1,568 standard),
  #   https://platform.claude.com/docs/en/build-with-claude/vision
  # OpenAI: the largest documented family maximum, gpt-4o-mini's 2,833 + 5,667 x 8 tiles,
  #   https://developers.openai.com/api/docs/guides/images-vision
  @image_token_bounds %{anthropic: 4_784, openai: 48_169}

  @typedoc "An authorize callback that receives the body digest and capacity evidence."
  @type authorize_fn :: (digest :: binary(), RequestCapacity.t() -> :ok | {:error, term()})

  @doc """
  Assesses a hosted-route request and delegates the admit/refuse decision.

  Converts messages to plain maps and serializes to JSON, computes an
  upper-bound token estimate from the byte count, and calls `authorize` with the
  body digest and capacity evidence. Returns `:ok` on admission or
  `{:error, {:request_admission_refused, reason}}` on refusal.
  """
  @spec assess(
          Limits.t(),
          pos_integer(),
          [term()],
          [ReqLLM.Tool.t()],
          Route.request_provider(),
          authorize_fn()
        ) :: :ok | {:error, {:request_admission_refused, term()}}
  def assess(%Limits{} = limits, output_tokens, messages, tools, provider, authorize)
      when is_integer(output_tokens) and output_tokens > 0 and is_list(tools) and
             is_function(authorize, 2) do
    tool_schemas = Enum.map(tools, &ReqLLM.Tool.to_schema(&1, schema_format(provider)))
    digest = :crypto.hash(:sha256, encode(messages, tool_schemas))
    tokens = measured_tokens(messages, tool_schemas, Map.get(@image_token_bounds, provider))
    evidence = RequestCapacity.assess(limits, {:upper_bound, tokens}, {:encoded, output_tokens})

    case authorize.(digest, evidence) do
      :ok -> :ok
      {:error, reason} -> {:error, {:request_admission_refused, reason}}
    end
  end

  @doc """
  Returns a conservative upper-bound token count derived from an encoded body.

  Every token in a JSON-encoded LLM request body occupies at least 2 bytes: even
  the shortest representable token (a single ASCII character) is surrounded by
  JSON structural bytes (quotes, brackets, commas, colons). A one-character
  string token like `"a"` takes 3+ bytes; a one-character key takes 4+ bytes
  (key, colon, value separator). The practical minimum is therefore 2 bytes per
  token, making `ceil(byte_size / 2)` a proven upper bound for any
  JSON-serialized payload.

  This bound is intentionally conservative. It overestimates real token counts,
  which is correct for admission gating: a request that fits the upper bound
  definitely fits, and a request refused by the upper bound might fit but erring
  on the side of refusal is safe.
  """
  @spec upper_bound_tokens(binary()) :: non_neg_integer()
  def upper_bound_tokens(body) when is_binary(body) do
    ceil(byte_size(body) / 2)
  end

  @spec encode([term()], [map()]) :: binary()
  defp encode(messages, tool_schemas) do
    JSON.encode!(%{messages: Enum.map(messages, &to_encodable/1), tools: tool_schemas})
  end

  # With a documented per-image bound, images are measured as that bound instead of their bytes.
  @spec measured_tokens([term()], [map()], pos_integer() | nil) :: non_neg_integer()
  defp measured_tokens(messages, tool_schemas, nil),
    do: upper_bound_tokens(encode(messages, tool_schemas))

  defp measured_tokens(messages, tool_schemas, image_bound) do
    {messages, images} = Enum.map_reduce(messages, 0, &strip_images/2)
    upper_bound_tokens(encode(messages, tool_schemas)) + images * image_bound
  end

  @spec strip_images(term(), non_neg_integer()) :: {term(), non_neg_integer()}
  defp strip_images(%ReqLLM.Message{content: parts} = message, count) when is_list(parts) do
    {parts, count} =
      Enum.map_reduce(parts, count, fn
        %ContentPart{type: type} = part, n when type in [:image, :image_url] ->
          {%{part | data: nil, url: nil}, n + 1}

        part, n ->
          {part, n}
      end)

    {%{message | content: parts}, count}
  end

  defp strip_images(message, count), do: {message, count}

  @spec schema_format(Route.request_provider()) :: :anthropic | :google | :openai
  defp schema_format(provider) when provider in [:anthropic, :google], do: provider
  defp schema_format(_provider), do: :openai

  @spec to_encodable(term()) :: term()
  defp to_encodable(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> to_encodable()
  defp to_encodable(%{} = map), do: Map.new(map, fn {k, v} -> {k, to_encodable(v)} end)
  defp to_encodable(list) when is_list(list), do: Enum.map(list, &to_encodable/1)

  defp to_encodable(bin) when is_binary(bin) do
    if String.valid?(bin), do: bin, else: Base.encode64(bin)
  end

  defp to_encodable(other), do: other
end
