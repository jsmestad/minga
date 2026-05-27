defmodule MingaEditor.RenderModel.UI.AgentContextBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.AgentContext
  alias MingaEditor.Frontend.Protocol.GUI.BoardCardPayload
  alias MingaEditor.Frontend.Protocol.GUI.BoardPayload

  @spec build(term()) :: AgentContext.t()
  def build({:board, %BoardPayload{} = board}) do
    card = BoardPayload.zoomed_card(board)
    build_from_card(board.zoomed_card_id, card)
  end

  def build(_other) do
    %AgentContext{visible: false}
  end

  @spec build_from_card(pos_integer() | nil, BoardCardPayload.t() | nil) :: AgentContext.t()
  defp build_from_card(_card_id, nil) do
    %AgentContext{visible: false}
  end

  defp build_from_card(_card_id, %BoardCardPayload{} = card) do
    if BoardCardPayload.you_card?(card) do
      %AgentContext{visible: false}
    else
      %AgentContext{
        visible: true,
        task: card.task,
        dispatch_timestamp: card.created_at,
        status: card.status,
        can_approve: card.status in [:needs_you, :done]
      }
    end
  end
end
