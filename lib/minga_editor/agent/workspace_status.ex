defmodule MingaEditor.Agent.WorkspaceStatus do
  @moduledoc """
  Decides the one Agent status that every surface shows for a workspace.

  The workspace pill, the Agent tab dot, the Agent activity strip, the status bar's Agent indicator and the Agent chat header all read this decision, so they cannot disagree. Every surface names the status through the `[[agent_statuses]]` table in `docs/design_tokens.toml` (`Minga.Design.Tokens.agent_status_state/1` and `agent_status_wire/1`, generated for Swift and Go too), so the words agree as well.

  The rules, in order:

  1. A failed Agent start needs the user (`:needs_you`), whatever the runtime last reported.
  2. The active Agent workspace, while it is attached to a Session (local or remote), shows the live shell presentation cache: a pending question needs the user, otherwise the display status, which includes a pending approval.
  3. Any other Agent workspace (a background workspace, or an active one with no Session attached) shows the status stored on its payload by Session events.
  4. With a file in front (the manual workspace), the status is the stored status of the conversation shown last: the workspace that owns the Session the live cache was built from. Session events reach the live cache only while its conversation is in front, so the cache's own status is a copy from the moment the conversation left; the stored status is the one the Spaces bar shows for that conversation. When that Session has ended, the status is `:idle`.
  5. A shell without workspaces, or a live cache that presents no Session, has the live presentation cache as its only source; without one the status is `:idle`.
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
  Returns the Agent status of `workspace` as one row of a workspace list.

  `active_workspace_id` names the active workspace. Only that workspace receives the live shell presentation cache `live_agent` and the live Agent UI `live_ui`. Every other workspace receives no live cache and uses its stored payload UI. A non-Agent workspace resolves from the stored UI only, so callers should filter to Agent workspaces when they show an Agent status.
  """
  @spec resolve_in(
          Workspace.t(),
          non_neg_integer() | nil,
          AgentState.t() | nil,
          UIState.t() | nil
        ) ::
          t()
  def resolve_in(%Workspace{id: id} = workspace, id, live_agent, live_ui),
    do: resolve(workspace, live_agent, live_ui)

  def resolve_in(
        %Workspace{payload: %WorkspaceAgent{agent_ui: ui}} = workspace,
        _active,
        _live,
        _live_ui
      ),
      do: resolve(workspace, nil, ui)

  def resolve_in(%Workspace{} = workspace, _active, _live, _live_ui),
    do: resolve(workspace, nil, nil)

  @doc """
  Returns the Agent status of the active workspace in `shell_state`, with `ui` as its live Agent UI state.

  Surfaces that show only the active workspace (the activity strip, the status bar, the chat header) call this.
  """
  @spec active(term(), UIState.t() | nil) :: t()
  def active(%TraditionalState{} = shell_state, ui) do
    live = TraditionalState.agent(shell_state)

    case TraditionalState.tab_bar(shell_state) do
      %TabBar{} = tab_bar -> resolve_active(tab_bar, TabBar.active_workspace(tab_bar), live, ui)
      nil -> resolve(nil, live, ui)
    end
  end

  def active(_shell_state, ui), do: resolve(nil, nil, ui)

  # With a file in front, the conversation shown last speaks through its own workspace's stored status.
  @spec resolve_active(TabBar.t(), Workspace.t() | nil, AgentState.t(), UIState.t() | nil) :: t()
  defp resolve_active(_tab_bar, %Workspace{payload: %WorkspaceAgent{}} = active, live, ui),
    do: resolve(active, live, ui)

  defp resolve_active(
         _tab_bar,
         active,
         _live,
         %UIState{chat_lifecycle: {:failed, _failure}} = ui
       ),
       do: resolve(active, nil, ui)

  defp resolve_active(tab_bar, active, %AgentState{} = live, ui) do
    case AgentState.session(live) do
      nil -> resolve(active, live, ui)
      session -> tab_bar |> TabBar.find_workspace_by_session(session) |> shown_last_status()
    end
  end

  @spec shown_last_status(Workspace.t() | nil) :: t()
  defp shown_last_status(%Workspace{payload: %WorkspaceAgent{agent_ui: ui}} = workspace),
    do: resolve(workspace, nil, ui)

  defp shown_last_status(nil), do: :idle

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
