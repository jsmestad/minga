defmodule MingaEditor.Frontend.GUIEditTimelineTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias Minga.Protocol.Opcodes

  @gui_action_timeline_navigate Opcodes.gui_action_timeline_navigate()

  describe "encode_gui_edit_timeline/3" do
    test "encodes hidden timeline" do
      binary = ProtocolGUI.encode_gui_edit_timeline(false, nil, [])
      <<opcode, _payload_len::16, visible, viewing::16, count>> = binary
      assert opcode == Opcodes.gui_edit_timeline()
      assert visible == 0
      assert viewing == 0xFFFF
      assert count == 0
    end

    test "encodes visible timeline with entries" do
      entries = [
        %{index: 0, tool_name: "edit_file", timestamp_delta: 0},
        %{index: 1, tool_name: "write_file", timestamp_delta: 500}
      ]

      binary = ProtocolGUI.encode_gui_edit_timeline(true, 1, entries)
      <<_opcode, payload_len::16, payload::binary-size(payload_len)>> = binary
      <<visible, viewing::16, count, rest::binary>> = payload
      assert visible == 1
      assert viewing == 1
      assert count == 2

      <<0, 9, "edit_file", 0::32, 1, 10, "write_file", 500::32>> = rest
    end

    test "encodes nil viewing_index as 0xFFFF" do
      binary = ProtocolGUI.encode_gui_edit_timeline(true, nil, [])
      <<_opcode, _payload_len::16, _visible, viewing::16, _count>> = binary
      assert viewing == 0xFFFF
    end
  end

  describe "decode_gui_action for timeline_navigate" do
    test "decodes navigate to index" do
      assert {:ok, {:timeline_navigate, 3}} ==
               ProtocolGUI.decode_gui_action(@gui_action_timeline_navigate, <<0, 3>>)
    end

    test "decodes navigate to index 0" do
      assert {:ok, {:timeline_navigate, 0}} ==
               ProtocolGUI.decode_gui_action(@gui_action_timeline_navigate, <<0, 0>>)
    end
  end

  describe "full event decode for timeline_navigate" do
    @op_gui_action Opcodes.gui_action()

    test "decodes a complete timeline_navigate event" do
      binary = <<@op_gui_action, @gui_action_timeline_navigate, 0, 5>>

      assert {:ok, {:gui_action, {:timeline_navigate, 5}}} ==
               MingaEditor.Frontend.Protocol.decode_event(binary)
    end
  end
end
