defmodule MingaAgent.Hooks.NotificationPayload do
  @moduledoc """
  Public payload passed to `Notification` hooks.

  Sent to the hook command's stdin as JSON when the agent sends an OS
  notification. Notification-only (never blocks).
  """

  @derive {JSON.Encoder, only: [:event, :session_id, :kind, :message]}
  @enforce_keys [:session_id, :kind, :message]
  defstruct [:session_id, :kind, :message, event: "Notification"]

  @typedoc "Payload for an agent notification."
  @type t :: %__MODULE__{
          event: String.t(),
          session_id: String.t(),
          kind: String.t(),
          message: String.t()
        }

  @doc "Builds a payload from session and notification fields."
  @spec new(String.t(), atom(), String.t()) :: t()
  def new(session_id, kind, message)
      when is_binary(session_id) and is_atom(kind) and is_binary(message) do
    %__MODULE__{session_id: session_id, kind: to_string(kind), message: message}
  end

  @doc "Converts the payload to the JSON object shape used on stdin."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payload) do
    %{
      "event" => payload.event,
      "session_id" => payload.session_id,
      "kind" => payload.kind,
      "message" => payload.message
    }
  end
end
