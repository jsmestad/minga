defmodule MingaEditor.Frontend.Protocol.GUINotificationsTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol

  test "decodes notification dismiss and action gui_actions" do
    id = "build:test"
    action = "show_logs"

    assert {:ok, {:gui_action, {:notification_dismiss, ^id}}} =
             Protocol.decode_event(<<0x07, 0x45, byte_size(id)::16, id::binary>>)

    assert {:ok, {:gui_action, {:notification_action, ^id, ^action}}} =
             Protocol.decode_event(
               <<0x07, 0x46, byte_size(id)::16, id::binary, byte_size(action)::16,
                 action::binary>>
             )
  end
end
