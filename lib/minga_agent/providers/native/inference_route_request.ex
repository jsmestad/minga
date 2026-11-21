defmodule MingaAgent.Providers.Native.InferenceRouteRequest do
  @moduledoc """
  Translates one native request into the Minga-owned `MingaAgent.InferenceRoute.Request` a contributed route receives.

  Routes never see a ReqLLM value. Rules:

  - System messages become `Request.system`, their text parts joined by a blank line.
  - Text, inline image, and thinking parts map one to one. A thinking signature is passed only when the part's metadata carries a string `:signature`.
  - A tool message becomes one `{:tool_result, id, parts, is_error}` part. `is_error` is true only when the message metadata says so.
  - Assistant tool calls follow the message's text and thinking as `{:tool_call, call}` parts, with decoded arguments.
  - Any other part (image URLs, video, files, provider blocks) fails the request with `{:inference_route_unsupported_content, type}` instead of being dropped silently. Capability checks and portable history remove these before a contributed route is reached, so this only guards against drift.
  - `:summary` and `:title` requests carry no tools.
  """

  alias MingaAgent.InferenceRoute.{ConversationRef, Credential, Message, Model, Options}
  alias MingaAgent.InferenceRoute.{Request, ToolCall, ToolDeclaration}
  alias ReqLLM.Message.ContentPart

  @type error ::
          {:inference_route_unsupported_content, atom()}
          | {:inference_route_invalid_tool_call, String.t() | nil}
          | :inference_route_missing_conversation

  @doc "Builds the route request from native messages and prepared stream options."
  @spec build(Model.t(), [ReqLLM.Message.t()], keyword()) ::
          {:ok, Request.t()} | {:error, error()}
  def build(%Model{} = model, messages, opts) when is_list(messages) do
    with {:ok, conversation} <- conversation(opts),
         {:ok, system, messages} <- split_messages(messages) do
      {:ok,
       %Request{
         model: model,
         system: system,
         messages: messages,
         tools: tools(conversation, Keyword.get(opts, :tools, [])),
         options: %Options{
           max_output_tokens: Keyword.get(opts, :max_tokens, model.max_output),
           reasoning: Keyword.get(opts, :minga_reasoning)
         },
         conversation: conversation,
         credential: credential(Keyword.get(opts, :route_credential))
       }}
    end
  end

  @spec conversation(keyword()) :: {:ok, ConversationRef.t()} | {:error, error()}
  defp conversation(opts) do
    case Keyword.get(opts, :minga_conversation) do
      %ConversationRef{} = conversation -> {:ok, conversation}
      _missing -> {:error, :inference_route_missing_conversation}
    end
  end

  @spec credential(term()) :: Credential.t() | nil
  defp credential(%Credential{} = credential), do: credential
  defp credential(_none), do: nil

  @spec tools(ConversationRef.t(), [ReqLLM.Tool.t()]) :: [ToolDeclaration.t()]
  defp tools(%ConversationRef{purpose: :turn}, tools), do: Enum.map(tools, &declaration/1)
  defp tools(%ConversationRef{}, _tools), do: []

  @spec declaration(ReqLLM.Tool.t()) :: ToolDeclaration.t()
  defp declaration(%ReqLLM.Tool{} = tool) do
    schema = tool |> ReqLLM.Tool.to_json_schema() |> get_in(["function", "parameters"])

    %ToolDeclaration{
      name: tool.name,
      description: tool.description,
      input_schema: stringify_keys(schema || %{"type" => "object"})
    }
  end

  @spec split_messages([ReqLLM.Message.t()]) ::
          {:ok, String.t() | nil, [Message.t()]} | {:error, error()}
  defp split_messages(messages) do
    messages
    |> Enum.reduce_while({:ok, [], []}, fn message, {:ok, system, acc} ->
      case message(message) do
        {:system, text} -> {:cont, {:ok, [text | system], acc}}
        {:ok, translated} -> {:cont, {:ok, system, [translated | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, [], acc} ->
        {:ok, nil, Enum.reverse(acc)}

      {:ok, system, acc} ->
        {:ok, system |> Enum.reverse() |> Enum.join("\n\n"), Enum.reverse(acc)}

      {:error, _reason} = error ->
        error
    end
  end

  @spec message(ReqLLM.Message.t()) ::
          {:system, String.t()} | {:ok, Message.t()} | {:error, error()}
  defp message(%ReqLLM.Message{role: :system, content: content}) do
    {:system,
     for(%ContentPart{type: :text, text: text} <- content, is_binary(text), do: text)
     |> Enum.join("\n\n")}
  end

  defp message(%ReqLLM.Message{role: :tool} = message) do
    with {:ok, parts} <- parts(message.content, [:text, :image]) do
      is_error = Map.get(message.metadata || %{}, :is_error) == true

      {:ok,
       %Message{role: :tool, content: [{:tool_result, message.tool_call_id, parts, is_error}]}}
    end
  end

  defp message(%ReqLLM.Message{role: role} = message) when role in [:user, :assistant] do
    with {:ok, parts} <- parts(message.content, [:text, :image, :thinking]),
         {:ok, calls} <- tool_calls(message.tool_calls || []) do
      {:ok, %Message{role: role, content: parts ++ calls}}
    end
  end

  @spec parts([ContentPart.t()], [atom()]) :: {:ok, [Message.part()]} | {:error, error()}
  defp parts(content, allowed) do
    content
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case part(part, allowed) do
        {:ok, translated} -> {:cont, {:ok, [translated | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @spec part(term(), [atom()]) :: {:ok, Message.part()} | {:error, error()}
  defp part(%ContentPart{type: :text, text: text}, _allowed) when is_binary(text),
    do: {:ok, {:text, text}}

  defp part(%ContentPart{type: :image, data: data, media_type: media_type}, allowed)
       when is_binary(data) and is_binary(media_type) do
    if :image in allowed,
      do: {:ok, {:image, media_type, data}},
      else: unsupported(:image)
  end

  defp part(%ContentPart{type: :thinking, text: text, metadata: metadata}, allowed)
       when is_binary(text) do
    if :thinking in allowed,
      do: {:ok, {:thinking, text, signature(metadata)}},
      else: unsupported(:thinking)
  end

  defp part(%ContentPart{type: type}, _allowed), do: unsupported(type)
  defp part(_other, _allowed), do: unsupported(:unknown)

  @spec unsupported(atom()) :: {:error, error()}
  defp unsupported(type), do: {:error, {:inference_route_unsupported_content, type}}

  @spec signature(term()) :: String.t() | nil
  defp signature(%{signature: signature}) when is_binary(signature), do: signature
  defp signature(_metadata), do: nil

  @spec tool_calls([ReqLLM.ToolCall.t()]) :: {:ok, [Message.part()]} | {:error, error()}
  defp tool_calls(calls) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, acc} ->
      case tool_call(call) do
        {:ok, translated} -> {:cont, {:ok, [{:tool_call, translated} | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @spec tool_call(term()) :: {:ok, ToolCall.t()} | {:error, error()}
  defp tool_call(%ReqLLM.ToolCall{id: id} = call) do
    case ToolCall.new(
           id: id,
           name: ReqLLM.ToolCall.name(call),
           arguments: ReqLLM.ToolCall.args_map(call)
         ) do
      {:ok, call} -> {:ok, call}
      {:error, _reason} -> {:error, {:inference_route_invalid_tool_call, id}}
    end
  end

  defp tool_call(_call), do: {:error, {:inference_route_invalid_tool_call, nil}}

  @spec stringify_keys(term()) :: term()
  defp stringify_keys(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
