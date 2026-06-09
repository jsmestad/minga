defmodule MingaBoard.Frontend.Adapter.GUI.ActionDecoderTest do
  use ExUnit.Case, async: true

  alias MingaBoard.Frontend.Adapter.GUI.ActionDecoder

  test "decodes generic extension select action" do
    assert {:ok, {:board_select_card, 7}} =
             ActionDecoder.decode({:extension_action, "minga_board", "select_card", <<7::32>>})
  end

  test "decodes generic extension reorder action" do
    assert {:ok, {:board_reorder, 7, 2}} =
             ActionDecoder.decode({:extension_action, "minga_board", "reorder", <<7::32, 2::16>>})
  end

  test "decodes generic extension dispatch action" do
    payload = <<3::16, "fix", 8::16, "claude-4">>

    assert {:ok, {:board_dispatch_agent, "fix", "claude-4"}} =
             ActionDecoder.decode({:extension_action, "minga_board", "dispatch_agent", payload})
  end

  test "rejects other extension ids and malformed payloads" do
    assert :error = ActionDecoder.decode({:extension_action, "other", "select_card", <<7::32>>})

    assert :error =
             ActionDecoder.decode({:extension_action, "minga_board", "select_card", <<1::16>>})
  end
end
