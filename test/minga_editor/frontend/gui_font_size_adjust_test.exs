defmodule MingaEditor.Frontend.GUIFontSizeAdjustTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias Minga.Protocol.Opcodes

  @gui_action_font_size_adjust Opcodes.gui_action_font_size_adjust()

  describe "decode_gui_action for font_size_adjust" do
    test "decodes decrease direction (0x00)" do
      assert {:ok, {:font_size_adjust, :decrease}} ==
               ProtocolGUI.decode_gui_action(@gui_action_font_size_adjust, <<0x00>>)
    end

    test "decodes increase direction (0x01)" do
      assert {:ok, {:font_size_adjust, :increase}} ==
               ProtocolGUI.decode_gui_action(@gui_action_font_size_adjust, <<0x01>>)
    end

    test "decodes reset direction (0x02)" do
      assert {:ok, {:font_size_adjust, :reset}} ==
               ProtocolGUI.decode_gui_action(@gui_action_font_size_adjust, <<0x02>>)
    end

    test "returns error for invalid direction byte" do
      assert :error == ProtocolGUI.decode_gui_action(@gui_action_font_size_adjust, <<0x03>>)
    end

    test "returns error for empty payload" do
      assert :error == ProtocolGUI.decode_gui_action(@gui_action_font_size_adjust, <<>>)
    end

    test "returns error for oversized payload" do
      assert :error == ProtocolGUI.decode_gui_action(@gui_action_font_size_adjust, <<0x01, 0x00>>)
    end
  end

  describe "full event decode for font_size_adjust" do
    @op_gui_action Opcodes.gui_action()

    test "decodes a complete font_size_adjust event" do
      binary = <<@op_gui_action, @gui_action_font_size_adjust, 0x01>>

      assert {:ok, {:gui_action, {:font_size_adjust, :increase}}} ==
               MingaEditor.Frontend.Protocol.decode_event(binary)
    end
  end
end
