defmodule MingaAgent.Providers.Native.ReqLLMAdapter do
  @moduledoc """
  ReqLLM-specific adapter helpers for the native provider.

  `MingaAgent.Providers.Native` owns orchestration policy: turn flow, retry, cost, compaction, approvals, tool coordination, context updates, and event normalization. This module owns the ReqLLM-shaped details needed to make one provider request and decode one provider response.
  """

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Credentials
  alias MingaAgent.Providers.Native.ReqLLMAdapter.ToolCall
  alias MingaAgent.Providers.Native.ReqLLMAdapter.TurnResult
  alias MingaAgent.Tool.Spec, as: ToolSpec
  alias ReqLLM.Message
  alias ReqLLM.Response
  alias ReqLLM.StreamResponse
  alias ReqLLM.Tool
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall, as: ReqLLMToolCall

  @typedoc "Streaming LLM client compatible with ReqLLM.stream_text/3."
  @type llm_client :: (String.t(), [ReqLLM.Message.t()], keyword() ->
                         {:ok, StreamResponse.t()} | {:error, term()})

  @typedoc "Neutralized tool-call payload emitted by ReqLLM streaming."
  @type tool_call :: ToolCall.t()

  @typedoc "Raw ReqLLM usage payload before Native normalizes it into TurnUsage."
  @type raw_usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:input) => non_neg_integer(),
          optional(:output) => non_neg_integer(),
          optional(:cache_read_input_tokens) => non_neg_integer(),
          optional(:cache_creation_input_tokens) => non_neg_integer(),
          optional(:cached_input) => non_neg_integer(),
          optional(:cached_tokens) => non_neg_integer(),
          optional(:cache_creation) => non_neg_integer(),
          optional(:cache_creation_tokens) => non_neg_integer(),
          optional(:cache_read) => non_neg_integer(),
          optional(:cache_write) => non_neg_integer(),
          optional(:total_cost) => number(),
          optional(:cost) => number()
        }

  @typedoc "Callbacks used while streaming a provider response."
  @type stream_callbacks :: [
          on_text: (String.t() -> term()),
          on_thinking: (String.t() -> term()),
          on_tool_call: (tool_call() -> term())
        ]

  @typep content_event ::
           {:text | :thinking, [String.t()], map()} | {:content_part, ContentPart.t()}
  @typep stream_accumulator :: {[String.t()], [content_event()]}

  @typedoc "Decoded result from one provider response."
  @type turn_result :: TurnResult.t()

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
    case parse_provider(model) do
      {:ok, _provider} ->
        :ok

      :error ->
        message =
          ~s|Model "#{model}" is invalid. | <>
            ~s|Expected "provider:model" (e.g., "anthropic:claude") or "model@provider". | <>
            "Check :agent_model in your config."

        {:error, message, :invalid_format}
    end
  end

  @doc "Builds the provider-specific tool value for a canonical tool declaration."
  @spec tool(ToolSpec.t(), ToolSpec.callback(), map()) :: Tool.t()
  def tool(%ToolSpec{} = spec, callback, provider_options \\ %{})
      when is_function(callback, 1) and is_map(provider_options) do
    Tool.new!(
      name: spec.name,
      description: spec.description,
      parameter_schema: spec.parameter_schema,
      provider_options: provider_options,
      callback: callback
    )
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
    {:ok, accumulator} = Agent.start_link(fn -> {[], []} end)

    try do
      result =
        StreamResponse.process_stream(stream_response,
          on_chunk: fn
            %ReqLLM.StreamChunk{metadata: %{stream_only?: true}} ->
              :ok

            %ReqLLM.StreamChunk{type: type} = chunk
            when type in [:content, :thinking, :content_part] ->
              Agent.update(accumulator, &accumulate_content_chunk(&1, chunk))

            _chunk ->
              :ok
          end,
          on_result: fn text ->
            run_callback(callbacks, :on_text, text)
          end,
          on_thinking: fn text ->
            run_callback(callbacks, :on_thinking, text)
          end,
          on_tool_call: fn chunk ->
            run_callback(callbacks, :on_tool_call, tool_call_chunk_to_map(chunk))
          end
        )

      {partial_text_parts, content_events} = Agent.get(accumulator, & &1)

      case result do
        {:ok, response} ->
          case response_to_turn_result(response, content_events) do
            {:ok, turn_result} -> {:ok, turn_result}
            {:error, reason} -> {:error, reason, partial_text(partial_text_parts)}
          end

        {:error, reason} ->
          {:error, reason, partial_text(partial_text_parts)}
      end
    after
      if Process.alive?(accumulator) do
        Agent.stop(accumulator)
      end
    end
  end

  @spec accumulate_content_chunk(stream_accumulator(), ReqLLM.StreamChunk.t()) ::
          stream_accumulator()
  defp accumulate_content_chunk(
         {partial_text, content_events},
         %ReqLLM.StreamChunk{type: :content, text: text, metadata: metadata}
       )
       when is_binary(text) do
    append_ordered_content({[text | partial_text], content_events}, {:text, text, metadata})
  end

  defp accumulate_content_chunk(
         accumulator,
         %ReqLLM.StreamChunk{type: :thinking, text: text, metadata: metadata}
       )
       when is_binary(text) do
    append_ordered_content(accumulator, {:thinking, text, metadata})
  end

  defp accumulate_content_chunk(
         {partial_text, content_events},
         %ReqLLM.StreamChunk{type: :content_part, content_part: %ContentPart{} = part}
       ) do
    {partial_text, [{:content_part, part} | content_events]}
  end

  defp accumulate_content_chunk(accumulator, _chunk), do: accumulator

  @spec append_ordered_content(
          stream_accumulator(),
          {:text | :thinking, String.t(), map()}
        ) :: stream_accumulator()
  defp append_ordered_content({partial_text, events}, {type, text, metadata}) do
    case events do
      [{event_type, texts, event_metadata} | rest]
      when event_type == type and event_metadata == metadata ->
        {partial_text, [{type, [text | texts], metadata} | rest]}

      _other ->
        {partial_text, [{type, [text], metadata} | events]}
    end
  end

  @spec ordered_content([content_event()], [term()]) :: [term()]
  defp ordered_content([], fallback), do: fallback

  defp ordered_content(content_events, fallback) do
    events = Enum.reverse(content_events)
    event_types = Enum.map(events, &content_event_type/1)
    fallback_types = Enum.map(fallback, &content_part_type/1)

    if event_types == fallback_types do
      if text_metadata_missing?(events, fallback) do
        Enum.map(events, &content_event_to_part/1)
      else
        fallback
      end
    else
      reorder_content_if_safe(events, fallback, event_types, fallback_types)
    end
  end

  @spec text_metadata_missing?([content_event()], [term()]) :: boolean()
  defp text_metadata_missing?(events, fallback) do
    Enum.zip(events, fallback)
    |> Enum.any?(fn
      {{:text, _chunks, metadata}, %ContentPart{type: :text, metadata: stored}} ->
        metadata != stored

      {{:thinking, _chunks, metadata}, %ContentPart{type: :thinking, metadata: stored}} ->
        metadata != stored

      _other ->
        false
    end)
  end

  @spec reorder_content_if_safe([content_event()], [term()], [atom()], [atom()]) :: [term()]
  defp reorder_content_if_safe(events, fallback, event_types, fallback_types) do
    case {text_thinking_types?(event_types), text_thinking_types?(fallback_types)} do
      {true, true} ->
        Enum.map(events, &content_event_to_part/1)

      {false, false} ->
        reorder_matching_content(events, fallback, event_types, fallback_types)

      _different_content ->
        fallback
    end
  end

  @spec reorder_matching_content([content_event()], [term()], [atom()], [atom()]) :: [term()]
  defp reorder_matching_content(events, fallback, event_types, fallback_types) do
    if Enum.frequencies(event_types) == Enum.frequencies(fallback_types) do
      ordered = Enum.map(events, &content_event_to_part/1)
      if Enum.frequencies(ordered) == Enum.frequencies(fallback), do: ordered, else: fallback
    else
      fallback
    end
  end

  @spec content_event_type(content_event()) :: atom()
  defp content_event_type({:text, _chunks, _metadata}), do: :text
  defp content_event_type({:thinking, _chunks, _metadata}), do: :thinking
  defp content_event_type({:content_part, part}), do: part.type

  @spec content_part_type(term()) :: atom()
  defp content_part_type(%{type: type}) when is_atom(type), do: type
  defp content_part_type(_part), do: :unknown

  @spec text_thinking_types?([atom()]) :: boolean()
  defp text_thinking_types?(types), do: Enum.all?(types, &(&1 in [:text, :thinking]))

  @spec content_event_to_part(content_event()) :: ContentPart.t()
  defp content_event_to_part({:text, chunks, metadata}) do
    ContentPart.text(chunks |> Enum.reverse() |> IO.iodata_to_binary(), metadata)
  end

  defp content_event_to_part({:thinking, chunks, metadata}) do
    ContentPart.thinking(chunks |> Enum.reverse() |> IO.iodata_to_binary(), metadata)
  end

  defp content_event_to_part({:content_part, part}), do: part

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
  @spec assistant_tool_call(String.t(), String.t(), map()) :: ReqLLMToolCall.t()
  def assistant_tool_call(id, name, arguments) do
    ReqLLMToolCall.new(id, name, JSON.encode!(arguments))
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
  @spec ensure_api_key_in_env(String.t(), keyword()) :: :ok
  def ensure_api_key_in_env(model, opts \\ []) do
    case parse_provider(model) do
      {:ok, provider} -> ensure_provider_api_key_in_env(provider, opts)
      :error -> :ok
    end
  end

  @spec response_to_turn_result(Response.t(), [content_event()]) ::
          {:ok, turn_result()} | {:error, term()}
  defp response_to_turn_result(
         %Response{
           message: %Message{role: :assistant} = message,
           finish_reason: finish_reason
         } = response,
         content_events
       )
       when finish_reason in [:stop, :tool_calls] do
    case extract_tool_calls(response) do
      {:ok, tool_calls} ->
        message = %{message | content: ordered_content(content_events, message.content)}

        {:ok, TurnResult.new(message, tool_calls, extract_usage(response))}

      {:error, reason} ->
        {:error, {:incomplete_response, reason}}
    end
  end

  defp response_to_turn_result(
         %Response{message: %Message{role: :assistant}, finish_reason: finish_reason},
         _content_events
       ) do
    {:error, {:incomplete_response, finish_reason}}
  end

  defp response_to_turn_result(%Response{message: message}, _content_events) do
    {:error, {:invalid_assistant_response, message}}
  end

  @spec extract_tool_calls(Response.t()) :: {:ok, [tool_call()]} | {:error, term()}
  defp extract_tool_calls(%{message: %{tool_calls: nil}}), do: {:ok, []}

  defp extract_tool_calls(%{message: %{tool_calls: tool_calls}}) when is_list(tool_calls) do
    tool_calls
    |> Enum.reduce_while({:ok, []}, fn tool_call, {:ok, acc} ->
      case req_llm_tool_call_to_adapter_tool_call(tool_call) do
        {:ok, adapter_call} -> {:cont, {:ok, [adapter_call | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tool_calls} -> {:ok, Enum.reverse(tool_calls)}
      {:error, _reason} = error -> error
    end
  end

  defp extract_tool_calls(_response), do: {:error, :invalid_tool_call_list}

  @spec partial_text([String.t()]) :: String.t()
  defp partial_text(parts), do: parts |> Enum.reverse() |> IO.iodata_to_binary()

  @spec extract_usage(Response.t()) :: raw_usage() | nil
  defp extract_usage(%{usage: usage}) when is_map(usage), do: usage
  defp extract_usage(_response), do: nil

  @spec req_llm_tool_call_to_adapter_tool_call(ReqLLMToolCall.t()) ::
          {:ok, tool_call()} | {:error, term()}
  defp req_llm_tool_call_to_adapter_tool_call(
         %ReqLLMToolCall{id: id, function: %{name: name}} = tool_call
       ) do
    case tool_call_error(ReqLLMToolCall.metadata(tool_call)) do
      nil ->
        case ReqLLMToolCall.args_map(tool_call) do
          arguments when is_map(arguments) -> {:ok, ToolCall.new(id, name, arguments)}
          _invalid_arguments -> {:error, {:invalid_tool_call_arguments, id}}
        end

      reason ->
        {:error, {:tool_call_arguments_lost, id, reason}}
    end
  end

  defp req_llm_tool_call_to_adapter_tool_call(_tool_call), do: {:error, :invalid_tool_call_shape}

  @spec tool_call_error(map()) :: term() | nil
  defp tool_call_error(%{error: reason}), do: reason
  defp tool_call_error(_metadata), do: nil

  @spec tool_call_chunk_to_map(term()) :: tool_call()
  defp tool_call_chunk_to_map(chunk) do
    ToolCall.new(
      Map.get(chunk.metadata, :id, "tool_#{:erlang.unique_integer([:positive])}"),
      chunk.name || "unknown",
      chunk.arguments || %{}
    )
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
      # anthropic_cache_messages adds a cache_control breakpoint on the last
      # conversation message so the growing transcript is a rolling cache-read
      # prefix rather than re-sent at full input price every turn.
      Keyword.put(opts, :provider_options,
        anthropic_prompt_cache: true,
        anthropic_cache_messages: true
      )
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

  @spec ensure_provider_api_key_in_env(String.t(), keyword()) :: :ok
  defp ensure_provider_api_key_in_env(provider, opts) do
    case Credentials.resolve(provider, opts) do
      {:ok, key, :file} -> put_file_backed_key_in_env(provider, key, opts)
      {:ok, _key, :env} -> :ok
      :error -> warn_missing_credentials(provider)
    end
  end

  @spec put_file_backed_key_in_env(String.t(), String.t(), keyword()) :: :ok
  defp put_file_backed_key_in_env(provider, key, opts) do
    case Credentials.env_var_for(provider) do
      nil ->
        :ok

      var_name ->
        case Keyword.get(opts, :on_env_set) do
          fun when is_function(fun, 2) -> fun.(var_name, key)
          nil -> System.put_env(var_name, key)
        end

        :ok
    end
  end

  @spec warn_missing_credentials(String.t()) :: :ok
  defp warn_missing_credentials(provider) do
    case Credentials.env_var_for(provider) do
      nil ->
        :ok

      var_name ->
        Minga.Log.warning(
          :agent,
          "[Agent.Native] No API key found for #{provider}. " <>
            "Use /auth to configure one, or set #{var_name}."
        )
    end
  end

  @spec provider_from_model(String.t()) :: String.t() | nil
  defp provider_from_model(model) do
    case parse_provider(model) do
      {:ok, provider} -> provider
      :error -> nil
    end
  end

  @spec parse_provider(String.t()) :: {:ok, String.t()} | :error
  defp parse_provider(model) do
    parse_provider(model, String.contains?(model, "@"), String.contains?(model, ":"))
  end

  @spec parse_provider(String.t(), boolean(), boolean()) :: {:ok, String.t()} | :error
  defp parse_provider(model, true, false) do
    with {:ok, _model_name, provider} <- split_once(model, "@") do
      {:ok, String.downcase(provider)}
    end
  end

  defp parse_provider(model, false, true) do
    with {:ok, provider, _model_name} <- split_once(model, ":") do
      {:ok, String.downcase(provider)}
    end
  end

  defp parse_provider(_model, _at?, _colon?), do: :error

  @spec split_once(String.t(), String.t()) :: {:ok, String.t(), String.t()} | :error
  defp split_once(value, separator) do
    case String.split(value, separator) do
      [left, right] -> non_empty_pair(left, right)
      _other -> :error
    end
  end

  @spec non_empty_pair(String.t(), String.t()) :: {:ok, String.t(), String.t()} | :error
  defp non_empty_pair("", _right), do: :error
  defp non_empty_pair(_left, ""), do: :error
  defp non_empty_pair(left, right), do: {:ok, left, right}

  @spec non_empty(String.t() | nil) :: String.t() | nil
  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(str) when is_binary(str), do: str
end
