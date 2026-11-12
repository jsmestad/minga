defmodule MingaAgent.Tool.Invocation do
  @moduledoc "A named tool call correlated to an admitted request and durable checkpoint."

  alias MingaAgent.Session.Request

  @enforce_keys [:request_id, :checkpoint_id, :call_id, :name, :arguments]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          request_id: String.t(),
          checkpoint_id: String.t(),
          call_id: String.t(),
          name: String.t(),
          arguments: map()
        }

  @doc "Captures call identity without accepting authorization or executable values."
  @spec new(Request.t(), String.t(), map()) :: t()
  def new(%Request{} = request, checkpoint_id, call) do
    %__MODULE__{
      request_id: request.request_id,
      checkpoint_id: checkpoint_id,
      call_id: to_string(call.id),
      name: call.name,
      arguments: call.arguments || %{}
    }
  end

  @doc "Returns the session-local one-shot lifecycle key."
  @spec key(t()) :: {String.t(), String.t(), String.t()}
  def key(%__MODULE__{} = invocation),
    do: {invocation.request_id, invocation.checkpoint_id, invocation.call_id}
end
