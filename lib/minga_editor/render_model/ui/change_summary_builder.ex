defmodule MingaEditor.RenderModel.UI.ChangeSummaryBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.ChangeSummary

  @spec build(term()) :: ChangeSummary.t()
  def build({:board, %{zoomed_card_id: card_id}}) when card_id != nil do
    build_for_board_card(card_id)
  end

  def build(_gui_payload) do
    %ChangeSummary{}
  end

  @spec build_for_board_card(pos_integer()) :: ChangeSummary.t()
  defp build_for_board_card(_card_id) do
    # TODO: Compute diff stats from the card's touched files
    %ChangeSummary{entries: [], selected_index: 0}
  end
end
