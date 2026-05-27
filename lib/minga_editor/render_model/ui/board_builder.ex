defmodule MingaEditor.RenderModel.UI.BoardBuilder do
  @moduledoc false

  alias Minga.Log
  alias Minga.RenderModel.UI.Board
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Frontend.Protocol.GUI.BoardPayload

  @spec build(term()) :: Board.t()
  def build({:board, %BoardPayload{} = board}) do
    fp = board_fingerprint(board)
    encoded = ProtocolGUI.encode_gui_board(board)

    %Board{encoded: encoded, fingerprint: fp}
  end

  def build(nil) do
    encoded = ProtocolGUI.encode_gui_board(BoardPayload.hidden())

    %Board{encoded: encoded, fingerprint: :dismissed}
  end

  def build(other) do
    Log.warning(
      :render,
      "Unsupported GUI shell payload #{inspect(other)}; dismissing Board surface"
    )

    encoded = ProtocolGUI.encode_gui_board(BoardPayload.hidden())

    %Board{encoded: encoded, fingerprint: :dismissed}
  end

  @spec board_fingerprint(BoardPayload.t()) :: integer()
  defp board_fingerprint(board) do
    cards =
      Enum.map(board.cards, fn card ->
        {card.id, card.status, card.kind, card.task, card.display_task, card.model,
         card.created_at, card.recent_files, card.sparkline}
      end)

    :erlang.phash2({
      board.focused_card_id,
      board.zoomed_card_id,
      board.filter_mode?,
      board.filter_text,
      cards
    })
  end
end
