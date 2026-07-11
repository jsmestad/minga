defmodule Minga.Frontend.Adapter.GUI.NotificationsEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Notifications

  @op_gui_notifications Opcodes.gui_notifications()

  @max_u32 4_294_967_295

  @spec encode(Notifications.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Notifications{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_notifications_fp do
      cmd = encode_notifications_binary(model.items)
      {cmd, %{caches | last_notifications_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_notifications_binary([Notifications.notification_item()]) :: binary()
  defp encode_notifications_binary(items) do
    writer =
      :gui_notifications
      |> Writer.new()
      |> Writer.append(<<1::8>>)
      |> Writer.uint16(:notification_count, Enum.count(items))

    payload =
      items
      |> Enum.reduce(writer, &encode_notification/2)
      |> Writer.finish()

    :gui_notifications
    |> Writer.new()
    |> Writer.append(<<@op_gui_notifications>>)
    |> Writer.payload16(:payload, payload)
    |> Writer.finish()
  end

  @spec encode_notification(Notifications.notification_item(), Writer.t()) :: Writer.t()
  defp encode_notification(notification, %Writer{} = writer) do
    flags = if notification.dismissable, do: 0x01, else: 0x00
    auto_dismiss_ms = notification.auto_dismiss_ms || @max_u32

    writer =
      writer
      |> Writer.string16(:notification_id, notification.id)
      |> Writer.uint8(:notification_level, notification_level_byte(notification.level))
      |> Writer.uint8(:notification_flags, flags)
      |> Writer.uint64(:notification_created_at, notification.created_at)
      |> Writer.uint64(:notification_updated_at, notification.updated_at)
      |> Writer.uint32(:notification_auto_dismiss_ms, auto_dismiss_ms)
      |> Writer.string16(:notification_title, notification.title)
      |> Writer.string16(:notification_body, notification.body)
      |> Writer.string16(:notification_source, notification.source)
      |> Writer.uint8(:notification_action_count, Enum.count(notification.actions))

    Enum.reduce(notification.actions, writer, &encode_notification_action/2)
  end

  @spec encode_notification_action(Notifications.action(), Writer.t()) :: Writer.t()
  defp encode_notification_action(action, %Writer{} = writer) do
    writer
    |> Writer.string16(:notification_action_id, action.id)
    |> Writer.string16(:notification_action_label, action.label)
  end

  @spec notification_level_byte(Notifications.level()) :: non_neg_integer()
  defp notification_level_byte(:info), do: 0
  defp notification_level_byte(:warning), do: 1
  defp notification_level_byte(:error), do: 2
  defp notification_level_byte(:success), do: 3
  defp notification_level_byte(:progress), do: 4
end
