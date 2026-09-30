defmodule MingaAgent.Providers.Native.ReqLLMAdapter.TurnResult do
  @moduledoc """
  Decoded result from one ReqLLM provider response.

  The adapter owns the ReqLLM response shape. Native consumes this struct to decide whether the turn is complete or should continue through tool execution.
  """

  alias MingaAgent.Providers.Native.ReqLLMAdapter
  alias ReqLLM.Message

  @enforce_keys [:message, :tool_calls, :usage]
  defstruct [:message, :tool_calls, :usage]

  @type t :: %__MODULE__{
          message: Message.t(),
          tool_calls: [ReqLLMAdapter.ToolCall.t()],
          usage: ReqLLMAdapter.raw_usage() | nil
        }

  @doc "Creates a decoded turn result while retaining the complete assistant message."
  @spec new(
          Message.t(),
          [ReqLLMAdapter.ToolCall.t()],
          ReqLLMAdapter.raw_usage() | nil
        ) :: t()
  def new(%Message{role: :assistant} = message, tool_calls, usage)
      when is_list(tool_calls) do
    %__MODULE__{message: message, tool_calls: tool_calls, usage: usage}
  end
end
