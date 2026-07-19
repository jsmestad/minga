defmodule MingaEditor.Frontend.GUIMinibufferProtocolTest do
  @moduledoc """
  Tests for retained minibuffer_select GUI action decoding.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  describe "decode_gui_action for minibuffer_select (0x17)" do
    test "decodes a valid candidate index" do
      assert {:ok, {:minibuffer_select, 3}} ==
               ProtocolGUI.decode_gui_action(0x17, <<3::16>>)
    end

    test "decodes index 0" do
      assert {:ok, {:minibuffer_select, 0}} ==
               ProtocolGUI.decode_gui_action(0x17, <<0::16>>)
    end

    test "decodes max uint16 index" do
      assert {:ok, {:minibuffer_select, 65_535}} ==
               ProtocolGUI.decode_gui_action(0x17, <<65_535::16>>)
    end

    test "returns error for short payload" do
      assert :error == ProtocolGUI.decode_gui_action(0x17, <<3>>)
    end

    test "returns error for empty payload" do
      assert :error == ProtocolGUI.decode_gui_action(0x17, <<>>)
    end
  end
end
