defmodule MingaAgent.Providers.Native.ReqLLMAdapter.TurnResult do
  @moduledoc """
  Decoded result from one ReqLLM provider response.

  The adapter owns the ReqLLM response shape. Native consumes this struct to decide whether the turn is complete or should continue through tool execution.
  """

  alias MingaAgent.Providers.Native.ReqLLMAdapter

  @enforce_keys [:text, :tool_calls, :usage]
  defstruct [:text, :tool_calls, :usage]

  @type t :: %__MODULE__{
          text: String.t(),
          tool_calls: [ReqLLMAdapter.ToolCall.t()],
          usage: ReqLLMAdapter.raw_usage() | nil
        }

  @doc "Creates a decoded turn result for Native orchestration."
  @spec new(String.t(), [ReqLLMAdapter.ToolCall.t()], ReqLLMAdapter.raw_usage() | nil) :: t()
  def new(text, tool_calls, usage) when is_binary(text) and is_list(tool_calls) do
    %__MODULE__{text: text, tool_calls: tool_calls, usage: usage}
  end
end
