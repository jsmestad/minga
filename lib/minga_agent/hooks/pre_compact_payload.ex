defmodule MingaAgent.Hooks.PreCompactPayload do
  @moduledoc """
  Public payload passed to `PreCompact` hooks.

  Sent to the hook command's stdin as JSON before context compaction runs.
  A non-zero exit from the hook vetoes compaction (context stays as-is).
  """

  @derive {Jason.Encoder, only: [:event, :session_id, :message_count]}
  @enforce_keys [:message_count]
  defstruct [:session_id, :message_count, event: "PreCompact"]

  @typedoc "Payload for a compaction about to run."
  @type t :: %__MODULE__{
          event: String.t(),
          session_id: String.t() | nil,
          message_count: non_neg_integer()
        }

  @doc "Builds a payload from context information."
  @spec new(non_neg_integer(), String.t() | nil) :: t()
  def new(message_count, session_id \\ nil) when is_integer(message_count) do
    %__MODULE__{message_count: message_count, session_id: session_id}
  end

  @doc "Converts the payload to the JSON object shape used on stdin."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payload) do
    %{
      "event" => payload.event,
      "session_id" => payload.session_id,
      "message_count" => payload.message_count
    }
  end
end
