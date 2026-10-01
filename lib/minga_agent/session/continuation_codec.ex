defmodule MingaAgent.Session.ContinuationCodec do
  @moduledoc """
  Explicit JSON-safe codec for the ReqLLM values in a durable continuation.

  The tagged term encoding preserves atom/string map keys, opaque provider
  blocks, reasoning signatures, inline binary attachments, and tool metadata.
  It never reconstructs a missing field from the display transcript.
  """

  alias MingaAgent.Session.Continuation
  alias MingaAgent.Session.Request
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Codec, as: OutputCodec
  alias MingaAgent.Tool.Output.Reference
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.ToolCall

  @version 3
  @legacy_version 2

  @doc "Encodes a continuation boundary and any in-flight effect checkpoint into JSON-safe values."
  @spec encode(Continuation.t()) :: map()
  def encode(%Continuation{} = continuation) do
    %{
      "version" => @version,
      "revision" => continuation.revision,
      "durable_revision" => continuation.durable_revision,
      "provenance" => Atom.to_string(continuation.provenance),
      "messages" => Enum.map(continuation.messages, &encode_term/1),
      "active_request" => encode_request(continuation.active_request),
      "tool_checkpoint" => encode_checkpoint(continuation.tool_checkpoint),
      "boundaries" => Enum.map(continuation.boundaries, &encode_boundary/1),
      "branches" =>
        Map.new(continuation.branch_messages, fn {name, snapshot} ->
          {name,
           %{
             "messages" => Enum.map(snapshot.messages, &encode_term/1),
             "boundaries" => Enum.map(snapshot.boundaries, &encode_boundary/1)
           }}
        end)
    }
  end

  @doc "Decodes the current lossless format and the previous one-way-import format."
  @spec decode(map()) :: {:ok, Continuation.t()} | {:error, term()}
  def decode(%{"version" => version} = encoded) when version in [@legacy_version, @version] do
    required_fields = [
      "provenance",
      "messages",
      "active_request",
      "tool_checkpoint",
      "boundaries",
      "branches",
      "revision",
      "durable_revision"
    ]

    with true <-
           Enum.all?(required_fields, &Map.has_key?(encoded, &1)) ||
             {:error, :invalid_continuation},
         :ok <- validate_version_tags(encoded, version),
         {:ok, provenance} <- decode_provenance(encoded["provenance"]),
         {:ok, messages} <- decode_terms(encoded["messages"]),
         {:ok, active_request} <- decode_request(encoded["active_request"]),
         {:ok, tool_checkpoint} <- decode_checkpoint(encoded["tool_checkpoint"]),
         {:ok, boundaries} <- decode_boundaries(encoded["boundaries"]),
         {:ok, branches} <- decode_branches(encoded["branches"]),
         {:ok, continuation} <-
           Continuation.restore(
             messages,
             encoded["revision"],
             encoded["durable_revision"],
             boundaries,
             branches,
             provenance,
             tool_checkpoint,
             active_request
           ) do
      {:ok, continuation}
    else
      {:error, _reason} = error -> error
    end
  end

  def decode(%{"version" => version}), do: {:error, {:unknown_continuation_version, version}}
  def decode(_encoded), do: {:error, :invalid_continuation}

  @spec validate_version_tags(map(), pos_integer()) :: :ok | {:error, :invalid_continuation}
  defp validate_version_tags(encoded, @legacy_version) do
    if output_tag?(encoded), do: {:error, :invalid_continuation}, else: :ok
  end

  defp validate_version_tags(_encoded, @version), do: :ok

  @spec output_tag?(term()) :: boolean()
  defp output_tag?(%{"$" => "output"}), do: true
  defp output_tag?(value) when is_map(value), do: Enum.any?(Map.values(value), &output_tag?/1)
  defp output_tag?(value) when is_list(value), do: Enum.any?(value, &output_tag?/1)
  defp output_tag?(_value), do: false

  @doc "Returns the unique retained references reachable anywhere in a validated encoded continuation."
  @spec references(map()) :: [Reference.t()]
  def references(encoded) when is_map(encoded) do
    encoded
    |> term_references()
    |> Enum.uniq_by(& &1.token)
  end

  def references(_encoded), do: []

  @spec term_references(term()) :: [Reference.t()]
  defp term_references(%{"$" => "output", "value" => encoded}) do
    case OutputCodec.decode(encoded) do
      {:ok, output} -> Output.references(output)
      {:error, _reason} -> []
    end
  end

  defp term_references(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.flat_map(&term_references/1)
  end

  defp term_references(value) when is_list(value), do: Enum.flat_map(value, &term_references/1)
  defp term_references(_value), do: []

  @spec encode_request(Request.t() | nil) :: map() | nil
  defp encode_request(nil), do: nil

  defp encode_request(%Request{} = request) do
    %{
      "version" => request.version,
      "request_id" => request.request_id,
      "turn_id" => request.turn_id,
      "conversation_revision" => request.conversation_revision,
      "messages" => Enum.map(request.messages, &encode_term/1)
    }
  end

  @spec decode_request(term()) :: {:ok, Request.t() | nil} | {:error, term()}
  defp decode_request(nil), do: {:ok, nil}

  defp decode_request(%{
         "version" => 1,
         "request_id" => request_id,
         "turn_id" => turn_id,
         "conversation_revision" => conversation_revision,
         "messages" => encoded_messages
       })
       when is_binary(request_id) and is_integer(turn_id) and turn_id > 0 and
              is_integer(conversation_revision) and conversation_revision >= 0 do
    with {:ok, messages} <- decode_terms(encoded_messages) do
      {:ok, Request.new(request_id, turn_id, conversation_revision, messages)}
    end
  end

  defp decode_request(_request), do: {:error, :invalid_active_request}

  @spec encode_checkpoint(Continuation.tool_checkpoint() | nil) :: map() | nil
  defp encode_checkpoint(nil), do: nil

  defp encode_checkpoint(checkpoint) do
    %{
      "version" => checkpoint.version,
      "checkpoint_id" => checkpoint.checkpoint_id,
      "request_id" => checkpoint.request_id,
      "messages" => Enum.map(checkpoint.messages, &encode_term/1),
      "calls" => Enum.map(checkpoint.calls, &encode_checkpoint_call/1)
    }
  end

  @spec encode_checkpoint_call(Continuation.checkpoint_call()) :: map()
  defp encode_checkpoint_call(call) do
    %{
      "tool_call_id" => call.tool_call_id,
      "name" => call.name,
      "arguments" => encode_term(call.arguments),
      "status" => encode_checkpoint_status(call.status)
    }
  end

  @spec encode_checkpoint_status(Continuation.tool_call_status()) :: map()
  defp encode_checkpoint_status(:pending), do: %{"kind" => "pending"}
  defp encode_checkpoint_status(:admitted), do: %{"kind" => "admitted"}

  defp encode_checkpoint_status({:completed, result_message}),
    do: %{"kind" => "completed", "result_message" => encode_term(result_message)}

  @spec decode_checkpoint(term()) ::
          {:ok, Continuation.tool_checkpoint() | nil} | {:error, term()}
  defp decode_checkpoint(nil), do: {:ok, nil}

  defp decode_checkpoint(%{
         "version" => 1,
         "checkpoint_id" => checkpoint_id,
         "request_id" => request_id,
         "messages" => encoded_messages,
         "calls" => encoded_calls
       })
       when is_binary(checkpoint_id) and is_binary(request_id) and is_list(encoded_calls) do
    with {:ok, messages} <- decode_terms(encoded_messages),
         {:ok, calls} <- decode_list(encoded_calls, &decode_checkpoint_call/1) do
      {:ok,
       %{
         version: 1,
         checkpoint_id: checkpoint_id,
         request_id: request_id,
         messages: messages,
         calls: calls
       }}
    end
  end

  defp decode_checkpoint(%{"version" => version}),
    do: {:error, {:unknown_tool_checkpoint_version, version}}

  defp decode_checkpoint(_checkpoint), do: {:error, :invalid_tool_checkpoint}

  @spec decode_checkpoint_call(term()) ::
          {:ok, Continuation.checkpoint_call()} | {:error, term()}
  defp decode_checkpoint_call(%{
         "tool_call_id" => tool_call_id,
         "name" => name,
         "arguments" => encoded_arguments,
         "status" => encoded_status
       })
       when is_binary(tool_call_id) and is_binary(name) do
    with {:ok, arguments} when is_map(arguments) <- decode_term(encoded_arguments),
         {:ok, status} <- decode_checkpoint_status(encoded_status) do
      {:ok, %{tool_call_id: tool_call_id, name: name, arguments: arguments, status: status}}
    else
      {:ok, _not_a_map} -> {:error, :invalid_checkpoint_arguments}
      {:error, _reason} = error -> error
    end
  end

  defp decode_checkpoint_call(_call), do: {:error, :invalid_checkpoint_call}

  @spec decode_checkpoint_status(term()) ::
          {:ok, Continuation.tool_call_status()} | {:error, term()}
  defp decode_checkpoint_status(%{"kind" => "pending"}), do: {:ok, :pending}
  defp decode_checkpoint_status(%{"kind" => "admitted"}), do: {:ok, :admitted}

  defp decode_checkpoint_status(%{
         "kind" => "completed",
         "result_message" => encoded_result
       }) do
    case decode_term(encoded_result) do
      {:ok, %Message{} = result_message} -> {:ok, {:completed, result_message}}
      {:ok, _not_a_message} -> {:error, :invalid_checkpoint_result}
      {:error, _reason} = error -> error
    end
  end

  defp decode_checkpoint_status(_status), do: {:error, :invalid_checkpoint_status}

  @spec decode_provenance(term()) ::
          {:ok, Continuation.provenance()} | {:error, :invalid_continuation_provenance}
  defp decode_provenance("lossless"), do: {:ok, :lossless}
  defp decode_provenance("legacy_reconstructed"), do: {:ok, :legacy_reconstructed}
  defp decode_provenance(_provenance), do: {:error, :invalid_continuation_provenance}

  @spec encode_boundary(Continuation.boundary()) :: map()
  defp encode_boundary(boundary) do
    %{
      "transcript_id" => boundary.transcript_id,
      "message_count" => boundary.message_count,
      "revision" => boundary.revision
    }
  end

  @spec decode_boundaries(term()) :: {:ok, [Continuation.boundary()]} | {:error, term()}
  defp decode_boundaries(boundaries) when is_list(boundaries) do
    decode_list(boundaries, &decode_boundary/1)
  end

  defp decode_boundaries(_boundaries), do: {:error, :invalid_continuation_boundaries}

  @spec decode_boundary(term()) :: {:ok, Continuation.boundary()} | {:error, term()}
  defp decode_boundary(%{
         "transcript_id" => transcript_id,
         "message_count" => message_count,
         "revision" => revision
       })
       when is_integer(transcript_id) and transcript_id > 0 and is_integer(message_count) and
              message_count >= 0 and is_integer(revision) and revision >= 0 do
    {:ok, %{transcript_id: transcript_id, message_count: message_count, revision: revision}}
  end

  defp decode_boundary(_boundary), do: {:error, :invalid_continuation_boundary}

  @spec decode_branches(term()) ::
          {:ok, %{String.t() => Continuation.branch_snapshot()}} | {:error, term()}
  defp decode_branches(branches) when is_map(branches) do
    Enum.reduce_while(branches, {:ok, %{}}, fn
      {name, %{"messages" => encoded_messages, "boundaries" => encoded_boundaries}}, {:ok, acc}
      when is_binary(name) ->
        with {:ok, messages} <- decode_terms(encoded_messages),
             {:ok, boundaries} <- decode_boundaries(encoded_boundaries) do
          snapshot = %{messages: messages, boundaries: boundaries}
          {:cont, {:ok, Map.put(acc, name, snapshot)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_continuation_branches}}
    end)
  end

  defp decode_branches(_branches), do: {:error, :invalid_continuation_branches}

  @spec encode_term(term()) :: term()
  defp encode_term(%Output{} = output) do
    %{"$" => "output", "value" => OutputCodec.encode(output)}
  end

  defp encode_term(%Message{} = message) do
    %{
      "$" => "message",
      "role" => encode_term(message.role),
      "content" => encode_term(message.content),
      "name" => encode_term(message.name),
      "tool_call_id" => encode_term(message.tool_call_id),
      "tool_calls" => encode_term(message.tool_calls),
      "metadata" => encode_term(message.metadata),
      "reasoning_details" => encode_term(message.reasoning_details)
    }
  end

  defp encode_term(%ContentPart{} = part) do
    %{
      "$" => "content_part",
      "type" => encode_term(part.type),
      "text" => encode_term(part.text),
      "url" => encode_term(part.url),
      "data" => encode_term(part.data),
      "file_id" => encode_term(part.file_id),
      "media_type" => encode_term(part.media_type),
      "filename" => encode_term(part.filename),
      "metadata" => encode_term(part.metadata)
    }
  end

  defp encode_term(%ReasoningDetails{} = detail) do
    %{
      "$" => "reasoning",
      "text" => encode_term(detail.text),
      "signature" => encode_term(detail.signature),
      "encrypted" => detail.encrypted?,
      "provider" => encode_term(detail.provider),
      "format" => encode_term(detail.format),
      "index" => detail.index,
      "provider_data" => encode_term(detail.provider_data)
    }
  end

  defp encode_term(%ToolCall{} = tool_call) do
    %{
      "$" => "tool_call",
      "id" => encode_term(tool_call.id),
      "type" => encode_term(tool_call.type),
      "function" => encode_term(tool_call.function)
    }
  end

  defp encode_term(value) when is_binary(value) do
    if String.valid?(value) do
      %{"$" => "string", "value" => value}
    else
      %{"$" => "binary", "value" => Base.encode64(value)}
    end
  end

  defp encode_term(value) when is_atom(value),
    do: %{"$" => "atom", "value" => Atom.to_string(value)}

  defp encode_term(value) when is_tuple(value),
    do: %{"$" => "tuple", "value" => value |> Tuple.to_list() |> Enum.map(&encode_term/1)}

  defp encode_term(value) when is_map(value) do
    entries = Enum.map(value, fn {key, item} -> [encode_term(key), encode_term(item)] end)
    %{"$" => "map", "value" => entries}
  end

  defp encode_term(value) when is_list(value), do: Enum.map(value, &encode_term/1)
  defp encode_term(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value

  @spec decode_terms(term()) :: {:ok, [term()]} | {:error, term()}
  defp decode_terms(values) when is_list(values), do: decode_list(values, &decode_term/1)
  defp decode_terms(_values), do: {:error, :invalid_continuation_messages}

  @spec decode_term(term()) :: {:ok, term()} | {:error, term()}
  defp decode_term(%{"$" => "output", "value" => encoded}) do
    OutputCodec.decode(encoded)
  end

  defp decode_term(%{"$" => "message"} = value) do
    with {:ok, role} <- decode_term(value["role"]),
         {:ok, content} <- decode_term(value["content"]),
         {:ok, name} <- decode_term(value["name"]),
         {:ok, tool_call_id} <- decode_term(value["tool_call_id"]),
         {:ok, tool_calls} <- decode_term(value["tool_calls"]),
         {:ok, metadata} <- decode_term(value["metadata"]),
         {:ok, reasoning_details} <- decode_term(value["reasoning_details"]) do
      {:ok,
       %Message{
         role: role,
         content: content,
         name: name,
         tool_call_id: tool_call_id,
         tool_calls: tool_calls,
         metadata: metadata,
         reasoning_details: reasoning_details
       }}
    end
  end

  defp decode_term(%{"$" => "content_part"} = value) do
    with {:ok, type} <- decode_term(value["type"]),
         {:ok, text} <- decode_term(value["text"]),
         {:ok, url} <- decode_term(value["url"]),
         {:ok, data} <- decode_term(value["data"]),
         {:ok, file_id} <- decode_term(value["file_id"]),
         {:ok, media_type} <- decode_term(value["media_type"]),
         {:ok, filename} <- decode_term(value["filename"]),
         {:ok, metadata} <- decode_term(value["metadata"]) do
      {:ok,
       %ContentPart{
         type: type,
         text: text,
         url: url,
         data: data,
         file_id: file_id,
         media_type: media_type,
         filename: filename,
         metadata: metadata
       }}
    end
  end

  defp decode_term(%{"$" => "reasoning"} = value) do
    with {:ok, text} <- decode_term(value["text"]),
         {:ok, signature} <- decode_term(value["signature"]),
         {:ok, provider} <- decode_term(value["provider"]),
         {:ok, format} <- decode_term(value["format"]),
         {:ok, provider_data} <- decode_term(value["provider_data"]) do
      {:ok,
       %ReasoningDetails{
         text: text,
         signature: signature,
         encrypted?: value["encrypted"] == true,
         provider: provider,
         format: format,
         index: value["index"] || 0,
         provider_data: provider_data
       }}
    end
  end

  defp decode_term(%{"$" => "tool_call"} = value) do
    with {:ok, id} <- decode_term(value["id"]),
         {:ok, type} <- decode_term(value["type"]),
         {:ok, function} <- decode_term(value["function"]) do
      {:ok, %ToolCall{id: id, type: type, function: function}}
    end
  end

  defp decode_term(%{"$" => "string", "value" => value}) when is_binary(value), do: {:ok, value}

  defp decode_term(%{"$" => "binary", "value" => value}) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_continuation_binary}
    end
  end

  defp decode_term(%{"$" => "atom", "value" => value}) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, {:unknown_continuation_atom, value}}
  end

  defp decode_term(%{"$" => "tuple", "value" => values}) when is_list(values) do
    with {:ok, items} <- decode_list(values, &decode_term/1), do: {:ok, List.to_tuple(items)}
  end

  defp decode_term(%{"$" => "map", "value" => entries}) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      [encoded_key, encoded_value], {:ok, acc} ->
        with {:ok, key} <- decode_term(encoded_key),
             {:ok, value} <- decode_term(encoded_value) do
          {:cont, {:ok, Map.put(acc, key, value)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_continuation_map}}
    end)
  end

  defp decode_term(values) when is_list(values), do: decode_list(values, &decode_term/1)

  defp decode_term(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: {:ok, value}

  defp decode_term(_value), do: {:error, :invalid_continuation_term}

  @spec decode_list([term()], (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  defp decode_list(values, decoder) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case decoder.(value) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end
end
