defmodule MingaEditor.Frontend.Protocol.GUIExtensionRuntimeTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Frontend.Protocol.GUI

  test "encodes generic frontend-extension runtime envelope" do
    payload = <<0x87, 1, 2, 3>>
    encoded = GUI.encode_gui_extension_runtime("sample_ext", "surface", payload)

    assert <<op, len::32, envelope::binary-size(len)>> = encoded
    assert op == Minga.Protocol.Opcodes.gui_extension_runtime()
    assert <<10::16, "sample_ext", 7::16, "surface", ^payload::binary>> = envelope
  end

  test "decodes generic frontend extension GUI action" do
    action_payload = <<10::16, "sample_ext", 6::16, "select", 1, 2, 3>>

    packet =
      <<Minga.Protocol.Opcodes.gui_action(), Minga.Protocol.Opcodes.gui_action_extension_action(),
        action_payload::binary>>

    assert {:ok, {:gui_action, {:extension_action, "sample_ext", "select", <<1, 2, 3>>}}} =
             Protocol.decode_event(packet)
  end
end
