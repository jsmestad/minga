defmodule MingaEditor.State.Workspace.Agent do
  @moduledoc "Agent-workspace payload."

  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.ProjectView
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State.Workspace.RemoteSession

  @type t :: %__MODULE__{
          session: pid() | nil,
          agent_status: MingaEditor.State.Workspace.agent_status(),
          remote_session: RemoteSession.t() | nil,
          agent_ui: UIState.t() | nil,
          project_view: ProjectView.t() | nil,
          pending_catchup_events: [EventRecord.t()]
        }

  defstruct session: nil,
            agent_status: :idle,
            remote_session: nil,
            agent_ui: UIState.new(),
            project_view: nil,
            pending_catchup_events: []
end
