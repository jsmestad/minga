defmodule MingaEditor.Agent.Events do
  @moduledoc """
  Routes foreground agent events to focused, process-free workflows.

  Live events and durable replay enter the same domain-family dispatch. The Editor remains the only mailbox owner, and each workflow directly composes owner transitions with rendering, synchronization, logging, or compaction.
  """

  alias MingaEditor.Agent.FileEventWorkflow
  alias MingaEditor.Agent.SessionEventWorkflow
  alias MingaEditor.Agent.StatusEventWorkflow
  alias MingaEditor.Agent.StreamEventWorkflow
  alias MingaEditor.Agent.ToolEventWorkflow
  alias MingaEditor.Agent.EditTimeline
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

  @doc "Applies one coalesced agent stream batch without changing mailbox ownership."
  @spec dispatch_batch(EditorState.t(), [term()]) :: EditorState.t()
  def dispatch_batch(%EditorState{} = state, batch) when is_list(batch),
    do: StreamEventWorkflow.batch(state, batch)

  @doc false
  @spec replay_catchup(EditorState.t(), [MingaAgent.EventLog.EventRecord.t()]) :: EditorState.t()
  def replay_catchup(%EditorState{} = state, events) when is_list(events) do
    events
    |> Enum.map(&event_record_to_editor_event/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(state, &replay_one_catchup_event/2)
  end

  @spec replay_one_catchup_event(term(), EditorState.t()) :: EditorState.t()
  defp replay_one_catchup_event(
         {:file_changed, path, _before, _after, tool_call_id, _tool_name} = event,
         state
       ) do
    replay_file_catchup(catchup_already_applied?(state, path, tool_call_id), event, state)
  end

  defp replay_one_catchup_event(event, state), do: replay_event(state, event)

  @spec replay_file_catchup(boolean(), term(), EditorState.t()) :: EditorState.t()
  defp replay_file_catchup(true, _event, state), do: state
  defp replay_file_catchup(false, event, state), do: replay_event(state, event)

  @spec replay_event(EditorState.t(), term()) :: EditorState.t()
  defp replay_event(
         state,
         {:file_changed, path, before_content, after_content, tool_call_id, tool_name}
       ) do
    FileEventWorkflow.replay_changed(
      state,
      path,
      before_content,
      after_content,
      tool_call_id,
      tool_name
    )
  end

  defp replay_event(state, {:status_changed, status}),
    do: StatusEventWorkflow.replay_status(state, status)

  defp replay_event(state, {:tool_started, _tool_call_id, _name, _args} = event),
    do: ToolEventWorkflow.replay(state, event)

  defp replay_event(state, {:tool_ended, _tool_call_id, _name, _result, _status} = event),
    do: ToolEventWorkflow.replay(state, event)

  defp replay_event(state, {:tool_interrupted, _tool_call_id} = event),
    do: ToolEventWorkflow.replay(state, event)

  defp replay_event(state, {:todo_plan_updated, _todos} = event),
    do: ToolEventWorkflow.replay(state, event)

  defp replay_event(state, _event), do: state

  @spec catchup_already_applied?(EditorState.t(), String.t(), String.t()) :: boolean()
  defp catchup_already_applied?(state, path, tool_call_id) do
    state.workspace.agent_ui.view
    |> Map.get(:edit_timeline)
    |> EditTimeline.entries_for(path)
    |> Enum.any?(&(&1.tool_call_id == tool_call_id))
  end

  @spec event_record_to_editor_event(MingaAgent.EventLog.EventRecord.t()) :: term() | nil
  defp event_record_to_editor_event(%{event_type: :file_edit_proposed, payload: payload}) do
    {:file_changed, payload["path"], payload["before_content"], payload["after_content"],
     payload["tool_call_id"], payload["tool_name"]}
  end

  defp event_record_to_editor_event(%{event_type: :todo_plan_updated, payload: payload}) do
    {:todo_plan_updated, todo_items_from_payload(Map.get(payload, "todos", []))}
  end

  defp event_record_to_editor_event(%{event_type: :tool_call_started, payload: payload}) do
    {:tool_started, payload_string(payload, "tool_call_id"), payload_string(payload, "name"),
     payload_map(payload, "args")}
  end

  defp event_record_to_editor_event(%{event_type: :tool_call_finished, payload: payload}) do
    {:tool_ended, payload_string(payload, "tool_call_id"), payload_string(payload, "name"),
     payload_string(payload, "result"), payload_status(payload)}
  end

  defp event_record_to_editor_event(%{event_type: :tool_call_interrupted, payload: payload}) do
    {:tool_interrupted, payload_string(payload, "tool_call_id")}
  end

  defp event_record_to_editor_event(_event), do: nil

  @spec todo_items_from_payload(term()) :: [MingaAgent.TodoItem.t()]
  defp todo_items_from_payload(items) when is_list(items) do
    Enum.flat_map(items, fn
      %{} = item ->
        case todo_item_from_payload(item) do
          nil -> []
          todo -> [todo]
        end

      _invalid ->
        []
    end)
  end

  defp todo_items_from_payload(_items), do: []

  @spec todo_item_from_payload(map()) :: MingaAgent.TodoItem.t() | nil
  defp todo_item_from_payload(item) do
    id = payload_string(item, "id")
    description = payload_string(item, "description")
    build_todo_item(id, description, item)
  end

  @spec build_todo_item(String.t(), String.t(), map()) :: MingaAgent.TodoItem.t() | nil
  defp build_todo_item("", _description, _item), do: nil
  defp build_todo_item(_id, "", _item), do: nil

  defp build_todo_item(id, description, item) do
    %MingaAgent.TodoItem{id: id, description: description, status: todo_status_payload(item)}
  end

  @spec todo_status_payload(map()) :: MingaAgent.TodoItem.status()
  defp todo_status_payload(item) do
    case payload_string(item, "status") do
      "in_progress" -> :in_progress
      "done" -> :done
      _status -> :pending
    end
  end

  @spec payload_map(map(), String.t()) :: map()
  defp payload_map(payload, key) do
    case Map.get(payload, key) || Map.get(payload, String.to_atom(key)) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  @spec payload_string(map(), String.t()) :: String.t()
  defp payload_string(payload, key) do
    case Map.get(payload, key) || Map.get(payload, String.to_atom(key)) do
      nil -> ""
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      value -> to_string(value)
    end
  end

  @spec payload_status(map()) :: :done | :error
  defp payload_status(payload) do
    case payload_string(payload, "status") do
      "done" -> :done
      _status -> :error
    end
  end
end
