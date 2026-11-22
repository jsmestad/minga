defmodule MingaEditor.Agent.Events do
  @moduledoc """
  Routes foreground agent events to focused, process-free workflows.

  Live events enter the same domain-family dispatch. The Editor remains the only mailbox owner, and each workflow directly composes owner transitions with rendering, synchronization, logging, or compaction.
  """

  alias MingaAgent.ModelSelection
  alias MingaEditor.Agent.FileChange
  alias MingaEditor.Agent.FileEventWorkflow
  alias MingaEditor.Agent.SessionEventWorkflow
  alias MingaEditor.Agent.StatusEventWorkflow
  alias MingaEditor.Agent.StreamEventWorkflow
  alias MingaEditor.Agent.ToolEventWorkflow
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.State, as: EditorState

  @doc "Applies one foreground session event with its originating Session identity."
  @spec dispatch(EditorState.t(), pid(), term()) :: EditorState.t()
  def dispatch(%EditorState{} = state, _session_pid, {:status_changed, status}),
    do: StatusEventWorkflow.status_changed(state, status)

  def dispatch(%EditorState{} = state, session_pid, {:display_status_changed, status}),
    do: StatusEventWorkflow.display_status_changed(state, session_pid, status)

  def dispatch(%EditorState{} = state, session_pid, {:queue_target_changed, target}),
    do: StatusEventWorkflow.queue_target_changed(state, session_pid, target)

  def dispatch(%EditorState{} = state, session_pid, {:stop_target_changed, target}),
    do: StatusEventWorkflow.stop_target_changed(state, session_pid, target)

  def dispatch(%EditorState{} = state, _session_pid, {:text_delta, _delta} = event),
    do: StreamEventWorkflow.delta(state, event)

  def dispatch(%EditorState{} = state, _session_pid, {:thinking_delta, _delta} = event),
    do: StreamEventWorkflow.delta(state, event)

  def dispatch(%EditorState{} = state, _session_pid, :messages_changed),
    do: StreamEventWorkflow.messages_changed(state)

  def dispatch(%EditorState{} = state, _session_pid, {:tool_started, tool_call_id, name, args}),
    do: ToolEventWorkflow.started(state, tool_call_id, name, args)

  def dispatch(%EditorState{} = state, _session_pid, {:tool_update, tool_call_id, name, partial}),
    do: ToolEventWorkflow.updated(state, tool_call_id, name, partial)

  def dispatch(
        %EditorState{} = state,
        _session_pid,
        {:tool_ended, %MingaAgent.Event.ToolEnd{} = event}
      ),
      do: ToolEventWorkflow.ended(state, event)

  def dispatch(%EditorState{} = state, _session_pid, {:tool_interrupted, tool_call_id}),
    do: ToolEventWorkflow.interrupted(state, tool_call_id)

  def dispatch(
        %EditorState{} = state,
        pid,
        {:file_changed, conversation, path, before_content, after_content, tool_call_id,
         tool_name}
      ) do
    case state.workspace.agent_ui.connection do
      %{target: %{session: ^pid}, conversation: ^conversation} when is_reference(conversation) ->
        dispatch(
          state,
          pid,
          {:file_changed, path, before_content, after_content, tool_call_id, tool_name}
        )

      _other ->
        state
    end
  end

  def dispatch(
        %EditorState{} = state,
        _session_pid,
        {:file_changed, path, before_content, after_content, tool_call_id, tool_name}
      ) do
    FileEventWorkflow.changed(state, %FileChange{
      path: path,
      before_content: before_content,
      after_content: after_content,
      tool_call_id: tool_call_id,
      tool_name: tool_name
    })
  end

  def dispatch(%EditorState{} = state, session_pid, {:approval_pending, approval}),
    do: SessionEventWorkflow.approval_pending(state, session_pid, approval)

  def dispatch(%EditorState{} = state, session_pid, {:approval_resolved, target, decision}),
    do: SessionEventWorkflow.approval_resolved(state, session_pid, target, decision)

  def dispatch(%EditorState{} = state, session_pid, {:question_requested, target, question}),
    do: SessionEventWorkflow.question_requested(state, session_pid, target, question)

  def dispatch(%EditorState{} = state, session_pid, {event, target})
      when event in [:question_answered, :question_cancelled, :question_interrupted],
      do: SessionEventWorkflow.question_retired(state, session_pid, target)

  def dispatch(%EditorState{} = state, _session_pid, {:error, message}),
    do: SessionEventWorkflow.error(state, message)

  def dispatch(%EditorState{} = state, _session_pid, {:model_limit_reached, message}),
    do:
      state
      |> MingaEditor.Handlers.Notifications.model_limit_reached(message)
      |> MingaEditor.schedule_render(16)

  def dispatch(
        %EditorState{} = state,
        session_pid,
        {:connection_changed, %MingaAgent.Session.ConnectionSnapshot{} = connection}
      ),
      do: SessionEventWorkflow.connection_changed(state, session_pid, connection)

  def dispatch(%EditorState{} = state, _session_pid, {:credentials_status, configured?}),
    do: SessionEventWorkflow.credentials_status(state, configured?)

  def dispatch(
        %EditorState{} = state,
        _session_pid,
        {:model_selection_changed, %ModelSelection{} = selection}
      ),
      do: apply_model_selection(state, selection)

  def dispatch(
        %EditorState{} = state,
        _session_pid,
        {:model_selection_rejected, %ModelSelection{}, message}
      )
      when is_binary(message),
      do: reject_model_selection(state, message)

  def dispatch(%EditorState{} = state, _session_pid, {:todo_plan_updated, todos}),
    do: ToolEventWorkflow.todo_plan_updated(state, todos)

  def dispatch(
        %EditorState{} = state,
        _session_pid,
        {:context_usage, estimated_tokens, context_limit}
      ),
      do: StatusEventWorkflow.context_usage(state, estimated_tokens, context_limit)

  def dispatch(%EditorState{} = state, _session_pid, {:prompt_queued, content, queue_type}),
    do: SessionEventWorkflow.prompt_queued(state, content, queue_type)

  def dispatch(%EditorState{} = state, _session_pid, :queues_recalled),
    do: SessionEventWorkflow.queues_recalled(state)

  def dispatch(%EditorState{} = state, _session_pid, _unknown), do: state

  @spec reject_model_selection(EditorState.t(), String.t()) :: EditorState.t()
  defp reject_model_selection(%EditorState{} = state, message) do
    agent_ui = UIState.push_toast(state.workspace.agent_ui, message, :error)

    state
    |> TraditionalWorkflow.install_agent_ui(agent_ui)
    |> MingaEditor.schedule_render(16)
  end

  @spec apply_model_selection(EditorState.t(), ModelSelection.t()) :: EditorState.t()
  defp apply_model_selection(%EditorState{} = state, %ModelSelection{} = selection) do
    current_ui = state.workspace.agent_ui

    case UIState.project_model_selection(current_ui, selection) do
      ^current_ui ->
        state

      agent_ui ->
        route = selection.route

        message =
          "Model activated: #{route.display_name} via " <>
            "#{route.model_provider}/#{route.execution.wire_protocol}"

        state
        |> TraditionalWorkflow.install_agent_ui(UIState.push_toast(agent_ui, message, :info))
        |> MingaEditor.schedule_render(16)
    end
  end

  @doc "Applies one coalesced agent stream batch without changing mailbox ownership."
  @spec dispatch_batch(EditorState.t(), [term()]) :: EditorState.t()
  def dispatch_batch(%EditorState{} = state, batch) when is_list(batch),
    do: StreamEventWorkflow.batch(state, batch)
end
