defmodule MingaAgent.EventLog.Taxonomy do
  @moduledoc "Canonical event names persisted by the agent event log."

  @type t :: MingaAgent.EventLog.EventRecord.event_type()

  @events [
    :session_started,
    :session_stopped,
    :user_disconnected,
    :user_message,
    :assistant_delta,
    :thinking_delta,
    :tool_call_started,
    :tool_call_updated,
    :tool_call_finished,
    :tool_call_interrupted,
    :file_edit_proposed,
    :approval_requested,
    :approval_resolved,
    :approval_interrupted,
    :system_message,
    :status_changed,
    :waiting_for_input,
    :prompt_queued,
    :message_changed,
    :error,
    :context_usage,
    :turn_limit_reached,
    :driver_changed
  ]

  @event_type_map Map.new(@events, fn atom -> {Atom.to_string(atom), atom} end)

  @doc "Returns the canonical persisted event names."
  @spec events() :: [t()]
  def events, do: @events

  @doc "Converts a stored event type string to its canonical atom, or `:error` for unknown types."
  @spec from_string(String.t()) :: {:ok, t()} | :error
  def from_string(type_string) when is_binary(type_string),
    do: Map.fetch(@event_type_map, type_string)

  @doc "Returns true when an atom is part of the canonical taxonomy."
  @spec known?(atom()) :: boolean()
  def known?(event_type) when is_atom(event_type), do: event_type in @events
end
