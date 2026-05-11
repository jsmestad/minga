defmodule MingaAgent.Hooks.UserPromptSubmitPayload do
  @moduledoc """
  Public payload passed to `UserPromptSubmit` hooks.

  Sent to the hook command's stdin as JSON before a user prompt is forwarded
  to the LLM provider. A non-zero exit from the hook vetoes the prompt.
  """

  @derive {Jason.Encoder, only: [:event, :session_id, :prompt]}
  @enforce_keys [:session_id, :prompt]
  defstruct [:session_id, :prompt, event: "UserPromptSubmit"]

  @typedoc "Payload for a user prompt about to be sent."
  @type t :: %__MODULE__{
          event: String.t(),
          session_id: String.t(),
          prompt: String.t()
        }

  @doc "Builds a payload from session_id and prompt content."
  @spec new(String.t(), String.t() | [term()]) :: t()
  def new(session_id, content) when is_binary(session_id) and is_binary(content) do
    %__MODULE__{session_id: session_id, prompt: content}
  end

  def new(session_id, content) when is_binary(session_id) and is_list(content) do
    %__MODULE__{session_id: session_id, prompt: extract_text(content)}
  end

  @doc "Converts the payload to the JSON object shape used on stdin."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payload) do
    %{
      "event" => payload.event,
      "session_id" => payload.session_id,
      "prompt" => payload.prompt
    }
  end

  @spec extract_text([term()]) :: String.t()
  defp extract_text(parts) do
    parts
    |> Enum.reduce([], fn
      %{type: :text, text: text}, acc when is_binary(text) -> [text | acc]
      part, acc when is_binary(part) -> [part | acc]
      _other, acc -> acc
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end
end
