defmodule MingaEditor.Frontend.Protocol.GUINotificationsTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.UI.Notification
  alias MingaEditor.UI.NotificationCenter

  test "encodes notification snapshots in a length-prefixed envelope" do
    center =
      NotificationCenter.new()
      |> NotificationCenter.upsert(
        Notification.new(
          id: "build:test",
          level: :error,
          title: "Build failed",
          body: "mix test exited with code 1",
          source: "Build",
          actions: [%{id: "show_logs", label: "Show logs"}],
          created_at: 1_715_000_000
        )
      )

    encoded = ProtocolGUI.encode_gui_notifications(center)

    assert <<0x99, payload_len::16, payload::binary>> = encoded
    assert payload_len == byte_size(payload)
    assert encoded =~ "build:test"
    assert encoded =~ "Build failed"
    assert encoded =~ "Show logs"
  end

  test "encodes the newer updated_at when a notification is replaced in place" do
    center =
      NotificationCenter.new()
      |> NotificationCenter.upsert(
        Notification.new(
          id: "build:test",
          level: :progress,
          title: "Building Minga",
          created_at: 1_715_000_000
        )
      )
      |> NotificationCenter.upsert(
        Notification.new(
          id: "build:test",
          level: :error,
          title: "Build failed",
          created_at: 1_715_000_120,
          actions: [%{id: "show_logs", label: "Show logs"}]
        )
      )

    [notification] = NotificationCenter.list(center)
    assert notification.created_at == 1_715_000_000
    assert notification.updated_at == 1_715_000_120

    encoded = ProtocolGUI.encode_gui_notifications(center)

    assert <<0x99, _payload_len::16, 1::8, 1::16, id_len::16, _id::binary-size(id_len), _level::8,
             _flags::8, 1_715_000_000::64, 1_715_000_120::64, _rest::binary>> = encoded
  end

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
