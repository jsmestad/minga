defmodule MingaAgent.RemoteAPI.SessionInfo do
  @moduledoc "Session record returned by the remote API broker."

  alias MingaAgent.SessionMetadata

  @enforce_keys [:session_id, :pid, :token, :metadata]
  defstruct [:session_id, :pid, :token, :metadata]

  @type t :: %__MODULE__{
          session_id: String.t(),
          pid: pid(),
          token: String.t(),
          metadata: SessionMetadata.t()
        }

  @doc "Creates a session info record."
  @spec new(String.t(), pid(), String.t(), SessionMetadata.t()) :: t()
  def new(session_id, pid, token, %SessionMetadata{} = metadata)
      when is_binary(session_id) and is_pid(pid) and is_binary(token) do
    %__MODULE__{session_id: session_id, pid: pid, token: token, metadata: metadata}
  end
end
