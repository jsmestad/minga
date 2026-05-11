defmodule MingaAgent.Hooks.PostToolUsePayload do
  @moduledoc """
  Public payload passed to `PostToolUse` hooks.

  Sent to the hook command's stdin as JSON after a tool has finished executing.
  The `result` field is truncated to avoid massive payloads from verbose tools.
  """

  @max_result_bytes 10_240

  @derive {Jason.Encoder, only: [:event, :tool_call_id, :tool_name, :arguments, :result, :is_error]}
  @enforce_keys [:tool_call_id, :tool_name, :arguments, :result, :is_error]
  defstruct [:tool_call_id, :tool_name, :arguments, :result, :is_error, event: "PostToolUse"]

  @typedoc "Payload for a tool call that just finished executing."
  @type t :: %__MODULE__{
          event: String.t(),
          tool_call_id: String.t(),
          tool_name: String.t(),
          arguments: map(),
          result: String.t(),
          is_error: boolean()
        }

  @doc "Builds a payload from explicit tool call fields."
  @spec new(String.t(), String.t(), map(), String.t(), boolean()) :: t()
  def new(tool_call_id, tool_name, arguments, result, is_error)
      when is_binary(tool_call_id) and is_binary(tool_name) and is_map(arguments) and
             is_binary(result) and is_boolean(is_error) do
    %__MODULE__{
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      arguments: arguments,
      result: truncate_result(result),
      is_error: is_error
    }
  end

  @doc "Builds a payload from a map (e.g. from a tool call struct and its result)."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      tool_call_id: normalize_id(value(attrs, :tool_call_id) || value(attrs, :id)),
      tool_name: to_string(value(attrs, :tool_name) || value(attrs, :name)),
      arguments: normalize_arguments(value(attrs, :arguments) || value(attrs, :args)),
      result: truncate_result(to_string(value(attrs, :result) || "")),
      is_error: value(attrs, :is_error) == true
    }
  end

  @doc "Converts the payload to the JSON object shape used on stdin."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payload) do
    %{
      "event" => payload.event,
      "tool_call_id" => payload.tool_call_id,
      "tool_name" => payload.tool_name,
      "arguments" => payload.arguments,
      "result" => payload.result,
      "is_error" => payload.is_error
    }
  end

  @spec value(map(), atom()) :: term()
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  @spec normalize_id(term()) :: String.t()
  defp normalize_id(nil), do: "tool_#{:erlang.unique_integer([:positive])}"
  defp normalize_id(id), do: to_string(id)

  @spec normalize_arguments(term()) :: map()
  defp normalize_arguments(args) when is_map(args), do: args
  defp normalize_arguments(_args), do: %{}

  @spec truncate_result(String.t()) :: String.t()
  defp truncate_result(result) when byte_size(result) <= @max_result_bytes, do: result

  defp truncate_result(result) do
    binary_part(result, 0, @max_result_bytes) <> "\n... (truncated)"
  end
end
