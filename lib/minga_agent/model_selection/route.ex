defmodule MingaAgent.ModelSelection.Route do
  @moduledoc "Persistable exact route authority for a text model."

  alias MingaAgent.ModelSelection.TextExecution

  @providers ~w(anthropic openai openai_codex google openrouter groq mistral deepseek ollama)a

  @enforce_keys [
    :origin,
    :request_provider,
    :id,
    :model_provider,
    :model_id,
    :display_name,
    :execution,
    :metadata
  ]
  defstruct @enforce_keys

  @type origin :: {:catalog, String.t(), String.t()} | {:custom, String.t(), String.t()}
  @type request_provider ::
          :anthropic
          | :openai
          | :openai_codex
          | :google
          | :openrouter
          | :groq
          | :mistral
          | :deepseek
          | :ollama
  @type t :: %__MODULE__{
          origin: origin(),
          request_provider: request_provider(),
          id: String.t(),
          model_provider: String.t(),
          model_id: String.t(),
          display_name: String.t(),
          execution: TextExecution.t(),
          metadata: map()
        }

  @doc "Builds a route using only installed, allowlisted request providers."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_route}
  def new(attrs) when is_map(attrs) do
    with origin when is_tuple(origin) <- Map.get(attrs, :origin),
         true <- valid_origin?(origin),
         provider when provider in @providers <- Map.get(attrs, :request_provider),
         id when is_binary(id) and id != "" <- Map.get(attrs, :id),
         model_provider when is_binary(model_provider) and model_provider != "" <-
           Map.get(attrs, :model_provider),
         model_id when is_binary(model_id) and model_id != "" <- Map.get(attrs, :model_id),
         true <- origin_matches_model?(origin, model_provider, model_id),
         display_name when is_binary(display_name) and display_name != "" <-
           Map.get(attrs, :display_name),
         %TextExecution{} = execution <- Map.get(attrs, :execution),
         true <- compatible?(provider, execution),
         metadata when is_map(metadata) <- Map.get(attrs, :metadata, %{}) do
      {:ok,
       %__MODULE__{
         origin: origin,
         request_provider: provider,
         id: id,
         model_provider: model_provider,
         model_id: model_id,
         display_name: display_name,
         execution: execution,
         metadata: metadata |> safe_metadata() |> normalize_metadata() |> normalize_modalities()
       }}
    else
      _invalid -> {:error, :invalid_route}
    end
  end

  def new(_attrs), do: {:error, :invalid_route}

  @spec origin_matches_model?(origin(), String.t(), String.t()) :: boolean()
  defp origin_matches_model?({_kind, provider, id}, provider, id), do: true
  defp origin_matches_model?(_origin, _provider, _id), do: false

  @doc "Materializes the route once into the exact inline model ReqLLM executes."
  @spec materialize(t()) :: {:ok, LLMDB.Model.t()} | {:error, term()}
  def materialize(%__MODULE__{} = route) do
    execution = route.execution

    attrs = %{
      provider: route.request_provider,
      id: execution.provider_model_id,
      model: execution.provider_model_id,
      provider_model_id: execution.provider_model_id,
      name: route.display_name,
      base_url: execution.base_url,
      limits: Map.get(route.metadata, :limits),
      modalities: Map.get(route.metadata, :modalities),
      capabilities: Map.get(route.metadata, :capabilities),
      cost: Map.get(route.metadata, :cost),
      execution: %{text: Map.from_struct(execution)},
      catalog_only: false,
      extra: %{wire: %{protocol: execution.wire_protocol}}
    }

    with {:ok, %LLMDB.Model{} = model} <- ReqLLM.model(drop_nil(attrs)),
         true <- projected_protocol(model) == execution.wire_protocol,
         true <- model.provider == route.request_provider,
         true <- model.base_url == execution.base_url do
      {:ok, model}
    else
      false -> {:error, :materialized_route_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @doc "Encodes a route for secret-free persistence."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = route) do
    %{
      "origin" => encode_origin(route.origin),
      "request_provider" => Atom.to_string(route.request_provider),
      "id" => route.id,
      "model_provider" => route.model_provider,
      "model_id" => route.model_id,
      "display_name" => route.display_name,
      "execution" => TextExecution.encode(route.execution),
      "metadata" => MingaAgent.ModelSelection.Encoding.stringify(route.metadata)
    }
  end

  @doc "Decodes and validates a persisted route."
  @spec decode(map()) :: {:ok, t()} | {:error, :invalid_route}
  def decode(data) when is_map(data) do
    with {:ok, origin} <- decode_origin(Map.get(data, "origin")),
         {:ok, provider} <- decode_provider(Map.get(data, "request_provider")),
         {:ok, execution} <- TextExecution.new(Map.get(data, "execution", %{})) do
      new(%{
        origin: origin,
        request_provider: provider,
        id: Map.get(data, "id"),
        model_provider: Map.get(data, "model_provider"),
        model_id: Map.get(data, "model_id"),
        display_name: Map.get(data, "display_name"),
        execution: execution,
        metadata: atomize_safe_metadata(Map.get(data, "metadata", %{}))
      })
    else
      _invalid -> {:error, :invalid_route}
    end
  end

  def decode(_data), do: {:error, :invalid_route}

  @doc "Returns the supported request provider atoms."
  @spec providers() :: [request_provider()]
  def providers, do: @providers

  @spec compatible?(request_provider(), TextExecution.t()) :: boolean()
  defp compatible?(:anthropic, %TextExecution{
         family: "anthropic_messages",
         wire_protocol: "anthropic_messages",
         path: "/v1/messages"
       }),
       do: true

  defp compatible?(:openai, %TextExecution{
         family: "openai_chat_compatible",
         wire_protocol: "openai_chat",
         path: "/chat/completions"
       }),
       do: true

  defp compatible?(:openai, %TextExecution{
         family: "openai_responses_compatible",
         wire_protocol: "openai_responses",
         path: "/responses"
       }),
       do: true

  defp compatible?(:openai_codex, %TextExecution{
         family: "openai_responses_compatible",
         wire_protocol: "openai_codex_responses",
         path: "/codex/responses"
       }),
       do: true

  defp compatible?(:google, %TextExecution{
         family: "google_generate_content",
         wire_protocol: "google_generate_content",
         path: "/models/{provider_model_id}:generateContent"
       }),
       do: true

  defp compatible?(provider, %TextExecution{
         family: "openai_chat_compatible",
         wire_protocol: "openai_chat",
         path: "/chat/completions"
       })
       when provider in [:openrouter, :groq, :mistral, :deepseek, :ollama],
       do: true

  defp compatible?(_provider, _execution), do: false

  @spec valid_origin?(term()) :: boolean()
  defp valid_origin?({kind, owner, model_id})
       when kind in [:catalog, :custom] and is_binary(owner) and owner != "" and
              is_binary(model_id) and model_id != "",
       do: true

  defp valid_origin?(_origin), do: false

  @spec safe_metadata(map()) :: map()
  defp safe_metadata(metadata),
    do: Map.take(metadata, [:limits, :modalities, :capabilities, :cost])

  @spec atomize_safe_metadata(map()) :: map()
  defp atomize_safe_metadata(metadata) do
    %{}
    |> put_metadata(:limits, Map.get(metadata, "limits"))
    |> put_metadata(:modalities, Map.get(metadata, "modalities"))
    |> put_metadata(:capabilities, Map.get(metadata, "capabilities"))
    |> put_metadata(:cost, Map.get(metadata, "cost"))
  end

  @spec put_metadata(map(), atom(), term()) :: map()
  defp put_metadata(metadata, _key, nil), do: metadata
  defp put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  @spec normalize_metadata(term()) :: term()
  defp normalize_metadata(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {existing_key(key), normalize_metadata(value)} end)
  end

  defp normalize_metadata(list) when is_list(list), do: Enum.map(list, &normalize_metadata/1)
  defp normalize_metadata(value), do: value

  @spec existing_key(term()) :: term()
  defp existing_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp existing_key(key), do: key

  @spec normalize_modalities(map()) :: map()
  defp normalize_modalities(%{modalities: modalities} = metadata) when is_map(modalities) do
    normalized =
      Map.new(modalities, fn
        {direction, values} when is_list(values) ->
          {direction, Enum.map(values, &normalize_modality/1)}

        pair ->
          pair
      end)

    Map.put(metadata, :modalities, normalized)
  end

  defp normalize_modalities(metadata), do: metadata

  @spec normalize_modality(term()) :: term()
  defp normalize_modality(value) when is_atom(value) or is_binary(value) do
    case LLMDB.Generated.ValidModalities.fetch(value) do
      {:ok, modality} -> modality
      :error -> value
    end
  end

  defp normalize_modality(value), do: value

  @spec encode_origin(origin()) :: map()
  defp encode_origin({kind, owner, model_id}) do
    %{"kind" => Atom.to_string(kind), "owner" => owner, "model_id" => model_id}
  end

  @spec decode_origin(map()) :: {:ok, origin()} | {:error, :invalid_route}
  defp decode_origin(%{"kind" => "catalog", "owner" => owner, "model_id" => model_id})
       when is_binary(owner) and owner != "" and is_binary(model_id) and model_id != "",
       do: {:ok, {:catalog, owner, model_id}}

  defp decode_origin(%{"kind" => "custom", "owner" => owner, "model_id" => model_id})
       when is_binary(owner) and owner != "" and is_binary(model_id) and model_id != "",
       do: {:ok, {:custom, owner, model_id}}

  defp decode_origin(_origin), do: {:error, :invalid_route}

  @spec decode_provider(term()) :: {:ok, request_provider()} | {:error, :invalid_route}
  defp decode_provider(value) when is_binary(value) do
    case Enum.find(@providers, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_route}
      provider -> {:ok, provider}
    end
  end

  defp decode_provider(_value), do: {:error, :invalid_route}

  @spec drop_nil(map()) :: map()
  defp drop_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  @spec projected_protocol(LLMDB.Model.t()) :: String.t() | nil
  defp projected_protocol(%LLMDB.Model{extra: %{wire: %{protocol: protocol}}}), do: protocol

  defp projected_protocol(_model), do: nil
end
