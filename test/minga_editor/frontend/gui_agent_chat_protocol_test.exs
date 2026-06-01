defmodule MingaEditor.Frontend.GUIAgentChatProtocolTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  describe "decode_gui_action for agent_tool_toggle" do
    test "decodes a valid agent_tool_toggle action" do
      assert {:ok, {:agent_tool_toggle, 7}} ==
               ProtocolGUI.decode_gui_action(0x15, <<7::16>>)
    end

    test "decodes agent_tool_toggle at index 0" do
      assert {:ok, {:agent_tool_toggle, 0}} ==
               ProtocolGUI.decode_gui_action(0x15, <<0::16>>)
    end

    test "decodes agent_tool_toggle at max UInt16" do
      assert {:ok, {:agent_tool_toggle, 65_535}} ==
               ProtocolGUI.decode_gui_action(0x15, <<65_535::16>>)
    end

    test "returns error for short payload" do
      assert :error == ProtocolGUI.decode_gui_action(0x15, <<7>>)
    end

    test "returns error for empty payload" do
      assert :error == ProtocolGUI.decode_gui_action(0x15, <<>>)
    end
  end
end
