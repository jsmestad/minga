defmodule MingaEditor.Agent.SessionEventWorkflow do
  @moduledoc """
  Applies approval, error, queue, spinner, and session presentation events.

  Queue recall remains owned by the active session. Approval and transcript actions are composed directly in their established render-then-sync order.
  """

  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.DraftWorkflow
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.UIState
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.WorkspaceWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent
  alias MingaAgent.Question
  alias MingaAgent.Question.Target, as: QuestionTarget
  alias MingaAgent.Session
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaEditor.Agent.ConnectionSetup
  alias MingaEditor.UI.Picker.AgentDraftAttachmentSource
  alias MingaEditor.UI.Picker.AgentRetainedOutputSource
  alias MingaAgent.ToolApproval.Public, as: PublicApproval
  alias MingaAgent.ToolApproval.Target, as: ApprovalTarget

  @typep queued_prompt :: String.t() | [ReqLLM.Message.ContentPart.t()]

  @doc "Installs the originating Session's complete approval without changing composer focus."
  @spec approval_pending(EditorState.t(), pid(), PublicApproval.t()) :: EditorState.t()
  def approval_pending(%EditorState{} = state, session_pid, %PublicApproval{} = approval)
      when is_pid(session_pid) do
    binding = PendingApproval.new(session_pid, approval)
    state = TraditionalWorkflow.install_agent_approval(state, binding)
    state = update_activity(state, &Activity.ensure_started_at/1)

    state
    |> MingaEditor.schedule_render(16)
    |> AgentLifecycle.sync_transcript()
  end

  @doc "Clears only the resolved approval attachment, renders, and synchronizes the transcript."
  @spec approval_resolved(
          EditorState.t(),
          pid(),
          ApprovalTarget.t(),
          Session.approval_decision() | :approval_timeout | :interrupted
        ) ::
          EditorState.t()
  def approval_resolved(
        %EditorState{} = state,
        session_pid,
        %ApprovalTarget{} = target,
        _decision
      )
      when is_pid(session_pid) do
    state
    |> TraditionalWorkflow.resolve_agent_approval(target, session_pid)
    |> MingaEditor.schedule_render(16)
    |> AgentLifecycle.sync_transcript()
  end

  @doc "Presents the current Session question without taking composer focus."
  @spec question_requested(EditorState.t(), pid(), QuestionTarget.t(), Question.t()) ::
          EditorState.t()
  def question_requested(%EditorState{} = state, session, target, question) do
    agent = TraditionalState.agent(state.shell_runtime.state)
    agent = AgentState.project_question(agent, session, {target, question})

    state
    |> TraditionalWorkflow.install_agent_state(agent)
    |> MingaEditor.schedule_render(16)
  end

  @doc "Withdraws only the question retired by the originating Session."
  @spec question_retired(EditorState.t(), pid(), QuestionTarget.t()) :: EditorState.t()
  def question_retired(%EditorState{} = state, session, target) do
    agent = TraditionalState.agent(state.shell_runtime.state)
    agent = AgentState.retire_question(agent, session, target)

    state
    |> TraditionalWorkflow.install_agent_state(agent)
    |> MingaEditor.schedule_render(16)
  end

  @doc "Restores queued prompts after an agent error and installs the visible error state."
  @spec error(EditorState.t(), String.t()) :: EditorState.t()
  def error(%EditorState{} = state, message) when is_binary(message) do
    state
    |> TraditionalWorkflow.install_agent_ui(
      UIState.report_chat_start_failure(state.workspace.agent_ui, message)
    )
    |> restore_queued_prompts_after_error()
    |> TraditionalWorkflow.install_agent_error(message)
    |> MingaEditor.schedule_render(16)
  end

  @doc "Installs the originating Session's canonical connection facts without moving focus."
  @spec connection_changed(EditorState.t(), pid(), ConnectionSnapshot.t()) :: EditorState.t()
  def connection_changed(
        %EditorState{} = state,
        session_pid,
        %ConnectionSnapshot{target: %{session: session_pid}} = connection
      )
      when is_pid(session_pid) do
    state
    |> TraditionalWorkflow.install_agent_ui(
      UIState.project_connection(state.workspace.agent_ui, connection)
    )
    |> ConnectionSetup.retire_prompt(connection)
    |> AgentRetainedOutputSource.dismiss_if_stale()
    |> AgentDraftAttachmentSource.dismiss_if_stale()
    |> MingaEditor.schedule_render(16)
  end

  def connection_changed(%EditorState{} = state, _session_pid, _connection), do: state

  @doc "Retires the chat attached to an exact stopped or unreachable Session."
  @spec session_unreachable(EditorState.t(), pid() | nil, :unavailable | {:failed, String.t()}) ::
          EditorState.t()
  def session_unreachable(
        %EditorState{shell_runtime: %Runtime{state: %TraditionalState{tab_bar: %TabBar{} = tabs}}} =
          state,
        session,
        lifecycle
      )
      when is_pid(session) do
    case {Runtime.active_session(state.shell_runtime),
          TabBar.find_workspace_by_session(tabs, session)} do
      {^session, _owner} ->
        state
        |> TraditionalWorkflow.install_agent_cache_reset()
        |> TraditionalWorkflow.install_agent_ui(
          UIState.transition_chat(state.workspace.agent_ui, lifecycle)
        )

      {_active, %Workspace{id: id, payload: %WorkspaceAgent{agent_ui: %UIState{} = ui}}} ->
        tabs = TabBar.set_workspace_agent_ui(tabs, id, UIState.transition_chat(ui, lifecycle))
        WorkspaceWorkflow.install_tab_bar(state, tabs)

      _no_owner ->
        state
    end
  end

  def session_unreachable(%EditorState{} = state, _session, _lifecycle), do: state

  @doc "Updates explicit credential readiness and schedules a render."
  @spec credentials_status(EditorState.t(), MingaAgent.Credentials.readiness()) :: EditorState.t()
  def credentials_status(%EditorState{} = state, readiness)
      when readiness in [:checking, :configured, :unconfigured] do
    state
    |> TraditionalWorkflow.install_agent_ui(
      UIState.project_credential_readiness(state.workspace.agent_ui, readiness)
    )
    |> MingaEditor.schedule_render(16)
  end

  @doc "Advances or stops the agent spinner according to the foreground status."
  @spec spinner_tick(EditorState.t()) :: EditorState.t()
  def spinner_tick(
        %EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}} = state
      ) do
    spinner_tick(state, AgentState.busy?(TraditionalState.agent(shell_state)))
  end

  def spinner_tick(%EditorState{} = state), do: state

  @spec spinner_tick(EditorState.t(), boolean()) :: EditorState.t()
  defp spinner_tick(state, true) do
    state
    |> TraditionalWorkflow.install_agent_ui(UIState.tick_spinner(state.workspace.agent_ui))
    |> MingaEditor.schedule_render(16)
  end

  defp spinner_tick(state, false), do: TraditionalWorkflow.install_agent_spinner_stop(state)

  @doc "Dismisses the current agent toast and schedules a render."
  @spec dismiss_toast(EditorState.t()) :: EditorState.t()
  def dismiss_toast(%EditorState{} = state) do
    state
    |> TraditionalWorkflow.install_agent_ui(UIState.dismiss_toast(state.workspace.agent_ui))
    |> MingaEditor.schedule_render(16)
  end

  @doc "Applies queue presentation for a newly queued prompt."
  @spec prompt_queued(EditorState.t(), String.t(), term()) :: EditorState.t()
  def prompt_queued(%EditorState{} = state, content, _queue_type) when is_binary(content) do
    state
    |> maybe_auto_name_workspace(content)
    |> MingaEditor.schedule_render(16)
  end

  @doc "Refreshes queue presentation after both prompt queues are recalled."
  @spec queues_recalled(EditorState.t()) :: EditorState.t()
  def queues_recalled(%EditorState{} = state), do: MingaEditor.schedule_render(state, 16)

  @spec restore_queued_prompts_after_error(EditorState.t()) :: EditorState.t()
  defp restore_queued_prompts_after_error(state) do
    case Runtime.active_session(state.shell_runtime) do
      session when is_pid(session) ->
        case DraftWorkflow.recall(state, session) do
          {:saved, updated} ->
            updated

          :volatile ->
            restore_volatile_queue(state, safe_recall_queues(session))
        end

      _session ->
        state
    end
  end

  @spec restore_volatile_queue(
          EditorState.t(),
          {[queued_prompt()], [queued_prompt()]} | {:error, :saved_draft_required}
        ) :: EditorState.t()
  defp restore_volatile_queue(state, {:error, :saved_draft_required}), do: state

  defp restore_volatile_queue(state, {steering, follow_up}),
    do: restore_queued_to_prompt(state, steering ++ follow_up)

  @spec safe_recall_queues(pid()) ::
          {[queued_prompt()], [queued_prompt()]} | {:error, :saved_draft_required}
  defp safe_recall_queues(session) do
    Session.recall_queues(session)
  catch
    :exit, _reason -> {[], []}
  end

  @spec restore_queued_to_prompt(EditorState.t(), [queued_prompt()]) :: EditorState.t()
  defp restore_queued_to_prompt(state, []), do: state

  defp restore_queued_to_prompt(state, queued) do
    current_text = PromptBuffer.prompt_text(state.workspace.agent_ui)
    combined = Session.combine_queue_entries_to_text(queued)
    restored = append_current_prompt(combined, current_text)

    TraditionalWorkflow.install_agent_ui(
      state,
      PromptBuffer.set_prompt_text(state.workspace.agent_ui, restored)
    )
  end

  @spec append_current_prompt(String.t(), String.t()) :: String.t()
  defp append_current_prompt(combined, ""), do: combined
  defp append_current_prompt(combined, current_text), do: combined <> "\n\n" <> current_text

  @spec maybe_auto_name_workspace(EditorState.t(), String.t()) :: EditorState.t()
  defp maybe_auto_name_workspace(state, prompt) do
    session = Runtime.active_session(state.shell_runtime)

    case workspace_for_session(traditional_tab_bar(state), session) do
      %Workspace{id: workspace_id} ->
        WorkspaceWorkflow.install_auto_named_workspace(state, workspace_id, prompt)

      nil ->
        state
    end
  end

  @spec workspace_for_session(TabBar.t() | nil, pid() | nil) :: Workspace.t() | nil
  defp workspace_for_session(nil, _session), do: nil
  defp workspace_for_session(_tab_bar, session) when not is_pid(session), do: nil

  defp workspace_for_session(tab_bar, session),
    do: TabBar.find_workspace_by_session(tab_bar, session)

  @spec traditional_tab_bar(EditorState.t()) :: TabBar.t() | nil
  defp traditional_tab_bar(%EditorState{
         shell_runtime: %Runtime{state: %TraditionalState{} = state}
       }),
       do: TraditionalState.tab_bar(state)

  defp traditional_tab_bar(%EditorState{}), do: nil

  @spec update_activity(EditorState.t(), (Activity.t() -> Activity.t())) :: EditorState.t()
  defp update_activity(state, fun) when is_function(fun, 1) do
    TraditionalWorkflow.install_agent_ui(
      state,
      (fn ui -> UIState.replace_activity(ui, fun.(ui.view.activity)) end).(
        state.workspace.agent_ui
      )
    )
  end
end
