defmodule MingaBoard.Frontend.Adapter.GUI.BoardEncoder do
  @moduledoc """
  Extension-owned legacy encoder for the Board GUI surface.

  Board is no longer part of the shared protocol schema. The extension keeps the old experimental wire format here so the implementation is owned with the Board package instead of `Minga.Frontend.Adapter.GUI`.
  """

  import Bitwise

  alias MingaBoard.RenderModel.UI.Board
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @extension_id "minga_board"
  @channel "board"
  @op_gui_board 0x87

  @spec encode(Board.t()) :: binary()
  def encode(%Board{} = model) do
    ProtocolGUI.encode_gui_extension_runtime(@extension_id, @channel, encode_payload(model))
  end

  @doc false
  @spec encode_payload(Board.t()) :: binary()
  def encode_payload(%Board{} = board) do
    :ok = validate_board!(board)
    cards = board.cards
    visible = if board.visible?, do: 1, else: 0
    focused_id = board.focused_card_id || 0

    card_entries = Enum.map(cards, &encode_card(&1, board.focused_card_id))

    filter_mode = if board.filter_mode?, do: 1, else: 0
    filter_bytes = :erlang.iolist_to_binary([board.filter_text])

    IO.iodata_to_binary([
      @op_gui_board,
      <<visible::8, focused_id::32, length(cards)::16, filter_mode::8,
        byte_size(filter_bytes)::16, filter_bytes::binary>>
      | card_entries
    ])
  end

  @spec encode_card(Board.Card.t(), pos_integer() | nil) :: binary()
  defp encode_card(%Board.Card{} = card, focused_id) do
    status_byte = status_byte(card.status)

    is_you = if Board.Card.you_card?(card), do: 1, else: 0
    is_focused = if card.id == focused_id, do: 1, else: 0
    flags = bor(is_you, bsl(is_focused, 1))

    task_bytes = :erlang.iolist_to_binary([card.display_task])
    model_bytes = :erlang.iolist_to_binary([card.model || ""])
    dispatch_timestamp = DateTime.to_unix(card.created_at)

    file_entries =
      Enum.map(card.recent_files, fn path ->
        path_bytes = :erlang.iolist_to_binary([path])
        <<byte_size(path_bytes)::16, path_bytes::binary>>
      end)

    sparkline_bytes =
      card.sparkline
      |> Enum.map(&encode_float16/1)
      |> IO.iodata_to_binary()

    IO.iodata_to_binary([
      <<card.id::32, status_byte::8, flags::8, byte_size(task_bytes)::16, task_bytes::binary,
        byte_size(model_bytes)::8, model_bytes::binary, dispatch_timestamp::32,
        length(card.recent_files)::8>>,
      file_entries,
      <<length(card.sparkline)::8, sparkline_bytes::binary>>
    ])
  end

  @spec encode_float16(number()) :: binary()
  defp encode_float16(value) do
    clamped = max(0.0, min(1.0, value))
    scaled = round(clamped * 65_535.0)
    <<scaled::16>>
  end

  @spec status_byte(Board.Card.status()) :: non_neg_integer()
  defp status_byte(:idle), do: 0
  defp status_byte(:working), do: 1
  defp status_byte(:iterating), do: 2
  defp status_byte(:needs_you), do: 3
  defp status_byte(:done), do: 4
  defp status_byte(:errored), do: 5

  @spec validate_board!(Board.t()) :: :ok
  defp validate_board!(%Board{cards: cards}) do
    Enum.each(cards, &validate_card!/1)
  end

  @spec validate_card!(Board.Card.t()) :: :ok
  defp validate_card!(%Board.Card{} = card) do
    with true <- is_integer(card.id) and card.id > 0,
         true <- card.status in [:idle, :working, :iterating, :needs_you, :done, :errored],
         true <- card.kind in [:you, :agent],
         true <- is_binary(card.task),
         true <- is_binary(card.display_task),
         true <- is_nil(card.model) or is_binary(card.model),
         true <- match?(%DateTime{}, card.created_at),
         true <- is_list(card.recent_files) and Enum.all?(card.recent_files, &is_binary/1),
         true <- is_list(card.sparkline) and Enum.all?(card.sparkline, &is_number/1) do
      :ok
    else
      false -> raise ArgumentError, "invalid board card: #{inspect(card)}"
    end
  end
end
