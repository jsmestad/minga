defmodule Minga.Frontend.Adapter.GUI.NotificationsEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Protocol.Encoding
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Notifications

  @op_gui_notifications Opcodes.gui_notifications()

  @max_u8 255
  @max_u16 65_535
  @max_u32 4_294_967_295

  @max_notification_title_bytes 512
  @max_notification_body_bytes 8_192
  @max_notification_source_bytes 512
  @max_notification_action_label_bytes 512

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
    {notification_bins, count} = bounded_notification_bins(items)
    payload = IO.iodata_to_binary([<<1::8, count::16>>, notification_bins])
    <<@op_gui_notifications, byte_size(payload)::16, payload::binary>>
  end

  @spec bounded_notification_bins([Notifications.notification_item()]) ::
          {[binary()], non_neg_integer()}
  defp bounded_notification_bins(notifications) do
    notifications
    |> Enum.take(@max_u16)
    |> Enum.reduce_while({[], 0, 3}, fn notification, {bins, count, size} ->
      bin = encode_notification(notification)
      next_size = size + byte_size(bin)

      if next_size <= @max_u16 do
        {:cont, {[bin | bins], count + 1, next_size}}
      else
        {:halt, {bins, count, size}}
      end
    end)
    |> then(fn {bins, count, _size} -> {Enum.reverse(bins), count} end)
  end

  @spec encode_notification(Notifications.notification_item()) :: binary()
  defp encode_notification(notification) do
    flags = if notification.dismissable, do: 0x01, else: 0x00
    auto_dismiss_ms = notification.auto_dismiss_ms || @max_u32
    actions = Enum.take(notification.actions, @max_u8)

    IO.iodata_to_binary([
      encode_notification_string16(notification.id, @max_notification_title_bytes),
      <<notification_level_byte(notification.level)::8, flags::8, notification.created_at::64,
        notification.updated_at::64, auto_dismiss_ms::32>>,
      encode_notification_string16(notification.title, @max_notification_title_bytes),
      encode_notification_string16(notification.body, @max_notification_body_bytes),
      encode_notification_string16(notification.source, @max_notification_source_bytes),
      <<length(actions)::8>>,
      Enum.map(actions, &encode_notification_action/1)
    ])
  end

  @spec encode_notification_action(Notifications.action()) :: binary()
  defp encode_notification_action(action) do
    IO.iodata_to_binary([
      encode_notification_string16(action.id, @max_notification_title_bytes),
      encode_notification_string16(action.label, @max_notification_action_label_bytes)
    ])
  end

  @spec encode_notification_string16(String.t(), non_neg_integer()) :: binary()
  defp encode_notification_string16(text, max_bytes) when is_binary(text) do
    bytes = Encoding.utf8_prefix_bytes(text, min(max_bytes, @max_u16))
    <<byte_size(bytes)::16, bytes::binary>>
  end

  @spec notification_level_byte(Notifications.level()) :: non_neg_integer()
  defp notification_level_byte(:info), do: 0
  defp notification_level_byte(:warning), do: 1
  defp notification_level_byte(:error), do: 2
  defp notification_level_byte(:success), do: 3
  defp notification_level_byte(:progress), do: 4
end
