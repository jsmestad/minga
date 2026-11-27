defmodule MingaEditor.TabWorkflow do
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent

  @moduledoc """
  External and presentation workflow around pure root tab transitions.

  Registry validation, remote event replay, agent session snapshots, transcript
  reads, spinner timers, and modal presentation stay here. `MingaEditor.State`
  installs only the atomic immutable tab transition.
  """

  alias MingaEditor.Agent.Arrival
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.UIState
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.HighlightSync
  alias MingaEditor.NativeIPC.NavigationFinalizer
  alias MingaEditor.Remote.EventReplay
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.InFileReview
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.TaskReviewWorkflow
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.Shell.Workflow, as: ShellWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.UI.Picker.AgentChecklistSource
  alias MingaEditor.UI.Picker.AgentDraftAttachmentSource
  alias MingaEditor.UI.Picker.AgentHistorySource
  alias MingaEditor.UI.Picker.AgentRetainedOutputSource
  alias MingaEditor.Viewport
  alias MingaEditor.WorkspaceWorkflow

  @opaque staged_switch ::
            {:unchanged, EditorState.t()}
            | {:switched, EditorState.t(), EditorState.t(), Tab.t(), pid() | nil}

  @doc "Creates an inactive Agent tab with its semantic pane context."
  @spec insert_agent(TabBar.t(), String.t(), Viewport.t(), String.t() | nil) ::
          {TabBar.t(), Tab.t()}
  def insert_agent(%TabBar{} = tabs, label, %Viewport{} = viewport, project_root) do
    insert_agent(tabs, label, Context.new_agent(viewport, project_root))
  end

  @doc "Creates an inactive Agent tab with an already prepared tab context."
  @spec insert_agent(TabBar.t(), String.t(), Context.t()) :: {TabBar.t(), Tab.t()}
  def insert_agent(%TabBar{} = tabs, label, %Context{} = context) do
    {tabs, tab} = TabBar.insert(tabs, :agent, label)
    tab = Tab.set_context(tab, context)
    {TabBar.accept_tab(tabs, tab), tab}
  end

  @doc "Switches tabs and performs the external work requested by the pure transition result."
  @spec switch(EditorState.t(), Tab.id()) :: EditorState.t()
  def switch(%EditorState{} = state, target_id) do
    state = ShellWorkflow.ensure_available(state)

    case switch_target(state, target_id) do
      :unchanged ->
        case Runtime.active_tab(state.shell_runtime) do
          %Tab{id: ^target_id} = target -> arrive(state, target)
          _tab -> state
        end

      :accepted ->
        candidate = stash_active_workspace_agent_ui(state)
        old_buffer = candidate.workspace.buffers.active

        {transitioned, {:switched, %Tab{} = target}} =
          EditorState.switch_tab(candidate, target_id)

        transitioned =
          transitioned
          |> finish_switch(target)
          |> HighlightSync.ensure_active_buffer_presentation(old_buffer)

        candidate
        |> WorkspaceWorkflow.persist_changes(transitioned)
        |> InFileReview.resume_ready()
        |> TaskReviewWorkflow.resume()
    end
  end

  @doc """
  Shows the project home while the active tab steps aside (`SPC p h`, or leaving a task with no file to return to).

  An Agent tab's agent state is stashed on its workspace first, as a switch would, and the live agent view goes inactive, so switching back restores the conversation.
  """
  @spec leave_to_home(EditorState.t()) :: EditorState.t()
  def leave_to_home(%EditorState{} = state) do
    state = state |> ShellWorkflow.ensure_available() |> stash_active_workspace_agent_ui()
    {agent_ui, _windows, _file_tree} = UIState.deactivate(state.workspace.agent_ui)
    workspace = MingaEditor.Session.State.set_agent_ui(state.workspace, agent_ui)
    EditorState.show_home(%{state | workspace: workspace})
  end

  @doc "Stages the pure root transition for an already validated tab target."
  @spec stage_switch(EditorState.t(), Tab.id()) :: staged_switch()
  def stage_switch(%EditorState{} = state, target_id) do
    case switch_target(state, target_id) do
      :unchanged ->
        {:unchanged, state}

      :accepted ->
        persistence_base = stash_active_workspace_agent_ui(state)
        old_buffer = persistence_base.workspace.buffers.active

        {transitioned, {:switched, %Tab{} = target}} =
          EditorState.switch_tab(persistence_base, target_id)

        {:switched, persistence_base, transitioned, target, old_buffer}
    end
  end

  @doc "Returns the effect-free state produced by a staged tab switch."
  @spec staged_state(staged_switch()) :: EditorState.t()
  def staged_state({:unchanged, state}), do: state
  def staged_state({:switched, _base, state, _target, _old_buffer}), do: state

  @doc "Runs the presentation and persistence effects for an accepted staged switch."
  @spec commit_staged_switch(staged_switch(), EditorState.t()) :: EditorState.t()
  def commit_staged_switch({:unchanged, _staged_state}, %EditorState{} = accepted_state),
    do: accepted_state

  def commit_staged_switch(
        {:switched, persistence_base, _staged_state, target, old_buffer},
        %EditorState{} = accepted_state
      ) do
    accepted_state
    |> NavigationFinalizer.run(:tab_presentation, &finish_switch(&1, target))
    |> NavigationFinalizer.run(
      :tab_highlight,
      &HighlightSync.ensure_active_buffer_presentation(&1, old_buffer)
    )
    |> NavigationFinalizer.run(
      :workspace_persistence,
      &WorkspaceWorkflow.persist_changes(persistence_base, &1)
    )
  end

  @doc "Restores a context and synchronizes its workspace-backed agent presentation."
  @spec restore_context(EditorState.t(), Tab.context() | Tab.legacy_context()) :: EditorState.t()
  def restore_context(%EditorState{} = state, context) when is_map(context) do
    old_buffer = state.workspace.buffers.active

    state
    |> EditorState.restore_tab_context(context)
    |> finish_restore(old_buffer)
  end

  @doc "Restores the exact replacement after a tab closes and installs its presentation."
  @spec restore_after_close(EditorState.t(), Tab.t()) :: EditorState.t()
  def restore_after_close(%EditorState{} = state, %Tab{} = target) do
    old_buffer = state.workspace.buffers.active

    state
    |> EditorState.restore_tab_after_close(target)
    |> finish_restore(old_buffer)
  end

  @spec finish_restore(EditorState.t(), pid() | nil) :: EditorState.t()
  defp finish_restore(state, old_buffer) do
    state
    |> Arrival.cancel()
    |> sync_active_workspace_agent_ui()
    |> restore_active_agent(Runtime.active_tab(state.shell_runtime))
    |> arrive()
    |> MingaEditor.Agent.SubagentPeekWorkflow.resume_in_workspace()
    |> HighlightSync.ensure_active_buffer_presentation(old_buffer)
    |> TaskReviewWorkflow.resume()
  end

  @spec restore_active_agent(EditorState.t(), Tab.t() | nil) :: EditorState.t()
  defp restore_active_agent(state, %Tab{kind: :agent} = tab),
    do: rebuild_switched_agent(state, tab)

  defp restore_active_agent(state, _tab), do: state

  @doc "Transfers the active workspace agent presentation and replays pending foreground catch-up events."
  @spec sync_active_workspace_agent_ui(EditorState.t()) :: EditorState.t()
  def sync_active_workspace_agent_ui(%EditorState{} = state),
    do: sync_active_workspace_agent_ui(state, :current)

  @spec sync_active_workspace_agent_ui(EditorState.t(), :current | :incoming) :: EditorState.t()
  defp sync_active_workspace_agent_ui(
         %EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}} = state,
         source
       ) do
    case TraditionalState.tab_bar(shell_state) do
      %TabBar{} = tab_bar -> sync_from_tab_bar(state, tab_bar, source)
      nil -> state
    end
  end

  defp sync_active_workspace_agent_ui(%EditorState{} = state, _source), do: state

  @spec finish_switch(EditorState.t(), Tab.t()) :: EditorState.t()
  defp finish_switch(state, target) do
    state
    |> Arrival.cancel()
    |> sync_active_workspace_agent_ui(:incoming)
    |> ModalWorkflow.dismiss_if_stale()
    |> TraditionalWorkflow.install_agent_spinner_stop()
    |> rebuild_switched_agent(target)
    |> arrive(target)
    |> MingaEditor.Agent.SubagentPeekWorkflow.resume_in_workspace()
    |> AgentHistorySource.dismiss_if_stale()
    |> AgentChecklistSource.dismiss_if_stale()
    |> AgentDraftAttachmentSource.dismiss_if_stale()
    |> maybe_restart_incoming_spinner()
  end

  @spec arrive(EditorState.t()) :: EditorState.t()
  defp arrive(state), do: arrive(state, Runtime.active_tab(state.shell_runtime))

  @spec arrive(EditorState.t(), Tab.t() | nil) :: EditorState.t()
  defp arrive(state, %Tab{kind: :agent}) do
    ui = state.workspace.agent_ui

    case PromptBuffer.ensure(ui) do
      ^ui -> state
      attached -> TraditionalWorkflow.install_agent_ui(state, attached)
    end
  end

  defp arrive(state, _tab), do: state

  @spec switch_target(EditorState.t(), Tab.id()) :: :accepted | :unchanged
  defp switch_target(
         %EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}},
         target_id
       ) do
    case TraditionalState.tab_bar(shell_state) do
      %TabBar{active_id: ^target_id} ->
        :unchanged

      %TabBar{} = tab_bar ->
        case TabBar.get(tab_bar, target_id) do
          %Tab{} -> :accepted
          nil -> :unchanged
        end

      nil ->
        :unchanged
    end
  end

  defp switch_target(%EditorState{}, _target_id), do: :unchanged

  @spec stash_active_workspace_agent_ui(EditorState.t()) :: EditorState.t()
  defp stash_active_workspace_agent_ui(
         %EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}} = state
       ) do
    case TraditionalState.tab_bar(shell_state) do
      %TabBar{} = tab_bar ->
        case TabBar.active_workspace(tab_bar) do
          %Workspace{id: workspace_id, payload: %WorkspaceAgent{}} ->
            # Parse results for a stashed tab are discarded, so its pending parses restart on return.
            agent_ui = UIState.suspend_review_highlights(state.workspace.agent_ui)
            tab_bar = TabBar.set_workspace_agent_ui(tab_bar, workspace_id, agent_ui)

            shell_state = TraditionalState.install_tab_bar(shell_state, tab_bar)

            %{
              state
              | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)
            }

          _workspace ->
            state
        end

      nil ->
        state
    end
  end

  @spec sync_from_tab_bar(EditorState.t(), TabBar.t(), :current | :incoming) :: EditorState.t()
  defp sync_from_tab_bar(state, tab_bar, source) do
    case TabBar.active_workspace(tab_bar) do
      %Workspace{id: workspace_id, payload: %WorkspaceAgent{agent_ui: %UIState{} = agent_ui}} ->
        agent_ui = activate_agent_ui(state.workspace, agent_ui)
        state = %{state | workspace: SessionState.set_agent_ui(state.workspace, agent_ui)}
        tab_bar = TabBar.set_workspace_agent_ui(tab_bar, workspace_id, nil)
        shell_state = Runtime.state(state.shell_runtime)
        shell_state = TraditionalState.install_tab_bar(shell_state, tab_bar)

        state = %{
          state
          | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)
        }

        replay_pending_events(state, tab_bar)

      %Workspace{payload: %WorkspaceAgent{agent_ui: nil}} when source == :current ->
        workspace = SessionState.set_agent_ui(state.workspace, state.workspace.agent_ui)
        replay_pending_events(%{state | workspace: workspace}, tab_bar)

      %Workspace{payload: %WorkspaceAgent{agent_ui: nil}} ->
        agent_ui = activate_agent_ui(state.workspace, UIState.new())
        workspace = SessionState.set_agent_ui(state.workspace, agent_ui)
        replay_pending_events(%{state | workspace: workspace}, tab_bar)

      _workspace ->
        workspace = SessionState.set_agent_ui(state.workspace, UIState.new())
        replay_pending_events(%{state | workspace: workspace}, tab_bar)
    end
  end

  @spec activate_agent_ui(SessionState.t(), UIState.t()) :: UIState.t()
  defp activate_agent_ui(%SessionState{keymap_scope: :agent} = workspace, agent_ui) do
    agent_ui
    |> UIState.activate(workspace.windows, workspace.file_tree)
    |> UIState.set_focus(UIState.View.focus(agent_ui.view))
  end

  defp activate_agent_ui(%SessionState{}, agent_ui), do: agent_ui

  @spec replay_pending_events(EditorState.t(), TabBar.t()) :: EditorState.t()
  defp replay_pending_events(state, tab_bar) do
    case TabBar.active_workspace(tab_bar) do
      %Workspace{
        id: workspace_id,
        payload: %WorkspaceAgent{session: session_pid, pending_catchup_events: [_ | _] = events}
      }
      when is_pid(session_pid) ->
        state = EventReplay.replay_active(state, session_pid, events)
        clear_replayed_events(state, workspace_id)

      _none ->
        state
    end
    |> AgentRetainedOutputSource.dismiss_if_stale()
    |> AgentChecklistSource.dismiss_if_stale()
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
  defp rebuild_switched_agent(state, %Tab{
         id: id,
         kind: :agent,
         payload: %Tab.Agent{session: session, remote_session_id: nil}
       })
       when is_pid(session) and node(session) == node() do
    Arrival.start(state, id, session)
  end

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
