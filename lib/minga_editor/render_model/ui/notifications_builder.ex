defmodule MingaEditor.RenderModel.UI.NotificationsBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.Notifications
  alias MingaEditor.UI.NotificationCenter

  @spec build(NotificationCenter.t()) :: Notifications.t()
  def build(%NotificationCenter{items: items}) do
    %Notifications{
      items: Enum.map(items, &convert_notification/1)
    }
  end

  @spec convert_notification(MingaEditor.UI.Notification.t()) :: Notifications.notification_item()
  defp convert_notification(n) do
    %{
      id: n.id,
      level: n.level,
      title: n.title,
      body: n.body || "",
      source: n.source || "",
      actions: Enum.map(n.actions, fn a -> %{id: a.id, label: a.label} end),
      dismissable: n.dismissable,
      auto_dismiss_ms: n.auto_dismiss_ms,
      created_at: n.created_at,
      updated_at: n.updated_at || n.created_at
    }
  end
end
