defmodule MingaAgent.Hooks.SessionStartPayload do
  @moduledoc """
  Public payload passed to `SessionStart` hooks.

  Sent to the hook command's stdin as JSON when an agent session's provider
  becomes ready.
  """

  @derive {Jason.Encoder, only: [:event, :session_id, :model, :provider, :project_root]}
  @enforce_keys [:session_id, :model, :provider]
  defstruct [:session_id, :model, :provider, :project_root, event: "SessionStart"]

  @typedoc "Payload for a session that just started."
  @type t :: %__MODULE__{
          event: String.t(),
          session_id: String.t(),
          model: String.t(),
          provider: String.t(),
          project_root: String.t()
        }

  @doc "Builds a payload from session state fields."
  @spec new(String.t(), String.t(), String.t()) :: t()
  def new(session_id, model, provider)
      when is_binary(session_id) and is_binary(model) and is_binary(provider) do
    %__MODULE__{
      session_id: session_id,
      model: model,
      provider: provider,
      project_root: project_root()
    }
  end

  @doc "Converts the payload to the JSON object shape used on stdin."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payload) do
    %{
      "event" => payload.event,
      "session_id" => payload.session_id,
      "model" => payload.model,
      "provider" => payload.provider,
      "project_root" => payload.project_root
    }
  end

  @spec project_root() :: String.t()
  defp project_root do
    File.cwd!()
  rescue
    _ -> ""
  end
end
