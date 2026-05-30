defmodule MingaAgent.RemoteAPI.AttachResult do
  @moduledoc "Attach result returned by the remote API broker."

  alias MingaAgent.RemoteAPI.SessionInfo
  alias MingaAgent.Session
  alias MingaAgent.SessionMetadata

  @type role :: :driver | :viewer

  @enforce_keys [:session_id, :pid, :token, :role, :messages, :snapshot, :metadata]
  defstruct [:session_id, :pid, :token, :role, :messages, :snapshot, :metadata]

  @type t :: %__MODULE__{
          session_id: String.t(),
          pid: pid(),
          token: String.t(),
          role: role(),
          messages: [MingaAgent.Message.t()],
          snapshot: Session.editor_snapshot(),
          metadata: SessionMetadata.t()
        }

  @doc "Creates an attach result from session info and snapshot data."
  @spec new(SessionInfo.t(), role(), [MingaAgent.Message.t()], Session.editor_snapshot()) :: t()
  def new(%SessionInfo{} = info, role, messages, snapshot)
      when role in [:driver, :viewer] and is_list(messages) and is_map(snapshot) do
    %__MODULE__{
      session_id: info.session_id,
      pid: info.pid,
      token: info.token,
      role: role,
      messages: messages,
      snapshot: snapshot,
      metadata: info.metadata
    }
  end
end
