defmodule Minga.Port.GUIBottomPanelTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.BottomPanel
  alias Minga.Port.Protocol.GUI, as: ProtocolGUI

  describe "encode_gui_bottom_panel/1" do
    test "encodes hidden panel as 2 bytes" do
      panel = %BottomPanel{visible: false}
      binary = ProtocolGUI.encode_gui_bottom_panel(panel)
      assert <<0x7B, 0>> = binary
    end

    test "encodes visible panel with messages tab" do
      panel = %BottomPanel{
        visible: true,
        active_tab: :messages,
        tabs: [:messages],
        height_percent: 30,
        filter: nil
      }

      binary = ProtocolGUI.encode_gui_bottom_panel(panel)

      assert <<0x7B, 1, active_idx::8, height::8, filter::8, tab_count::8, rest::binary>> = binary

      assert active_idx == 0
      assert height == 30
      assert filter == 0
      assert tab_count == 1

      # Tab def: type(1) + name_len(1) + name
      assert <<0x01, name_len::8, name::binary-size(name_len)>> = rest
      assert name == "Messages"
    end

    test "encodes visible panel with multiple tabs" do
      panel = %BottomPanel{
        visible: true,
        active_tab: :diagnostics,
        tabs: [:messages, :diagnostics, :terminal],
        height_percent: 45,
        filter: :warnings
      }

      binary = ProtocolGUI.encode_gui_bottom_panel(panel)

      assert <<0x7B, 1, active_idx::8, height::8, filter::8, tab_count::8, rest::binary>> = binary

      # diagnostics is at index 1
      assert active_idx == 1
      assert height == 45
      assert filter == 1
      assert tab_count == 3

      # Parse all three tab defs
      assert <<0x01, len1::8, name1::binary-size(len1), 0x02, len2::8, name2::binary-size(len2),
               0x03, len3::8, name3::binary-size(len3)>> = rest

      assert name1 == "Messages"
      assert name2 == "Diagnostics"
      assert name3 == "Terminal"
    end

    test "encodes filter preset for warnings" do
      panel = %BottomPanel{visible: true, filter: :warnings}
      binary = ProtocolGUI.encode_gui_bottom_panel(panel)
      <<0x7B, 1, _active::8, _height::8, filter::8, _rest::binary>> = binary
      assert filter == 0x01
    end
  end

  describe "decode_gui_action for panel actions" do
    test "decodes panel_switch_tab" do
      assert {:ok, {:panel_switch_tab, 2}} =
               ProtocolGUI.decode_gui_action(0x09, <<2>>)
    end

    test "decodes panel_dismiss" do
      assert {:ok, :panel_dismiss} =
               ProtocolGUI.decode_gui_action(0x0A, <<>>)
    end

    test "decodes panel_resize" do
      assert {:ok, {:panel_resize, 45}} =
               ProtocolGUI.decode_gui_action(0x0B, <<45>>)
    end
  end
end
