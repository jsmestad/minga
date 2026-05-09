defmodule MingaAgent.Hooks.PreToolUsePayload do
  @moduledoc """
  Public payload passed to `PreToolUse` hooks.

  The shell runner encodes this payload as JSON and writes it to the hook
  command's standard input. Keep field names stable because user scripts may
  depend on them.
  """

  @derive {Jason.Encoder, only: [:event, :tool_call_id, :tool_name, :arguments]}
  @enforce_keys [:tool_call_id, :tool_name, :arguments]
  defstruct [:tool_call_id, :tool_name, :arguments, event: "PreToolUse"]

  @typedoc "Payload for a tool call about to execute."
  @type t :: %__MODULE__{
          event: String.t(),
          tool_call_id: String.t(),
          tool_name: String.t(),
          arguments: map()
        }

  @doc "Builds a payload from a native provider or runtime tool call map."
  @spec new(map()) :: t()
  def new(tool_call) when is_map(tool_call) do
    %__MODULE__{
      tool_call_id: normalize_id(value(tool_call, :id) || value(tool_call, :tool_call_id)),
      tool_name: to_string(value(tool_call, :name) || value(tool_call, :tool_name)),
      arguments: normalize_arguments(value(tool_call, :arguments) || value(tool_call, :args))
    }
  end

  @doc "Builds a payload from explicit tool call fields."
  @spec new(String.t(), String.t(), map()) :: t()
  def new(tool_call_id, tool_name, arguments)
      when is_binary(tool_call_id) and is_binary(tool_name) and is_map(arguments) do
    %__MODULE__{tool_call_id: tool_call_id, tool_name: tool_name, arguments: arguments}
  end

  @doc "Converts the payload to the JSON object shape used on stdin."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payload) do
    %{
      "event" => payload.event,
      "tool_call_id" => payload.tool_call_id,
      "tool_name" => payload.tool_name,
      "arguments" => payload.arguments
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
end
