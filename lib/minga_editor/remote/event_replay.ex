defmodule MingaEditor.Remote.EventReplay do
  @moduledoc "Replays durable remote agent events into the foreground agent UI."

  alias MingaEditor.Agent.Events
  alias MingaEditor.State, as: EditorState
  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.Tool.Output.Codec, as: OutputCodec

  @type event :: term()

  @doc "Applies replayable event-log records to the active agent surface."
  @spec replay_active(EditorState.t(), pid(), [EventRecord.t()]) :: EditorState.t()
  def replay_active(%EditorState{} = state, session_pid, records)
      when is_pid(session_pid) and is_list(records) do
    Enum.reduce(records, state, fn record, acc ->
      case to_agent_event(record) do
        nil ->
          acc

        event ->
          replay_event(acc, session_pid, event)
      end
    end)
  end

  @doc "Converts replayable history into UI events. Live approval and question controls come from the Session snapshot."
  @spec to_agent_event(EventRecord.t()) :: event() | nil
  def to_agent_event(%EventRecord{event_type: :assistant_delta, payload: payload}),
    do: {:text_delta, string_payload(payload, "delta")}

  def to_agent_event(%EventRecord{event_type: :thinking_delta, payload: payload}),
    do: {:thinking_delta, string_payload(payload, "delta")}

  def to_agent_event(%EventRecord{event_type: :tool_call_started, payload: payload}) do
    {:tool_started, string_payload(payload, "tool_call_id"), string_payload(payload, "name"),
     map_payload(payload, "args")}
  end

  def to_agent_event(%EventRecord{event_type: :tool_call_finished, payload: payload}) do
    with {:ok, outcome, reason} <- tool_status(payload),
         {:ok, output} <- output_payload(payload) do
      {:tool_ended,
       %MingaAgent.Event.ToolEnd{
         tool_call_id: string_payload(payload, "tool_call_id"),
         name: string_payload(payload, "name"),
         result: string_payload(payload, "result"),
         outcome: outcome,
         reason: reason,
         is_error: outcome != :complete,
         output: output
       }}
    else
      {:error, reason} ->
        {:error,
         "Remote tool result could not be replayed: #{inspect(reason, limit: 4, printable_limit: 200)}"}
    end
  end

  def to_agent_event(%EventRecord{event_type: :tool_call_interrupted, payload: payload}) do
    {:tool_interrupted, string_payload(payload, "tool_call_id")}
  end

  def to_agent_event(%EventRecord{event_type: :tool_call_updated, payload: payload}) do
    {:tool_update, string_payload(payload, "tool_call_id"), string_payload(payload, "name"),
     string_payload(payload, "partial_result")}
  end

  def to_agent_event(%EventRecord{event_type: :file_edit_proposed, payload: payload}) do
    {:file_changed, string_payload(payload, "path"), string_payload(payload, "before_content"),
     string_payload(payload, "after_content"), string_payload(payload, "tool_call_id"),
     string_payload(payload, "tool_name")}
  end

  # Historical consent records cannot recreate or resolve a live approval attachment.
  def to_agent_event(%EventRecord{event_type: type})
      when type in [:approval_requested, :approval_resolved],
      do: nil

  def to_agent_event(%EventRecord{event_type: :status_changed, payload: payload}),
    do: {:status_changed, atom_payload(payload, "status")}

  def to_agent_event(%EventRecord{event_type: :waiting_for_input}), do: {:status_changed, :idle}

  def to_agent_event(%EventRecord{event_type: :prompt_queued, payload: payload}) do
    {:prompt_queued, string_payload(payload, "content"), atom_payload(payload, "queue")}
  end

  def to_agent_event(%EventRecord{event_type: :message_changed}), do: :messages_changed

  def to_agent_event(%EventRecord{event_type: :todo_plan_updated, payload: payload}) do
    {:todo_plan_updated, todo_items_from_payload(payload_value(payload, "todos"))}
  end

  def to_agent_event(%EventRecord{event_type: :error, payload: payload}),
    do: {:error, string_payload(payload, "message")}

  def to_agent_event(%EventRecord{event_type: :context_usage, payload: payload}) do
    {:context_usage, integer_payload(payload, "estimated_tokens"),
     integer_payload(payload, "context_limit")}
  end

  def to_agent_event(%EventRecord{event_type: :turn_limit_reached, payload: payload}) do
    {:turn_limit_reached, integer_payload(payload, "current"), integer_payload(payload, "limit")}
  end

  def to_agent_event(%EventRecord{}), do: nil

  @spec replay_event(EditorState.t(), pid(), event()) :: EditorState.t()
  defp replay_event(state, session, {:status_changed, status}),
    do: MingaEditor.Agent.StatusEventWorkflow.replay_status_changed(state, session, status)

  defp replay_event(state, session, event), do: Events.dispatch(state, session, event)

  @spec payload_value(map(), String.t()) :: term()
  defp payload_value(payload, key) when is_map(payload) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> Map.get(payload, String.to_atom(key))
    end
  end

  @spec tool_status(map()) ::
          {:ok, MingaAgent.ToolCall.outcome(), MingaAgent.ToolCall.terminal_reason()}
          | {:error, :invalid_tool_outcome}
  defp tool_status(payload) do
    with {:ok, outcome} <- tool_outcome(string_payload(payload, "status")),
         {:ok, reason} <- tool_reason(payload_value(payload, "reason")) do
      MingaAgent.ToolCall.saved_outcome(%{
        tool_outcome: outcome,
        tool_outcome_reason: reason,
        is_error: outcome != :complete
      })
    end
  end

  @spec tool_outcome(String.t()) ::
          {:ok, MingaAgent.ToolCall.outcome()} | {:error, :invalid_tool_outcome}
  defp tool_outcome("done"), do: {:ok, :complete}
  defp tool_outcome("complete"), do: {:ok, :complete}
  defp tool_outcome("denied"), do: {:ok, :denied}
  defp tool_outcome("cancelled"), do: {:ok, :cancelled}
  defp tool_outcome("error"), do: {:ok, :error}
  defp tool_outcome(_unknown), do: {:error, :invalid_tool_outcome}

  @spec tool_reason(term()) ::
          {:ok, MingaAgent.ToolCall.terminal_reason()} | {:error, :invalid_tool_outcome}
  defp tool_reason(nil), do: {:ok, nil}
  defp tool_reason(:approval_timeout), do: {:ok, :approval_timeout}
  defp tool_reason("approval_timeout"), do: {:ok, :approval_timeout}
  defp tool_reason(_unknown), do: {:error, :invalid_tool_outcome}

  @spec output_payload(map()) :: {:ok, MingaAgent.Tool.Output.t() | nil} | {:error, term()}
  defp output_payload(payload) do
    case payload_value(payload, "output") do
      nil -> {:ok, nil}
      value when is_map(value) -> OutputCodec.decode(value)
      _invalid -> {:error, :invalid_tool_output}
    end
  end

  @spec string_payload(map(), String.t()) :: String.t()
  defp string_payload(payload, key) do
    case payload_value(payload, key) do
      value when is_binary(value) -> value
      nil -> ""
      value when is_atom(value) -> Atom.to_string(value)
      value -> to_string(value)
    end
  end

  @spec map_payload(map(), String.t()) :: map()
  defp map_payload(payload, key) do
    case payload_value(payload, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  @spec todo_items_from_payload(term()) :: [MingaAgent.TodoItem.t()]
  defp todo_items_from_payload(items) when is_list(items) do
    Enum.flat_map(items, fn
      %{} = item ->
        case todo_item_from_payload(item) do
          nil -> []
          todo -> [todo]
        end

      _ ->
        []
    end)
  end

  defp todo_items_from_payload(_items), do: []

  @spec todo_item_from_payload(map()) :: MingaAgent.TodoItem.t() | nil
  defp todo_item_from_payload(item) do
    id = string_payload(item, "id")
    description = string_payload(item, "description")

    with true <- id != "" and description != "",
         {:ok, reference} <- OutputCodec.decode_reference(payload_value(item, "result_ref")) do
      %MingaAgent.TodoItem{
        id: id,
        description: description,
        status: todo_status_payload(item),
        note: payload_value(item, "note"),
        result_ref: reference
      }
    else
      _invalid -> nil
    end
  end

  @spec todo_status_payload(map()) :: MingaAgent.TodoItem.status()
  defp todo_status_payload(item) do
    case string_payload(item, "status") do
      "in_progress" -> :in_progress
      "done" -> :done
      "blocked" -> :blocked
      _ -> :pending
    end
  end

  @spec atom_payload(map(), String.t()) :: atom()
  defp atom_payload(payload, key) do
    payload
    |> string_payload(key)
    |> String.to_existing_atom()
  rescue
    ArgumentError -> :unknown
  end

  @spec integer_payload(map(), String.t()) :: integer()
  defp integer_payload(payload, key) do
    case payload_value(payload, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value)
      _ -> 0
    end
  end

  @spec parse_integer(String.t()) :: integer()
  defp parse_integer(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 0
    end
  end
end
