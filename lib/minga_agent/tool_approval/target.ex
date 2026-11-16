defmodule MingaAgent.ToolApproval.Target do
  @moduledoc """
  Immutable identity of one displayed approval in an admitted session request.

  The request ID identifies the admitted provider turn. Tool call IDs alone cannot distinguish a stale control from a later request that reuses an ID.
  """

  @derive JSON.Encoder
  @enforce_keys [:session_id, :request_id, :tool_call_id]
  defstruct [:session_id, :request_id, :tool_call_id]

  @type t :: %__MODULE__{
          session_id: String.t(),
          request_id: String.t(),
          tool_call_id: String.t()
        }

  @doc "Captures the session, admitted request and tool call shown by an approval control."
  @spec new(String.t(), String.t(), String.t()) :: t()
  def new(session_id, request_id, tool_call_id)
      when is_binary(session_id) and is_binary(request_id) and is_binary(tool_call_id) do
    %__MODULE__{session_id: session_id, request_id: request_id, tool_call_id: tool_call_id}
  end
end
