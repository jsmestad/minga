defmodule MingaEditor.Agent.SessionEventWorkflow do
  @moduledoc """
  Applies approval, error, queue, spinner, and session presentation events.

  Queue recall remains owned by the active session. Approval and transcript actions are composed directly in their established render-then-sync order.
  """

  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaAgent.Session

  @typep queued_prompt :: String.t() | [ReqLLM.Message.ContentPart.t()]

  @doc "Installs an approval request, moves input focus, renders, and synchronizes the transcript."
  @spec approval_pending(EditorState.t(), map()) :: EditorState.t()
  def approval_pending(%EditorState{} = state, approval) when is_map(approval) do
    cached = Map.take(approval, [:tool_call_id, :name, :args, :preview])
    state = TraditionalWorkflow.install_agent_approval(state, cached)
    state = update_activity(state, &Activity.ensure_started_at/1)

    state =
      TraditionalWorkflow.install_agent_ui(
        state,
        PromptBuffer.set_input_focused(state.workspace.agent_ui, false)
      )

    state
    |> MingaEditor.schedule_render(16)
    |> AgentLifecycle.sync_transcript()
  end

  @doc "Clears a resolved approval, renders, and synchronizes the transcript."
  @spec approval_resolved(EditorState.t(), term()) :: EditorState.t()
  def approval_resolved(%EditorState{} = state, _decision) do
    state
    |> TraditionalWorkflow.clear_agent_approval()
    |> MingaEditor.schedule_render(16)
    |> AgentLifecycle.sync_transcript()
  end

  @doc "Restores queued prompts after an agent error and installs the visible error state."
  @spec error(EditorState.t(), String.t()) :: EditorState.t()
  def error(%EditorState{} = state, message) when is_binary(message) do
    state
    |> restore_queued_prompts_after_error()
    |> TraditionalWorkflow.install_agent_error(message)
    |> MingaEditor.schedule_render(16)
  end

  @doc "Updates whether provider credentials are configured and schedules a render."
  @spec credentials_status(EditorState.t(), boolean()) :: EditorState.t()
  def credentials_status(%EditorState{} = state, configured?) when is_boolean(configured?) do
    state
    |> TraditionalWorkflow.install_agent_panel(
      Panel.set_credentials_configured(state.workspace.agent_ui.panel, configured?)
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
        {steering, follow_up} = safe_recall_queues(session)
        restore_queued_to_prompt(state, steering ++ follow_up)

      _session ->
        state
    end
  end

  @spec safe_recall_queues(pid()) :: {[queued_prompt()], [queued_prompt()]}
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
      %Workspace{} = workspace -> maybe_apply_auto_name(state, workspace, prompt)
      nil -> state
    end
  end

  @spec workspace_for_session(TabBar.t() | nil, pid() | nil) :: Workspace.t() | nil
  defp workspace_for_session(nil, _session), do: nil
  defp workspace_for_session(_tab_bar, session) when not is_pid(session), do: nil

  defp workspace_for_session(tab_bar, session),
    do: TabBar.find_workspace_by_session(tab_bar, session)

  @spec maybe_apply_auto_name(EditorState.t(), Workspace.t(), String.t()) :: EditorState.t()
  defp maybe_apply_auto_name(state, workspace, prompt) do
    updated_workspace = Workspace.auto_name(workspace, prompt)
    install_auto_name(state, workspace, updated_workspace)
  end

  @spec install_auto_name(EditorState.t(), Workspace.t(), Workspace.t()) :: EditorState.t()
  defp install_auto_name(state, %Workspace{label: label}, %Workspace{label: label}), do: state

  defp install_auto_name(state, workspace, updated_workspace) do
    case traditional_tab_bar(state) do
      %TabBar{} = tab_bar ->
        tab_bar =
          TabBar.update_workspace(tab_bar, workspace.id, fn _current -> updated_workspace end)

        install_tab_bar(state, tab_bar)

      nil ->
        state
    end
  end

  @spec traditional_tab_bar(EditorState.t()) :: TabBar.t() | nil
  defp traditional_tab_bar(%EditorState{
         shell_runtime: %Runtime{state: %TraditionalState{} = state}
       }),
       do: TraditionalState.tab_bar(state)

  defp traditional_tab_bar(%EditorState{}), do: nil

  @spec install_tab_bar(EditorState.t(), TabBar.t()) :: EditorState.t()
  defp install_tab_bar(
         %EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}} = state,
         %TabBar{} = tab_bar
       ) do
    shell_state = TraditionalState.install_tab_bar(shell_state, tab_bar)
    %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)}
  end

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
