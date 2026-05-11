defmodule MingaAgent.Hooks.StopPayload do
  @moduledoc """
  Public payload passed to `Stop` hooks.

  Sent to the hook command's stdin as JSON when the agent finishes a turn
  and transitions to idle.
  """

  @max_message_bytes 1_024

  @derive {Jason.Encoder, only: [:event, :session_id, :reason, :last_message]}
  @enforce_keys [:session_id, :reason]
  defstruct [:session_id, :reason, :last_message, event: "Stop"]

  @typedoc "Payload for an agent turn that just completed."
  @type t :: %__MODULE__{
          event: String.t(),
          session_id: String.t(),
          reason: String.t(),
          last_message: String.t() | nil
        }

  @doc "Builds a payload from session state fields."
  @spec new(String.t(), atom(), String.t() | nil) :: t()
  def new(session_id, reason, last_message \\ nil)
      when is_binary(session_id) and is_atom(reason) do
    %__MODULE__{
      session_id: session_id,
      reason: to_string(reason),
      last_message: truncate_message(last_message)
    }
  end

  @doc "Converts the payload to the JSON object shape used on stdin."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payload) do
    %{
      "event" => payload.event,
      "session_id" => payload.session_id,
      "reason" => payload.reason,
      "last_message" => payload.last_message
    }
  end

  @spec truncate_message(String.t() | nil) :: String.t() | nil
  defp truncate_message(nil), do: nil
  defp truncate_message(msg) when byte_size(msg) <= @max_message_bytes, do: msg

  defp truncate_message(msg) do
    truncated = String.byte_slice(msg, 0, @max_message_bytes)
    truncated <> "\n... (truncated)"
  end
end
