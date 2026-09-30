defmodule MingaAgent.Session.Outcome do
  @moduledoc """
  Complete model-continuation outcome returned by a provider worker.

  Request identity and the source conversation revision let Session reject a
  late or duplicate outcome without changing the durable boundary.
  """

  alias MingaAgent.Session.Request
  alias ReqLLM.Message

  @enforce_keys [:request_id, :turn_id, :conversation_revision, :messages]
  defstruct version: 1, request_id: nil, turn_id: nil, conversation_revision: 0, messages: []

  @type t :: %__MODULE__{
          version: pos_integer(),
          request_id: String.t(),
          turn_id: pos_integer(),
          conversation_revision: non_neg_integer(),
          messages: [Message.t()]
        }

  @doc "Builds a completed outcome for the exact request snapshot."
  @spec new(Request.t(), [Message.t()]) :: t()
  def new(%Request{} = request, messages) when is_list(messages) do
    %__MODULE__{
      request_id: request.request_id,
      turn_id: request.turn_id,
      conversation_revision: request.conversation_revision,
      messages: messages
    }
  end
end
