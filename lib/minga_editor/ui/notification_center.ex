defmodule MingaEditor.UI.NotificationCenter do
  @moduledoc """
  Ordered collection of active editor notifications.

  The editor owns this model. Frontends receive full snapshots and report user actions back by notification id and action id.
  """

  alias MingaEditor.UI.Notification
  alias MingaEditor.UI.Notification.Action

  defstruct items: []

  @type t :: %__MODULE__{items: [Notification.t()]}

  @doc "Creates an empty notification center."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns notifications in display order, oldest first."
  @spec list(t()) :: [Notification.t()]
  def list(%__MODULE__{items: items}), do: items

  @doc "Adds or replaces a notification by id while preserving its original position."
  @spec upsert(t(), Notification.t()) :: t()
  def upsert(%__MODULE__{items: items} = center, %Notification{id: id} = notification) do
    case Enum.split_while(items, &(&1.id != id)) do
      {prefix, [existing | suffix]} ->
        updated =
          notification
          |> Notification.with_created_at(existing.created_at)
          |> Notification.with_updated_at(notification.updated_at || notification.created_at)

        %{center | items: prefix ++ [updated] ++ suffix}

      {_all, []} ->
        %{center | items: items ++ [notification]}
    end
  end

  @doc "Updates an existing notification or inserts a new one when the id is unknown."
  @spec update(t(), Notification.t()) :: t()
  def update(%__MODULE__{} = center, %Notification{} = notification),
    do: upsert(center, notification)

  @doc "Dismisses one notification without affecting unrelated notifications."
  @spec dismiss(t(), String.t()) :: t()
  def dismiss(%__MODULE__{items: items} = center, id) when is_binary(id) do
    %{center | items: Enum.reject(items, &(&1.id == id))}
  end

  @doc "Dismisses only when the notification's stored timer ref matches."
  @spec dismiss(t(), String.t(), reference()) :: t()
  def dismiss(%__MODULE__{} = center, id, dismiss_ref) when is_binary(id) do
    case find(center, id) do
      %Notification{dismiss_ref: ^dismiss_ref} -> dismiss(center, id)
      _ -> center
    end
  end

  @doc "Finds a notification by id."
  @spec find(t(), String.t()) :: Notification.t() | nil
  def find(%__MODULE__{items: items}, id) when is_binary(id) do
    Enum.find(items, &(&1.id == id))
  end

  @doc "Finds an inline action on a notification."
  @spec action(t(), String.t(), String.t()) :: Action.t() | nil
  def action(%__MODULE__{} = center, notification_id, action_id) do
    case find(center, notification_id) do
      %Notification{actions: actions} -> Enum.find(actions, &(&1.id == action_id))
      nil -> nil
    end
  end
end
