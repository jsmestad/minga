defmodule MingaAgent.Session.Request do
  @moduledoc """
  Immutable, versioned request snapshot handed from a Session to a provider worker.

  The snapshot carries the exact ReqLLM values for one request. Providers may
  consume it and return an outcome, but they do not own or mutate conversation
  history.
  """

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

  @doc "Creates the immutable snapshot for one admitted request."
  @spec new(String.t(), pos_integer(), non_neg_integer(), [Message.t()]) :: t()
  def new(request_id, turn_id, conversation_revision, messages)
      when is_binary(request_id) and is_integer(turn_id) and turn_id > 0 and
             is_integer(conversation_revision) and conversation_revision >= 0 and
             is_list(messages) do
    %__MODULE__{
      request_id: request_id,
      turn_id: turn_id,
      conversation_revision: conversation_revision,
      messages: messages
    }
  end
end
