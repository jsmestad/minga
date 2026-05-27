defmodule MingaEditor.RenderModel.UI.ChangeSummaryBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.ChangeSummary
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @spec build(term()) :: ChangeSummary.t()
  def build({:board, %{zoomed_card_id: card_id}}) when card_id != nil do
    build_for_board_card(card_id)
  end

  def build(_gui_payload) do
    build_hidden()
  end

  @spec build_for_board_card(pos_integer()) :: ChangeSummary.t()
  defp build_for_board_card(card_id) do
    # TODO: Compute diff stats from the card's touched files
    entries = []
    selected_index = 0

    fp = :erlang.phash2({card_id, entries})
    encoded = ProtocolGUI.encode_gui_change_summary(entries, selected_index)

    %ChangeSummary{encoded: encoded, fingerprint: fp}
  end

  @spec build_hidden() :: ChangeSummary.t()
  defp build_hidden do
    encoded = ProtocolGUI.encode_gui_change_summary([], 0)

    %ChangeSummary{encoded: encoded, fingerprint: :hidden}
  end
end
