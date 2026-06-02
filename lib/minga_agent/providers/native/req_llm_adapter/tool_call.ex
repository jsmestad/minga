defmodule MingaAgent.Providers.Native.ReqLLMAdapter.ToolCall do
  @moduledoc """
  Neutral tool-call payload emitted by the ReqLLM adapter.

  ReqLLM streaming chunks and completed responses have provider-shaped tool-call data. This struct is the stable shape that crosses from the adapter back into `MingaAgent.Providers.Native` for event emission, assistant context reconstruction, and local tool execution.
  """

  @enforce_keys [:id, :name, :arguments]
  defstruct [:id, :name, :arguments]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          arguments: map()
        }

  @doc "Creates a neutral adapter tool-call payload."
  @spec new(String.t(), String.t(), map()) :: t()
  def new(id, name, arguments) when is_binary(id) and is_binary(name) and is_map(arguments) do
    %__MODULE__{id: id, name: name, arguments: arguments}
  end
end
