defmodule Minga.Port.GUIExecuteCommandTest do
  use ExUnit.Case, async: true

  alias Minga.Port.Protocol.GUI, as: ProtocolGUI

  describe "decode_gui_action for execute_command (0x16)" do
    test "decodes a valid command name" do
      name = "buffer_prev"
      name_len = byte_size(name)
      payload = <<name_len::16, name::binary>>

      assert {:ok, {:execute_command, "buffer_prev"}} ==
               ProtocolGUI.decode_gui_action(0x16, payload)
    end

    test "decodes a longer command name" do
      name = "split_vertical"
      name_len = byte_size(name)
      payload = <<name_len::16, name::binary>>

      assert {:ok, {:execute_command, "split_vertical"}} ==
               ProtocolGUI.decode_gui_action(0x16, payload)
    end

    test "decodes an empty command name" do
      payload = <<0::16>>

      assert {:ok, {:execute_command, ""}} ==
               ProtocolGUI.decode_gui_action(0x16, payload)
    end

    test "returns error for truncated payload" do
      assert :error == ProtocolGUI.decode_gui_action(0x16, <<0>>)
    end

    test "returns error for empty payload" do
      assert :error == ProtocolGUI.decode_gui_action(0x16, <<>>)
    end

    test "returns error for payload shorter than declared length" do
      # Declares 10 bytes but only provides 3
      assert :error == ProtocolGUI.decode_gui_action(0x16, <<10::16, "abc">>)
    end
  end
end
