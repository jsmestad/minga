defmodule MingaAgent.EventLog.EventRecord do
  @moduledoc "A durable, replay-safe agent session event."

  @enforce_keys [:session_id, :event_type, :payload, :wall_clock, :monotonic_ts]
  defstruct [:id, :session_id, :event_type, :payload, :wall_clock, :monotonic_ts]

  @type event_type ::
          :session_started
          | :session_stopped
          | :user_message
          | :assistant_delta
          | :thinking_delta
          | :tool_call_started
          | :tool_call_updated
          | :tool_call_finished
          | :file_edit_proposed
          | :approval_requested
          | :approval_resolved
          | :system_message
          | :status_changed
          | :waiting_for_input
          | :prompt_queued
          | :message_changed
          | :error
          | :context_usage
          | :turn_limit_reached
          | :driver_changed

  @type t :: %__MODULE__{
          id: non_neg_integer() | nil,
          session_id: String.t(),
          event_type: event_type(),
          payload: map(),
          wall_clock: DateTime.t(),
          monotonic_ts: integer()
        }

  @doc "Creates a new event record."
  @spec new(String.t(), event_type(), map(), keyword()) :: t()
  def new(session_id, event_type, payload, opts \\ [])
      when is_binary(session_id) and is_atom(event_type) and is_map(payload) do
    %__MODULE__{
      session_id: session_id,
      event_type: event_type,
      payload: payload,
      wall_clock: Keyword.get_lazy(opts, :wall_clock, &DateTime.utc_now/0),
      monotonic_ts: Keyword.get_lazy(opts, :monotonic_ts, &System.monotonic_time/0)
    }
  end
end
