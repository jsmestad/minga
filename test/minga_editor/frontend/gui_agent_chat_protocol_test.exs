defmodule MingaEditor.Frontend.GUIAgentChatProtocolTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Frontend.Protocol

  describe "decode_gui_action for agent_tool_toggle" do
    test "decodes stable message IDs" do
      assert {:ok, {:agent_tool_toggle, 0x01020304}} ==
               ProtocolGUI.decode_gui_action(0x15, <<0x01020304::32>>)

      assert {:ok, {:agent_tool_toggle, 0}} ==
               ProtocolGUI.decode_gui_action(0x15, <<0::32>>)

      assert {:ok, {:agent_tool_toggle, 0xFFFF_FFFF}} ==
               ProtocolGUI.decode_gui_action(0x15, <<0xFFFF_FFFF::32>>)
    end

    test "rejects old and malformed payload sizes" do
      assert :error == ProtocolGUI.decode_gui_action(0x15, <<7::16>>)
      assert :error == ProtocolGUI.decode_gui_action(0x15, <<7>>)
      assert :error == ProtocolGUI.decode_gui_action(0x15, <<>>)
      assert :error == ProtocolGUI.decode_gui_action(0x15, <<1, 2, 3>>)
    end

    test "decodes the full gui_action event with stable message ID" do
      assert {:ok, {:gui_action, {:agent_tool_toggle, 0x01020304}}} ==
               Protocol.decode_event(
                 <<Minga.Protocol.Opcodes.gui_action(), 0x15, 0x01, 0x02, 0x03, 0x04>>
               )
    end
  end
end
