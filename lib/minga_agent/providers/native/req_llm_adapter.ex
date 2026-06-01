defmodule MingaAgent.Providers.Native.ReqLLMAdapter do
  @moduledoc """
  ReqLLM-specific adapter helpers for the native provider.

  `MingaAgent.Providers.Native` owns orchestration policy: turn flow, retry, cost, compaction, approvals, tool coordination, context updates, and event normalization. This module owns the ReqLLM-shaped details needed to make one provider request and decode one provider response.
  """

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Credentials
  alias ReqLLM.Response
  alias ReqLLM.StreamResponse
  alias ReqLLM.Tool
  alias ReqLLM.ToolCall

  @typedoc "Streaming LLM client compatible with ReqLLM.stream_text/3."
  @type llm_client :: (String.t(), [ReqLLM.Message.t()], keyword() ->
                         {:ok, StreamResponse.t()} | {:error, term()})

  @typedoc "Callbacks used while streaming a provider response."
  @type stream_callbacks :: [
          on_text: (String.t() -> term()),
          on_thinking: (String.t() -> term()),
          on_tool_call: (map() -> term())
        ]

  @typedoc "Decoded result from one provider response."
  @type turn_result :: %{
          text: String.t(),
          tool_calls: [map()],
          usage: map() | nil
        }

  @thinking_efforts %{
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "think" => :medium,
    "think-hard" => :high,
    "ultrathink" => :high
  }

  @doc "Returns the default ReqLLM streaming client."
  @spec default_client() :: llm_client()
  def default_client, do: &ReqLLM.stream_text/3

  @doc "Validates the model string before ReqLLM sees it."
  @spec validate_model(String.t()) :: :ok | {:error, String.t(), :invalid_format}
  def validate_model(model) when is_binary(model) do
    if String.contains?(model, ":") or String.contains?(model, "@") do
      :ok
    else
      message =
        ~s|Model "#{model}" is missing a provider prefix. | <>
          ~s|Expected "provider:model" (e.g., "anthropic:#{model}"). | <>
          "Check :agent_model in your config."

      {:error, message, :invalid_format}
    end
  end

  @doc "Builds ReqLLM stream options for one native provider request."
  @spec stream_opts(String.t(), [Tool.t()], String.t(), pos_integer(), AgentConfig.t()) ::
          keyword()
  def stream_opts(model, tools, thinking_level, max_tokens, %AgentConfig{} = config) do
    opts = [tools: tools, max_tokens: max_tokens]

    opts
    |> maybe_add_base_url(model, config)
    |> maybe_add_prompt_cache(model, config)
    |> maybe_add_codex_oauth(model)
    |> maybe_add_reasoning_effort(thinking_level)
  end

  @doc "Runs one ReqLLM streaming request attempt. Retry ownership stays in Native."
  @spec stream(llm_client(), String.t(), [ReqLLM.Message.t()], keyword()) ::
          {:ok, StreamResponse.t()} | {:error, term()}
  def stream(llm_client, model, messages, opts) when is_function(llm_client, 3) do
    llm_client.(model, messages, opts)
  end

  @doc "Processes a ReqLLM stream response into a neutral turn result."
  @spec process_stream(StreamResponse.t(), stream_callbacks()) ::
          {:ok, turn_result()} | {:error, term(), String.t()}
  def process_stream(%StreamResponse{} = stream_response, callbacks \\ []) do
    {:ok, accumulator} = Agent.start_link(fn -> "" end)

    result =
      StreamResponse.process_stream(stream_response,
        on_result: fn text ->
          Agent.update(accumulator, fn acc -> acc <> text end)
          run_callback(callbacks, :on_text, text)
        end,
        on_thinking: fn text ->
          run_callback(callbacks, :on_thinking, text)
        end,
        on_tool_call: fn chunk ->
          run_callback(callbacks, :on_tool_call, tool_call_chunk_to_map(chunk))
        end
      )

    partial_text = Agent.get(accumulator, & &1)
    Agent.stop(accumulator)

    case result do
      {:ok, response} -> {:ok, response_to_turn_result(response)}
      {:error, reason} -> {:error, reason, partial_text}
    end
  end

  @doc "Runs a non-streaming text request through ReqLLM stream processing."
  @spec call_sync(llm_client(), String.t(), [ReqLLM.Message.t()], keyword(), AgentConfig.t()) ::
          {:ok, String.t()} | {:error, term()}
  def call_sync(llm_client, model, messages, opts, %AgentConfig{} = config) do
    stream_opts =
      opts
      |> Keyword.take([:max_tokens])
      |> maybe_add_base_url(model, config)

    with {:ok, stream_response} <- stream(llm_client, model, messages, stream_opts),
         {:ok, response} <- StreamResponse.process_stream(stream_response) do
      {:ok, Response.text(response) || ""}
    end
  end

  @doc "Builds the summary callback expected by the compaction subsystem."
  @spec summary_client(llm_client(), AgentConfig.t()) :: MingaAgent.Compaction.summary_fn()
  def summary_client(llm_client, %AgentConfig{} = config) do
    fn model, messages, opts ->
      opts = maybe_add_base_url(opts, model, config)

      with {:ok, stream_response} <- stream(llm_client, model, messages, opts),
           {:ok, response} <- StreamResponse.process_stream(stream_response) do
        {:ok, Response.text(response) || ""}
      end
    end
  end

  @doc "Creates a ReqLLM tool-call value for assistant messages."
  @spec assistant_tool_call(String.t(), String.t(), map()) :: ToolCall.t()
  def assistant_tool_call(id, name, arguments) do
    ToolCall.new(id, name, JSON.encode!(arguments))
  end

  @doc "Returns true for Anthropic-compatible models."
  @spec anthropic_model?(String.t()) :: boolean()
  def anthropic_model?(model) do
    provider_from_model(model) == "anthropic"
  end

  @doc "Returns true for OpenAI Codex OAuth-backed models."
  @spec openai_codex_model?(String.t()) :: boolean()
  def openai_codex_model?(model), do: provider_from_model(model) == "openai_codex"

  @doc "Sets the provider API key env var when credentials are file-backed."
  @spec ensure_api_key_in_env(String.t()) :: :ok
  def ensure_api_key_in_env(model) do
    provider = provider_from_model(model)

    case Credentials.resolve(provider) do
      {:ok, key, :file} ->
        case Credentials.env_var_for(provider) do
          nil -> :ok
          var_name -> System.put_env(var_name, key)
        end

      {:ok, _key, :env} ->
        :ok

      :error ->
        Minga.Log.debug(
          :agent,
          "[Agent.Native] No API key found for #{provider}. " <>
            "Use /auth to configure one, or set #{Credentials.env_var_for(provider) || "the provider's env var"}."
        )

        :ok
    end
  end

  @spec response_to_turn_result(Response.t()) :: turn_result()
  defp response_to_turn_result(response) do
    %{
      tool_calls: extract_tool_calls(response),
      text: extract_text(response),
      usage: extract_usage(response)
    }
  end

  @spec extract_tool_calls(Response.t()) :: [map()]
  defp extract_tool_calls(%{message: %{tool_calls: nil}}), do: []

  defp extract_tool_calls(%{message: %{tool_calls: tool_calls}}) when is_list(tool_calls) do
    Enum.map(tool_calls, &ToolCall.to_map/1)
  end

  defp extract_tool_calls(_response), do: []

  @spec extract_text(Response.t()) :: String.t()
  defp extract_text(%{message: %{content: content}}) when is_list(content) do
    content
    |> Enum.filter(fn part -> Map.get(part, :type, :text) == :text end)
    |> Enum.map_join("", fn part -> Map.get(part, :text, "") end)
  end

  defp extract_text(_response), do: ""

  @spec extract_usage(Response.t()) :: map() | nil
  defp extract_usage(%{usage: usage}) when is_map(usage), do: usage
  defp extract_usage(_response), do: nil

  @spec tool_call_chunk_to_map(term()) :: map()
  defp tool_call_chunk_to_map(chunk) do
    %{
      id: Map.get(chunk.metadata, :id, "tool_#{:erlang.unique_integer([:positive])}"),
      name: chunk.name || "unknown",
      arguments: chunk.arguments || %{}
    }
  end

  @spec run_callback(stream_callbacks(), atom(), term()) :: :ok
  defp run_callback(callbacks, key, value) do
    case Keyword.get(callbacks, key) do
      fun when is_function(fun, 1) -> fun.(value)
      _missing -> :ok
    end

    :ok
  end

  @spec maybe_add_prompt_cache(keyword(), String.t(), AgentConfig.t()) :: keyword()
  defp maybe_add_prompt_cache(opts, model, config) do
    if anthropic_model?(model) and config.prompt_cache do
      Keyword.put(opts, :provider_options, anthropic_prompt_cache: true)
    else
      opts
    end
  end

  @spec maybe_add_codex_oauth(keyword(), String.t()) :: keyword()
  defp maybe_add_codex_oauth(opts, model) do
    if openai_codex_model?(model) do
      provider_options =
        Keyword.get(opts, :provider_options, [])
        |> Keyword.put(:auth_mode, :oauth)
        |> Keyword.put(:oauth_file, Credentials.oauth_path())
        |> Keyword.put(:codex_originator, "minga")

      Keyword.put(opts, :provider_options, provider_options)
    else
      opts
    end
  end

  @spec maybe_add_reasoning_effort(keyword(), String.t()) :: keyword()
  defp maybe_add_reasoning_effort(opts, thinking_level) do
    case Map.get(@thinking_efforts, thinking_level) do
      effort when effort in [:low, :medium, :high] -> Keyword.put(opts, :reasoning_effort, effort)
      nil -> opts
    end
  end

  @spec maybe_add_base_url(keyword(), String.t(), AgentConfig.t()) :: keyword()
  defp maybe_add_base_url(opts, model, %AgentConfig{} = config) do
    url =
      non_empty(config.api_base_url_override) ||
        per_provider_url(model, config) ||
        non_empty(config.api_base_url)

    if url, do: Keyword.put(opts, :base_url, url), else: opts
  end

  @spec per_provider_url(String.t(), AgentConfig.t()) :: String.t() | nil
  defp per_provider_url(model, config) do
    provider = provider_from_model(model)

    case config.api_endpoints do
      endpoints when is_map(endpoints) -> non_empty(Map.get(endpoints, provider))
      _other -> nil
    end
  end

  @spec provider_from_model(String.t()) :: String.t()
  defp provider_from_model(model) do
    provider_from_model(model, String.contains?(model, "@"), String.contains?(model, ":"))
  end

  @spec provider_from_model(String.t(), boolean(), boolean()) :: String.t()
  defp provider_from_model(model, true, _colon?) do
    model
    |> String.split("@", parts: 2)
    |> List.last()
    |> String.downcase()
  end

  defp provider_from_model(model, false, true) do
    model
    |> String.split(":", parts: 2)
    |> hd()
    |> String.downcase()
  end

  defp provider_from_model(_model, false, false), do: "anthropic"

  @spec non_empty(String.t() | nil) :: String.t() | nil
  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(str) when is_binary(str), do: str
end
