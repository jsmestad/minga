defmodule Minga.Frontend.Adapter.GUI.NotificationsEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.NotificationsEncoder
  alias Minga.RenderModel.UI.Notifications
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.UI.Notification
  alias MingaEditor.UI.NotificationCenter

  @op_gui_notifications Minga.Protocol.Opcodes.gui_notifications()

  describe "encode/2" do
    test "encodes empty notifications" do
      model = %Notifications{items: []}
      caches = Caches.new()

      {cmd, _caches} = NotificationsEncoder.encode(model, caches)

      assert <<@op_gui_notifications, _len::16, 1::8, 0::16>> = cmd
    end

    test "encodes notifications with items" do
      model = %Notifications{
        items: [
          %{
            id: "test-1",
            level: :info,
            title: "Hello",
            body: "World",
            source: "test",
            actions: [],
            dismissable: true,
            auto_dismiss_ms: nil,
            created_at: 1_000_000,
            updated_at: 1_000_000
          }
        ]
      }

      caches = Caches.new()
      {cmd, _caches} = NotificationsEncoder.encode(model, caches)

      assert <<@op_gui_notifications, _len::16, 1::8, 1::16, _rest::binary>> = cmd
    end

    test "returns nil on second call with same model (fingerprint skip)" do
      model = %Notifications{items: []}
      caches = Caches.new()

      {cmd1, caches} = NotificationsEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = NotificationsEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "produces byte-identical output to legacy ProtocolGUI for empty center" do
      center = NotificationCenter.new()
      legacy_binary = ProtocolGUI.encode_gui_notifications(center)

      model = MingaEditor.RenderModel.UI.NotificationsBuilder.build(center)
      caches = Caches.new()
      {new_binary, _caches} = NotificationsEncoder.encode(model, caches)

      assert new_binary == legacy_binary,
             "Empty notifications: new encoder output does not match legacy output"
    end

    test "produces byte-identical output to legacy ProtocolGUI with notifications" do
      notification =
        Notification.new(%{
          id: "notify-1",
          level: :warning,
          title: "Warning!",
          body: "Something happened",
          source: "test-source",
          created_at: 1_700_000_000,
          actions: [%{id: "dismiss", label: "Dismiss"}]
        })

      center = NotificationCenter.upsert(NotificationCenter.new(), notification)
      legacy_binary = ProtocolGUI.encode_gui_notifications(center)

      model = MingaEditor.RenderModel.UI.NotificationsBuilder.build(center)
      caches = Caches.new()
      {new_binary, _caches} = NotificationsEncoder.encode(model, caches)

      assert new_binary == legacy_binary,
             "Notifications with items: new encoder output does not match legacy output"
    end

    test "produces byte-identical output to legacy ProtocolGUI with multiple notifications" do
      n1 =
        Notification.new(%{
          id: "n1",
          level: :info,
          title: "Info",
          created_at: 1_700_000_000
        })

      n2 =
        Notification.new(%{
          id: "n2",
          level: :error,
          title: "Error",
          body: "Big problem",
          created_at: 1_700_000_001,
          dismissable: false
        })

      n3 =
        Notification.new(%{
          id: "n3",
          level: :success,
          title: "Done",
          auto_dismiss_ms: 3000,
          created_at: 1_700_000_002
        })

      center =
        NotificationCenter.new()
        |> NotificationCenter.upsert(n1)
        |> NotificationCenter.upsert(n2)
        |> NotificationCenter.upsert(n3)

      legacy_binary = ProtocolGUI.encode_gui_notifications(center)

      model = MingaEditor.RenderModel.UI.NotificationsBuilder.build(center)
      caches = Caches.new()
      {new_binary, _caches} = NotificationsEncoder.encode(model, caches)

      assert new_binary == legacy_binary,
             "Multiple notifications: new encoder output does not match legacy output"
    end

    test "produces byte-identical output for progress level" do
      notification =
        Notification.new(%{
          id: "progress-1",
          level: :progress,
          title: "Loading...",
          created_at: 1_700_000_000
        })

      center = NotificationCenter.upsert(NotificationCenter.new(), notification)
      legacy_binary = ProtocolGUI.encode_gui_notifications(center)

      model = MingaEditor.RenderModel.UI.NotificationsBuilder.build(center)
      caches = Caches.new()
      {new_binary, _caches} = NotificationsEncoder.encode(model, caches)

      assert new_binary == legacy_binary
    end
  end
end
