defmodule MingaEditor.Agent.Events do
  @moduledoc """
  Routes foreground agent events to focused, process-free workflows.

  Live events enter the same domain-family dispatch. The Editor remains the only mailbox owner, and each workflow directly composes owner transitions with rendering, synchronization, logging, or compaction.
  """

  alias MingaAgent.ModelSelection
  alias MingaEditor.Agent.FileEventWorkflow
  alias MingaEditor.Agent.SessionEventWorkflow
  alias MingaEditor.Agent.StatusEventWorkflow
  alias MingaEditor.Agent.StreamEventWorkflow
  alias MingaEditor.Agent.ToolEventWorkflow
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.State, as: EditorState

  @doc "Applies one foreground agent event through its focused workflow."
  @spec dispatch(EditorState.t(), term()) :: EditorState.t()
  def dispatch(%EditorState{} = state, {:status_changed, status}),
    do: StatusEventWorkflow.status_changed(state, status)

  def dispatch(%EditorState{} = state, {:text_delta, _delta} = event),
    do: StreamEventWorkflow.delta(state, event)

  def dispatch(%EditorState{} = state, {:thinking_delta, _delta} = event),
    do: StreamEventWorkflow.delta(state, event)

  def dispatch(%EditorState{} = state, :messages_changed),
    do: StreamEventWorkflow.messages_changed(state)

  def dispatch(%EditorState{} = state, {:tool_started, tool_call_id, name, args}),
    do: ToolEventWorkflow.started(state, tool_call_id, name, args)

  def dispatch(%EditorState{} = state, {:tool_started, name, args}),
    do: ToolEventWorkflow.started(state, name, args)

  def dispatch(%EditorState{} = state, {:tool_update, tool_call_id, name, partial}),
    do: ToolEventWorkflow.updated(state, tool_call_id, name, partial)

  def dispatch(%EditorState{} = state, {:tool_ended, tool_call_id, name, result, status}),
    do: ToolEventWorkflow.ended(state, tool_call_id, name, result, status)

  def dispatch(%EditorState{} = state, {:tool_ended, name, result, status}),
    do: ToolEventWorkflow.ended(state, name, result, status)

  def dispatch(%EditorState{} = state, {:tool_interrupted, tool_call_id}),
    do: ToolEventWorkflow.interrupted(state, tool_call_id)

  def dispatch(
        %EditorState{} = state,
        {:file_changed, path, before_content, after_content, tool_call_id, tool_name}
      ) do
    FileEventWorkflow.changed(
      state,
      path,
      before_content,
      after_content,
      tool_call_id,
      tool_name
    )
  end

  def dispatch(%EditorState{} = state, {:approval_pending, approval}),
    do: SessionEventWorkflow.approval_pending(state, approval)

  def dispatch(%EditorState{} = state, {:approval_resolved, decision}),
    do: SessionEventWorkflow.approval_resolved(state, decision)

  def dispatch(%EditorState{} = state, {:error, message}),
    do: SessionEventWorkflow.error(state, message)

  def dispatch(%EditorState{} = state, {:credentials_status, configured?}),
    do: SessionEventWorkflow.credentials_status(state, configured?)

  def dispatch(
        %EditorState{} = state,
        {:model_selection_changed, %ModelSelection{} = selection}
      ),
      do: apply_model_selection(state, selection)

  def dispatch(
        %EditorState{} = state,
        {:model_selection_rejected, %ModelSelection{}, message}
      )
      when is_binary(message),
      do: reject_model_selection(state, message)

  def dispatch(%EditorState{} = state, {:todo_plan_updated, todos}),
    do: ToolEventWorkflow.todo_plan_updated(state, todos)

  def dispatch(%EditorState{} = state, :spinner_tick),
    do: SessionEventWorkflow.spinner_tick(state)

  def dispatch(%EditorState{} = state, :dismiss_toast),
    do: SessionEventWorkflow.dismiss_toast(state)

  def dispatch(%EditorState{} = state, {:context_usage, estimated_tokens, context_limit}),
    do: StatusEventWorkflow.context_usage(state, estimated_tokens, context_limit)

  def dispatch(%EditorState{} = state, {:prompt_queued, content, queue_type}),
    do: SessionEventWorkflow.prompt_queued(state, content, queue_type)

  def dispatch(%EditorState{} = state, :queues_recalled),
    do: SessionEventWorkflow.queues_recalled(state)

  def dispatch(%EditorState{} = state, _unknown), do: state

  @spec reject_model_selection(EditorState.t(), String.t()) :: EditorState.t()
  defp reject_model_selection(%EditorState{} = state, message) do
    agent_ui = UIState.push_toast(state.workspace.agent_ui, message, :error)

    state
    |> TraditionalWorkflow.install_agent_ui(agent_ui)
    |> MingaEditor.schedule_render(16)
  end

  @spec apply_model_selection(EditorState.t(), ModelSelection.t()) :: EditorState.t()
  defp apply_model_selection(%EditorState{} = state, %ModelSelection{} = selection) do
    route = selection.route

    message =
      "Model activated: #{route.display_name} via " <>
        "#{route.model_provider}/#{route.execution.wire_protocol}"

    agent_ui =
      state.workspace.agent_ui
      |> UIState.set_model_name(route.display_name)
      |> UIState.set_provider_name(route.model_provider)
      |> UIState.set_thinking_level(selection.policy.reasoning.effort)
      |> UIState.push_toast(message, :info)

    state
    |> TraditionalWorkflow.install_agent_ui(agent_ui)
    |> MingaEditor.schedule_render(16)
  end

  @doc "Applies one coalesced agent stream batch without changing mailbox ownership."
  @spec dispatch_batch(EditorState.t(), [term()]) :: EditorState.t()
  def dispatch_batch(%EditorState{} = state, batch) when is_list(batch),
    do: StreamEventWorkflow.batch(state, batch)
end
