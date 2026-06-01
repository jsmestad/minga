defmodule MingaEditor.Frontend.GUIBottomPanelTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  # Bottom panel encoding now lives in Minga.Frontend.Adapter.GUI.BottomPanelEncoder
  # (wire format) and MingaEditor.RenderModel.UI.BottomPanelBuilder (message-store
  # cursor behavior). This module covers only the panel action decoding that still
  # lives in ProtocolGUI.

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
