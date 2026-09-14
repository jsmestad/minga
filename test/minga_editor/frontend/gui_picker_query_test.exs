defmodule MingaEditor.Frontend.GUIPickerQueryTest do
  use ExUnit.Case, async: true

  alias Minga.Protocol.Opcodes
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_action Opcodes.gui_action()
  @gui_action_picker_query_changed Opcodes.gui_action_picker_query_changed()
  @gui_action_picker_item_activate Opcodes.gui_action_picker_item_activate()
  @gui_action_picker_action_activate Opcodes.gui_action_picker_action_activate()

  test "decodes a correlated native picker query" do
    query = "café"

    payload =
      <<7::32, 11::32, byte_size(query)::16, query::binary>>

    assert {:ok, {:picker_query_changed, 7, 11, ^query}} =
             ProtocolGUI.decode_gui_action(@gui_action_picker_query_changed, payload)
  end

  test "rejects truncated picker query payloads" do
    assert :error =
             ProtocolGUI.decode_gui_action(
               @gui_action_picker_query_changed,
               <<7::32, 11::32, 5::16, "hi">>
             )
  end

  test "decodes a complete picker query input event" do
    binary =
      <<@op_gui_action, @gui_action_picker_query_changed, 9::32, 4::32, 3::16, "src">>

    assert {:ok, {:gui_action, {:picker_query_changed, 9, 4, "src"}}} =
             Protocol.decode_event(binary)
  end

  test "decodes exact picker item and action activation identities" do
    assert {:ok, {:picker_item_activate, 7, 11}} =
             ProtocolGUI.decode_gui_action(@gui_action_picker_item_activate, <<7::32, 11::32>>)

    assert {:ok, {:picker_action_activate, 13, 17}} =
             ProtocolGUI.decode_gui_action(@gui_action_picker_action_activate, <<13::32, 17::32>>)

    assert :error = ProtocolGUI.decode_gui_action(@gui_action_picker_item_activate, <<7::32>>)
  end
end
