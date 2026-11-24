defmodule MingaEditor.Agent.WorkspaceStatus do
  @moduledoc """
  Decides the one Agent status that every surface shows for a workspace.

  The workspace pill, the Agent tab dot, the Agent activity strip, the status bar's Agent indicator and the Agent chat header all read this decision, so they cannot disagree. Each surface keeps its own mapping from this status to its wire enum.

  The rules, in order:

  1. A failed Agent start needs the user (`:needs_you`), whatever the runtime last reported.
  2. The active Agent workspace, while it is attached to a Session (local or remote), shows the live shell presentation cache: a pending question needs the user, otherwise the display status, which includes a pending approval.
  3. Any other Agent workspace (a background workspace, or an active one with no Session attached) shows the status stored on its payload by Session events.
  4. Outside an Agent workspace (the manual workspace, or a shell without workspaces), the live presentation cache is the only source; without one the status is `:idle`.
  """

  alias MingaEditor.Agent.PendingQuestion
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent
  alias MingaEditor.State.Workspace.RemoteSession

  @typedoc "The Agent status of one workspace."
  @type t :: Workspace.agent_status() | :needs_you

  @doc """
  Returns the Agent status of `workspace`.

  Pass the live shell presentation cache as `live` only when `workspace` is the active workspace; pass `nil` for a background workspace. `ui` is the workspace's Agent UI state: the live one for the active workspace, the stored one otherwise.
  """
  @spec resolve(Workspace.t() | nil, AgentState.t() | nil, UIState.t() | nil) :: t()
  def resolve(_workspace, _live, %UIState{chat_lifecycle: {:failed, _failure}}), do: :needs_you

  def resolve(%Workspace{payload: %WorkspaceAgent{} = payload}, %AgentState{} = live, _ui) do
    if attached?(payload), do: live_status(live), else: payload.agent_status
  end

  def resolve(%Workspace{payload: %WorkspaceAgent{agent_status: status}}, nil, _ui), do: status
  def resolve(_workspace, %AgentState{} = live, _ui), do: live_status(live)
  def resolve(_workspace, nil, _ui), do: :idle

  @doc """
  Returns the Agent status of the active workspace in `shell_state`, with `ui` as its live Agent UI state.

  Surfaces that show only the active workspace (the activity strip, the status bar, the chat header) call this.
  """
  @spec active(term(), UIState.t() | nil) :: t()
  def active(shell_state, ui),
    do: shell_state |> active_workspace() |> resolve(live_agent(shell_state), ui)

  @spec active_workspace(term()) :: Workspace.t() | nil
  defp active_workspace(%TraditionalState{} = shell_state) do
    case TraditionalState.tab_bar(shell_state) do
      %TabBar{} = tab_bar -> TabBar.active_workspace(tab_bar)
      nil -> nil
    end
  end

  defp active_workspace(_shell_state), do: nil

  @doc "Returns the live shell presentation cache from a shell state snapshot, or nil for another shell."
  @spec live_agent(term()) :: AgentState.t() | nil
  def live_agent(%TraditionalState{} = shell_state), do: TraditionalState.agent(shell_state)
  def live_agent(_shell_state), do: nil

  @spec attached?(WorkspaceAgent.t()) :: boolean()
  defp attached?(%WorkspaceAgent{session: session}) when is_pid(session), do: true
  defp attached?(%WorkspaceAgent{remote_session: %RemoteSession{}}), do: true
  defp attached?(%WorkspaceAgent{}), do: false

  @spec live_status(AgentState.t()) :: t()
  defp live_status(%AgentState{pending_question: %PendingQuestion{}}), do: :needs_you
  defp live_status(%AgentState{} = live), do: AgentState.display_status(live)
end
