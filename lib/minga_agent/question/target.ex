defmodule MingaAgent.Question.Target do
  @moduledoc "Identity of the session, admitted request, checkpoint and tool call that asked a clarification."

  @derive JSON.Encoder
  @enforce_keys [:session_id, :request_id, :checkpoint_id, :tool_call_id]
  defstruct [:session_id, :request_id, :checkpoint_id, :tool_call_id]

  @type t :: %__MODULE__{
          session_id: String.t(),
          request_id: String.t(),
          checkpoint_id: String.t(),
          tool_call_id: String.t()
        }
end
