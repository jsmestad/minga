defmodule MingaEditor.TabWorkflow do
  @moduledoc """
  External and presentation workflow around pure root tab transitions.

  Registry validation, remote event replay, agent session snapshots, transcript
  reads, spinner timers, and modal presentation stay here. `MingaEditor.State`
  installs only the atomic immutable tab transition.
  """

  alias MingaEditor.Agent.UIState
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Remote.EventReplay
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.Shell.Workflow, as: ShellWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.WorkspaceWorkflow

  @doc "Switches tabs and performs the external work requested by the pure transition result."
  @spec switch(EditorState.t(), Tab.id()) :: EditorState.t()
  def switch(%EditorState{} = state, target_id) do
    state = ShellWorkflow.ensure_available(state)

    case EditorState.switch_tab(state, target_id) do
      {state, :unchanged} ->
        state

      {transitioned, {:switched, %Tab{} = target}} ->
        transitioned = finish_switch(transitioned, target)
        WorkspaceWorkflow.persist_changes(state, transitioned)
    end
  end

  @doc "Restores a context and synchronizes its workspace-backed agent presentation."
  @spec restore_context(EditorState.t(), Tab.context() | Tab.legacy_context()) :: EditorState.t()
  def restore_context(%EditorState{} = state, context) when is_map(context) do
    state
    |> EditorState.restore_tab_context(context)
    |> sync_active_workspace_agent_ui()
  end

  @doc "Synchronizes the live agent projection and replays pending foreground catch-up events."
  @spec sync_active_workspace_agent_ui(EditorState.t()) :: EditorState.t()
  def sync_active_workspace_agent_ui(
        %EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}} = state
      ) do
    case TraditionalState.tab_bar(shell_state) do
      %TabBar{} = tab_bar -> sync_from_tab_bar(state, tab_bar)
      nil -> state
    end
  end

  def sync_active_workspace_agent_ui(%EditorState{} = state), do: state

  @spec finish_switch(EditorState.t(), Tab.t()) :: EditorState.t()
  defp finish_switch(state, target) do
    state
    |> sync_active_workspace_agent_ui()
    |> ModalWorkflow.dismiss_if_stale()
    |> TraditionalWorkflow.install_agent_spinner_stop()
    |> rebuild_switched_agent(target)
    |> maybe_restart_incoming_spinner()
  end

  @spec sync_from_tab_bar(EditorState.t(), TabBar.t()) :: EditorState.t()
  defp sync_from_tab_bar(state, tab_bar) do
    agent_ui = active_workspace_agent_ui(state, tab_bar)
    workspace = SessionState.set_agent_ui(state.workspace, agent_ui)
    state = %{state | workspace: workspace}
    replay_pending_events(state, tab_bar)
  end

  @spec active_workspace_agent_ui(EditorState.t(), TabBar.t()) :: UIState.t()
  defp active_workspace_agent_ui(state, tab_bar) do
    agent_ui =
      case TabBar.active_workspace(tab_bar) do
        %Workspace{agent_ui: %UIState{} = agent_ui} -> agent_ui
        _missing -> UIState.new()
      end

    activate_agent_ui(state.workspace, agent_ui)
  end

  @spec activate_agent_ui(SessionState.t(), UIState.t()) :: UIState.t()
  defp activate_agent_ui(%SessionState{keymap_scope: :agent} = workspace, agent_ui) do
    UIState.activate(agent_ui, workspace.windows, workspace.file_tree)
  end

  defp activate_agent_ui(%SessionState{}, agent_ui), do: agent_ui

  @spec replay_pending_events(EditorState.t(), TabBar.t()) :: EditorState.t()
  defp replay_pending_events(state, tab_bar) do
    case TabBar.active_workspace(tab_bar) do
      %Workspace{id: workspace_id, pending_catchup_events: [_ | _] = events} ->
        state = EventReplay.replay_active(state, events)
        clear_replayed_events(state, workspace_id)

      _none ->
        state
    end
  end

  @spec clear_replayed_events(EditorState.t(), non_neg_integer()) :: EditorState.t()
  defp clear_replayed_events(
         %EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}} = state,
         workspace_id
       ) do
    tab_bar = TraditionalState.tab_bar(shell_state)
    tab_bar = TabBar.clear_workspace_catchup_events(tab_bar, workspace_id)
    shell_state = TraditionalState.install_tab_bar(shell_state, tab_bar)

    %{
      state
      | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  @spec rebuild_switched_agent(EditorState.t(), Tab.t()) :: EditorState.t()
  defp rebuild_switched_agent(state, %Tab{kind: :agent} = tab) do
    state
    |> AgentLifecycle.rebuild_agent_from_session(tab)
    |> AgentLifecycle.sync_transcript()
  end

  defp rebuild_switched_agent(state, %Tab{} = tab) do
    AgentLifecycle.rebuild_agent_from_session(state, tab)
  end

  @spec maybe_restart_incoming_spinner(EditorState.t()) :: EditorState.t()
  defp maybe_restart_incoming_spinner(
         %EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}} = state
       ) do
    agent = TraditionalState.agent(shell_state)

    if AgentState.busy?(agent) and agent.spinner_timer == nil do
      TraditionalWorkflow.install_agent_spinner_start(state)
    else
      state
    end
  end

  defp maybe_restart_incoming_spinner(%EditorState{} = state), do: state
end
