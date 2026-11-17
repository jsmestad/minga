defmodule MingaAgent.Session.PortableHistory do
  @moduledoc "Pure conversion of completed model history without provider-owned replay state."

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  @type error ::
          :unportable_attachment
          | :unportable_compaction
          | :unportable_content
          | :incomplete_tool_exchange
  @type counts :: %{non_neg_integer() => non_neg_integer()}
  @type file_policy :: :retain | :reject

  @doc "Explains why completed history cannot move to another model."
  @spec message(error()) :: String.t()
  def message(:unportable_attachment),
    do:
      "This conversation contains a provider-owned file that the selected model cannot access. Keep the current model or start a new conversation."

  def message(:unportable_compaction),
    do:
      "This conversation contains provider-only compacted context. Keep the current model or start a new conversation."

  def message(:unportable_content),
    do:
      "This conversation contains content the selected model cannot represent. Keep the current model or start a new conversation."

  def message(:incomplete_tool_exchange),
    do:
      "This conversation has an incomplete tool exchange. Reconcile the outstanding tool results before changing models."

  @doc "Converts history and maps each old message boundary to its converted message count."
  @spec convert([Message.t()], file_policy()) ::
          {:ok, [Message.t()], counts()} | {:error, error()}
  def convert(messages, file_policy \\ :reject) do
    initial = {:ok, [], %{0 => 0}, 0, MapSet.new()}

    messages
    |> Enum.with_index(1)
    |> Enum.reduce_while(initial, fn {message, index}, {:ok, acc, counts, count, pending} ->
      with {:ok, converted} <- convert_message(message, file_policy),
           {:ok, pending} <- track_exchange(converted, pending) do
        {acc, count} = append_message(converted, acc, count)
        {:cont, {:ok, acc, Map.put(counts, index, count), count, pending}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> finish()
  end

  @spec finish(term()) :: {:ok, [Message.t()], counts()} | {:error, error()}
  defp finish({:ok, messages, counts, _count, pending}) do
    if MapSet.size(pending) == 0,
      do: {:ok, Enum.reverse(messages), counts},
      else: {:error, :incomplete_tool_exchange}
  end

  defp finish({:error, _reason} = error), do: error

  @spec append_message(Message.t() | nil, [Message.t()], non_neg_integer()) ::
          {[Message.t()], non_neg_integer()}
  defp append_message(nil, acc, count), do: {acc, count}
  defp append_message(message, acc, count), do: {[message | acc], count + 1}

  @spec convert_message(Message.t(), file_policy()) ::
          {:ok, Message.t() | nil} | {:error, error()}
  defp convert_message(%Message{} = message, file_policy) do
    with {:ok, content} <- convert_content(message.content, file_policy),
         {:ok, calls} <- convert_calls(message.tool_calls) do
      metadata = portable_metadata(message)

      converted = %{
        message
        | content: content,
          tool_calls: calls,
          reasoning_details: nil,
          metadata: metadata
      }

      {:ok, omit_empty_assistant(converted)}
    end
  end

  @spec portable_metadata(Message.t()) :: map()
  defp portable_metadata(%Message{role: :tool, metadata: metadata}) do
    Map.take(metadata, [
      :is_error,
      :output,
      :minga_effect_status,
      :image_tool_result_delivery,
      :tool_output,
      :req_llm_tool_result_content_source
    ])
  end

  defp portable_metadata(_message), do: %{}

  @spec omit_empty_assistant(Message.t()) :: Message.t() | nil
  defp omit_empty_assistant(%Message{role: :assistant, content: [], tool_calls: calls})
       when calls in [nil, []], do: nil

  defp omit_empty_assistant(message), do: message

  @spec convert_content([ContentPart.t()], file_policy()) ::
          {:ok, [ContentPart.t()]} | {:error, error()}
  defp convert_content(parts, file_policy) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case convert_part(part, file_policy) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  @spec convert_part(ContentPart.t(), file_policy()) ::
          {:ok, ContentPart.t() | nil} | {:error, error()}
  defp convert_part(%ContentPart{type: :thinking}, _file_policy), do: {:ok, nil}

  defp convert_part(
         %ContentPart{type: :provider_block, data: %{"type" => "compaction"}},
         _file_policy
       ),
       do: {:error, :unportable_compaction}

  defp convert_part(
         %ContentPart{type: :provider_block, data: %{type: "compaction"}},
         _file_policy
       ),
       do: {:error, :unportable_compaction}

  defp convert_part(%ContentPart{type: :provider_block}, _file_policy), do: {:ok, nil}

  defp convert_part(%ContentPart{type: :file, data: data} = part, _file_policy)
       when is_binary(data), do: {:ok, %{part | file_id: nil, metadata: %{}}}

  defp convert_part(%ContentPart{type: :file} = part, :retain),
    do: {:ok, %{part | metadata: Map.take(part.metadata, [:req_llm, "req_llm"])}}

  defp convert_part(%ContentPart{type: :file}, :reject), do: {:error, :unportable_attachment}

  defp convert_part(%ContentPart{type: type} = part, _file_policy)
       when type in [:text, :image, :image_url, :video_url], do: {:ok, %{part | metadata: %{}}}

  defp convert_part(_part, _file_policy), do: {:error, :unportable_content}

  @spec convert_calls([ToolCall.t()] | nil) :: {:ok, [ToolCall.t()] | nil} | {:error, error()}
  defp convert_calls(nil), do: {:ok, nil}

  defp convert_calls(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn
      %ToolCall{id: id, function: %{name: name, arguments: arguments}} = call, {:ok, acc}
      when is_binary(id) and id != "" and is_binary(name) and is_binary(arguments) ->
        if ToolCall.builtin?(call) or ToolCall.provider_native?(call) do
          {:cont, {:ok, acc}}
        else
          clean = ToolCall.new(call.id, ToolCall.name(call), ToolCall.args_json(call))
          {:cont, {:ok, [clean | acc]}}
        end

      _call, _acc ->
        {:halt, {:error, :unportable_content}}
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  @spec track_exchange(Message.t() | nil, MapSet.t(String.t())) ::
          {:ok, MapSet.t(String.t())} | {:error, error()}
  defp track_exchange(nil, pending), do: {:ok, pending}

  defp track_exchange(%Message{role: :tool, tool_call_id: id}, pending) do
    if MapSet.member?(pending, id),
      do: {:ok, MapSet.delete(pending, id)},
      else: {:error, :incomplete_tool_exchange}
  end

  defp track_exchange(%Message{tool_calls: calls}, pending) do
    if MapSet.size(pending) == 0 do
      ids = Enum.map(calls || [], & &1.id)
      unique = MapSet.new(ids)

      if MapSet.size(unique) == length(ids),
        do: {:ok, unique},
        else: {:error, :incomplete_tool_exchange}
    else
      {:error, :incomplete_tool_exchange}
    end
  end
end
