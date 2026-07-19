defmodule Minga.Frontend.Adapter.GUI.NotificationsEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.NotificationsEncoder
  alias Minga.RenderModel.UI.Notifications
  alias MingaEditor.RenderModel.UI.NotificationsBuilder
  alias MingaEditor.UI.Notification
  alias MingaEditor.UI.NotificationCenter

  @op_gui_notifications Minga.Protocol.Opcodes.gui_notifications()

  describe "encode/2" do
    test "encodes empty notifications exactly" do
      {cmd, _caches} = NotificationsEncoder.encode(%Notifications{items: []}, Caches.new())

      assert cmd == <<@op_gui_notifications, 3::16, 1, 0::16>>
    end

    test "encodes one notification with an action exactly" do
      model = %Notifications{
        items: [
          %{
            id: "notify-1",
            level: :error,
            title: "Build failed",
            body: "mix test exited with code 1",
            source: "Build",
            actions: [%{id: "show_logs", label: "Show logs"}],
            dismissable: true,
            auto_dismiss_ms: nil,
            created_at: 1_715_000_000,
            updated_at: 1_715_000_120
          }
        ]
      }

      {cmd, _caches} = NotificationsEncoder.encode(model, Caches.new())

      assert <<@op_gui_notifications, payload_len::16, payload::binary>> = cmd
      assert payload_len == byte_size(payload)

      assert <<1, 1::16, id_len::16, id::binary-size(id_len), 2, 0x01, 1_715_000_000::64,
               1_715_000_120::64, 0xFFFF_FFFF::32, title_len::16, title::binary-size(title_len),
               body_len::16, body::binary-size(body_len), source_len::16,
               source::binary-size(source_len), 1, action_id_len::16,
               action_id::binary-size(action_id_len), action_label_len::16,
               action_label::binary-size(action_label_len)>> = payload

      assert id == "notify-1"
      assert title == "Build failed"
      assert body == "mix test exited with code 1"
      assert source == "Build"
      assert action_id == "show_logs"
      assert action_label == "Show logs"
    end

    test "encodes multiple notifications preserving count, order, levels, and dismissable flag" do
      model = %Notifications{
        items: [
          item("n1", :info, "Info", created_at: 1_700_000_000),
          item("n2", :error, "Error",
            body: "Big problem",
            dismissable: false,
            created_at: 1_700_000_001
          ),
          item("n3", :success, "Done", auto_dismiss_ms: 3000, created_at: 1_700_000_002)
        ]
      }

      {cmd, _caches} = NotificationsEncoder.encode(model, Caches.new())
      <<@op_gui_notifications, payload_len::16, payload::binary-size(payload_len)>> = cmd

      {header, entries} = decode_notifications(payload)
      assert header == {1, 3}
      assert Enum.map(entries, & &1.id) == ["n1", "n2", "n3"]
      assert Enum.map(entries, & &1.level) == [0, 2, 3]
      assert Enum.map(entries, & &1.flags) == [0x01, 0x00, 0x01]
      assert Enum.at(entries, 2).auto_dismiss_ms == 3000
    end

    test "encodes progress level and explicit auto-dismiss" do
      model = %Notifications{
        items: [item("progress-1", :progress, "Loading...", auto_dismiss_ms: 3000)]
      }

      {cmd, _caches} = NotificationsEncoder.encode(model, Caches.new())
      <<@op_gui_notifications, _payload_len::16, payload::binary>> = cmd
      {_header, [entry]} = decode_notifications(payload)

      assert entry.level == 4
      assert entry.auto_dismiss_ms == 3000
    end

    test "encodes NotificationCenter replacement timestamps through the builder owner" do
      center =
        NotificationCenter.new()
        |> NotificationCenter.upsert(
          Notification.new(
            id: "build:test",
            level: :progress,
            title: "Building",
            created_at: 1_715_000_000
          )
        )
        |> NotificationCenter.upsert(
          Notification.new(
            id: "build:test",
            level: :error,
            title: "Build failed",
            created_at: 1_715_000_120
          )
        )

      model = NotificationsBuilder.build(center)
      {cmd, _caches} = NotificationsEncoder.encode(model, Caches.new())
      <<@op_gui_notifications, _payload_len::16, payload::binary>> = cmd
      {_header, [entry]} = decode_notifications(payload)

      assert entry.created_at == 1_715_000_000
      assert entry.updated_at == 1_715_000_120
    end

    test "returns nil on second call with same model and re-emits changed semantic content" do
      model = %Notifications{items: []}
      changed = %Notifications{items: [item("n1", :info, "Info")]}
      caches = Caches.new()

      {cmd1, caches} = NotificationsEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, caches} = NotificationsEncoder.encode(model, caches)
      assert cmd2 == nil

      {cmd3, _caches} = NotificationsEncoder.encode(changed, caches)
      assert cmd3 != nil
    end
  end

  defp item(id, level, title, opts \\ []) do
    created_at = Keyword.get(opts, :created_at, 1_700_000_000)

    %{
      id: id,
      level: level,
      title: title,
      body: Keyword.get(opts, :body, ""),
      source: Keyword.get(opts, :source, ""),
      actions: Keyword.get(opts, :actions, []),
      dismissable: Keyword.get(opts, :dismissable, true),
      auto_dismiss_ms: Keyword.get(opts, :auto_dismiss_ms),
      created_at: created_at,
      updated_at: Keyword.get(opts, :updated_at, created_at)
    }
  end

  defp decode_notifications(<<version::8, count::16, rest::binary>>) do
    {{version, count}, decode_notification_entries(rest, [])}
  end

  defp decode_notification_entries("", acc), do: Enum.reverse(acc)

  defp decode_notification_entries(payload, acc) do
    {id, payload} = take_string16(payload)

    <<level::8, flags::8, created_at::64, updated_at::64, auto_dismiss_ms::32, payload::binary>> =
      payload

    {title, payload} = take_string16(payload)
    {body, payload} = take_string16(payload)
    {source, <<action_count::8, payload::binary>>} = take_string16(payload)
    {actions, payload} = decode_actions(payload, action_count, [])

    entry = %{
      id: id,
      level: level,
      flags: flags,
      created_at: created_at,
      updated_at: updated_at,
      auto_dismiss_ms: auto_dismiss_ms,
      title: title,
      body: body,
      source: source,
      actions: actions
    }

    decode_notification_entries(payload, [entry | acc])
  end

  defp decode_actions(payload, 0, acc), do: {Enum.reverse(acc), payload}

  defp decode_actions(payload, count, acc) do
    {id, payload} = take_string16(payload)
    {label, payload} = take_string16(payload)
    decode_actions(payload, count - 1, [%{id: id, label: label} | acc])
  end

  defp take_string16(<<len::16, value::binary-size(len), rest::binary>>), do: {value, rest}
end
