defmodule MingaEditor.State.Tab.Agent do
  @moduledoc "Agent-tab payload owned by `MingaEditor.State.Tab`."
  defstruct session: nil,
            agent_status: nil,
            server_name: nil,
            remote_session_id: nil,
            connection_status: nil,
            attention: false,
            background_subagent: nil

  @type t :: %__MODULE__{
          session: pid() | nil,
          agent_status: MingaEditor.State.Workspace.agent_status(),
          server_name: String.t() | nil,
          remote_session_id: String.t() | nil,
          connection_status: MingaEditor.State.Workspace.RemoteSession.connection_status() | nil,
          attention: boolean(),
          background_subagent: MingaAgent.Subagent.Handle.t() | nil
        }
end
