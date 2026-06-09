defmodule MingaBoard.Frontend.Adapter.GUI.ActionDecoder do
  @moduledoc "Decodes generic frontend-extension GUI actions owned by the Board extension."

  @extension_id "minga_board"

  @type board_action ::
          {:board_select_card, non_neg_integer()}
          | {:board_close_card, non_neg_integer()}
          | {:board_reorder, non_neg_integer(), non_neg_integer()}
          | {:board_dispatch_agent, String.t(), String.t()}

  @spec decode({:extension_action, String.t(), String.t(), binary()}) ::
          {:ok, board_action()} | :error
  def decode({:extension_action, @extension_id, "select_card", <<card_id::32>>}),
    do: {:ok, {:board_select_card, card_id}}

  def decode({:extension_action, @extension_id, "close_card", <<card_id::32>>}),
    do: {:ok, {:board_close_card, card_id}}

  def decode({:extension_action, @extension_id, "reorder", <<card_id::32, new_index::16>>}),
    do: {:ok, {:board_reorder, card_id, new_index}}

  def decode(
        {:extension_action, @extension_id, "dispatch_agent",
         <<task_len::16, task::binary-size(task_len), model_len::16,
           model::binary-size(model_len)>>}
      ),
      do: {:ok, {:board_dispatch_agent, task, model}}

  def decode(_action), do: :error
end
