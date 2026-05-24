defmodule MingaAgent.Hooks.SessionEndPayload do
  @moduledoc """
  Public payload passed to `SessionEnd` hooks.

  Sent to the hook command's stdin as JSON when an agent session terminates.
  """

  @derive {JSON.Encoder, only: [:event, :session_id, :reason, :status]}
  @enforce_keys [:session_id, :reason, :status]
  defstruct [:session_id, :reason, :status, event: "SessionEnd"]

  @typedoc "Payload for a session that just ended."
  @type t :: %__MODULE__{
          event: String.t(),
          session_id: String.t(),
          reason: String.t(),
          status: String.t()
        }

  @doc "Builds a payload from session state and terminate reason."
  @spec new(String.t(), term(), atom()) :: t()
  def new(session_id, reason, status)
      when is_binary(session_id) and is_atom(status) do
    %__MODULE__{
      session_id: session_id,
      reason: normalize_reason(reason),
      status: to_string(status)
    }
  end

  @doc "Converts the payload to the JSON object shape used on stdin."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payload) do
    %{
      "event" => payload.event,
      "session_id" => payload.session_id,
      "reason" => payload.reason,
      "status" => payload.status
    }
  end

  @spec normalize_reason(term()) :: String.t()
  defp normalize_reason(:normal), do: "normal"
  defp normalize_reason(:shutdown), do: "shutdown"
  defp normalize_reason({:shutdown, _}), do: "shutdown"
  defp normalize_reason(_other), do: "crash"
end
