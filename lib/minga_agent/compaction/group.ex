defmodule MingaAgent.Compaction.Group do
  @moduledoc """
  One semantic unit in a conversation that compaction never splits.

  A group is the smallest atomic unit for compaction planning:
  - `:system` groups contain consecutive system messages.
  - `:user` groups contain a single user message.
  - `:assistant` groups contain a plain assistant message (no tool calls).
  - `:tool_exchange` groups contain an assistant message with tool calls
    followed by all matching tool-result messages.

  Tool calls and their results always stay together. The compaction planner
  selects complete groups to summarize, never splitting one.
  """

  alias ReqLLM.Message

  @type kind :: :system | :user | :assistant | :tool_exchange

  @type t :: %__MODULE__{
          kind: kind(),
          messages: [Message.t()],
          token_estimate: non_neg_integer()
        }

  @enforce_keys [:kind, :messages, :token_estimate]
  defstruct @enforce_keys

  @doc "Builds a group from classified messages and their token estimate."
  @spec new(kind(), [Message.t()], non_neg_integer()) :: t()
  def new(kind, messages, token_estimate)
      when kind in [:system, :user, :assistant, :tool_exchange] and is_list(messages) and
             is_integer(token_estimate) and token_estimate >= 0 do
    %__MODULE__{kind: kind, messages: messages, token_estimate: token_estimate}
  end
end
