defmodule MingaEditor.Remote.EventReplay do
  @moduledoc "Replays durable remote agent events into the foreground agent UI."

  alias MingaEditor.Agent.Events
  alias MingaEditor.Handlers.EffectHandler
  alias MingaEditor.State, as: EditorState
  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.ToolApproval.Preview

  @type event :: term()

  @doc "Applies replayable event-log records to the active agent surface."
  @spec replay_active(EditorState.t(), [EventRecord.t()]) :: EditorState.t()
  def replay_active(%EditorState{} = state, records) when is_list(records) do
    Enum.reduce(records, state, fn record, acc ->
      case to_agent_event(record) do
        nil ->
          acc

        event ->
          {acc, effects} = Events.handle(acc, event)
          EffectHandler.apply_effects(acc, effects)
      end
    end)
  end

  @doc "Converts a durable event-log record back into the live agent event shape."
  @spec to_agent_event(EventRecord.t()) :: event() | nil
  def to_agent_event(%EventRecord{event_type: :assistant_delta, payload: payload}),
    do: {:text_delta, string_payload(payload, "delta")}

  def to_agent_event(%EventRecord{event_type: :thinking_delta, payload: payload}),
    do: {:thinking_delta, string_payload(payload, "delta")}

  def to_agent_event(%EventRecord{event_type: :tool_call_updated, payload: payload}) do
    {:tool_update, string_payload(payload, "tool_call_id"), string_payload(payload, "name"),
     string_payload(payload, "partial_result")}
  end

  def to_agent_event(%EventRecord{event_type: :file_edit_proposed, payload: payload}) do
    {:file_changed, string_payload(payload, "path"), string_payload(payload, "before_content"),
     string_payload(payload, "after_content"), string_payload(payload, "tool_call_id"),
     string_payload(payload, "tool_name")}
  end

  def to_agent_event(%EventRecord{event_type: :approval_requested, payload: payload}) do
    approval = %{
      tool_call_id: string_payload(payload, "tool_call_id"),
      name: string_payload(payload, "name"),
      args: map_payload(payload, "args")
    }

    case approval_preview(payload_value(payload, "preview")) do
      nil -> {:approval_pending, approval}
      preview -> {:approval_pending, Map.put(approval, :preview, preview)}
    end
  end

  def to_agent_event(%EventRecord{event_type: :approval_resolved, payload: payload}),
    do: {:approval_resolved, atom_payload(payload, "decision")}

  def to_agent_event(%EventRecord{event_type: :status_changed, payload: payload}),
    do: {:status_changed, atom_payload(payload, "status")}

  def to_agent_event(%EventRecord{event_type: :waiting_for_input}), do: {:status_changed, :idle}

  def to_agent_event(%EventRecord{event_type: :prompt_queued, payload: payload}) do
    {:prompt_queued, string_payload(payload, "content"), atom_payload(payload, "queue")}
  end

  def to_agent_event(%EventRecord{event_type: :message_changed}), do: :messages_changed

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

  @spec approval_preview(term()) :: Preview.t() | nil
  defp approval_preview(%Preview{} = preview), do: preview

  defp approval_preview(%{} = preview) do
    case {payload_value(preview, "kind"), payload_value(preview, "summary"),
          payload_value(preview, "lines")} do
      {kind, summary, lines} when is_binary(summary) and is_list(lines) ->
        case preview_kind(kind) do
          nil ->
            nil

          preview_kind ->
            if Enum.all?(lines, &is_binary/1) do
              Preview.new(preview_kind, summary, lines)
            else
              nil
            end
        end

      _ ->
        nil
    end
  end

  defp approval_preview(_preview), do: nil

  @spec preview_kind(term()) :: Preview.kind() | nil
  defp preview_kind(kind) when is_atom(kind) and kind in [:diff, :command, :target, :args],
    do: kind

  defp preview_kind(kind) when is_binary(kind) do
    case kind do
      "diff" -> :diff
      "command" -> :command
      "target" -> :target
      "args" -> :args
      _ -> nil
    end
  end

  defp preview_kind(_kind), do: nil

  @spec payload_value(map(), String.t()) :: term()
  defp payload_value(payload, key) when is_map(payload) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> Map.get(payload, String.to_atom(key))
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
