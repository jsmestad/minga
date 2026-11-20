defmodule MingaAgent.Session.QueuedInputSummary do
  @moduledoc "The displayed identity and bounded preview of one pending Agent input."

  alias MingaAgent.Session.TurnExecution

  @enforce_keys [:identity, :kind, :preview, :attachment_count]
  defstruct [:identity, :kind, :preview, :attachment_count]

  @type identity :: {pos_integer(), pos_integer()}
  @type t :: %__MODULE__{
          identity: identity(),
          kind: TurnExecution.prompt_kind(),
          preview: String.t(),
          attachment_count: non_neg_integer()
        }

  @spec new(TurnExecution.queued_input(), TurnExecution.prompt_kind()) :: t()
  def new({id, revision, content, attachments, source}, kind) do
    %__MODULE__{
      identity: {id, revision},
      kind: kind,
      preview: source |> text_preview(content) |> String.byte_slice(0, 240),
      attachment_count: length(attachments)
    }
  end

  @spec text_preview(String.t() | nil, TurnExecution.content()) :: String.t()
  defp text_preview(source, _content) when is_binary(source), do: source
  defp text_preview(nil, text) when is_binary(text), do: text

  defp text_preview(nil, parts) do
    Enum.find_value(parts, "", fn
      %ReqLLM.Message.ContentPart{type: :text, text: text} when is_binary(text) -> text
      _part -> nil
    end)
  end
end
