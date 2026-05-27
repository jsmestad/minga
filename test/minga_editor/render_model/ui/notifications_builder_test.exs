defmodule MingaEditor.RenderModel.UI.NotificationsBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.NotificationsBuilder
  alias Minga.RenderModel.UI.Notifications
  alias MingaEditor.UI.Notification
  alias MingaEditor.UI.NotificationCenter

  describe "build/1" do
    test "produces empty items from empty notification center" do
      center = NotificationCenter.new()
      model = NotificationsBuilder.build(center)

      assert %Notifications{} = model
      assert model.items == []
    end

    test "converts notifications preserving all fields" do
      notification =
        Notification.new(%{
          id: "test-1",
          level: :warning,
          title: "Warning!",
          body: "Something happened",
          source: "test-source",
          created_at: 1_000_000
        })

      center = NotificationCenter.upsert(NotificationCenter.new(), notification)
      model = NotificationsBuilder.build(center)

      assert length(model.items) == 1
      item = hd(model.items)
      assert item.id == "test-1"
      assert item.level == :warning
      assert item.title == "Warning!"
      assert item.body == "Something happened"
      assert item.source == "test-source"
      assert item.dismissable == true
      assert item.created_at == 1_000_000
    end

    test "converts nil body and source to empty strings" do
      notification =
        Notification.new(%{
          id: "test-2",
          level: :info,
          title: "Info",
          created_at: 1_000_000
        })

      center = NotificationCenter.upsert(NotificationCenter.new(), notification)
      model = NotificationsBuilder.build(center)

      item = hd(model.items)
      assert item.body == ""
      assert item.source == ""
    end

    test "converts actions" do
      notification =
        Notification.new(%{
          id: "test-3",
          level: :error,
          title: "Error",
          created_at: 1_000_000,
          actions: [%{id: "retry", label: "Retry"}]
        })

      center = NotificationCenter.upsert(NotificationCenter.new(), notification)
      model = NotificationsBuilder.build(center)

      item = hd(model.items)
      assert length(item.actions) == 1
      assert hd(item.actions).id == "retry"
      assert hd(item.actions).label == "Retry"
    end
  end
end
