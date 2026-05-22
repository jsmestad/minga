defmodule MingaEditor.UINotificationCenterTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Notification
  alias MingaEditor.UI.NotificationCenter

  describe "upsert/2" do
    test "preserves created_at, refreshes updated_at, and keeps a single notification per id" do
      center =
        NotificationCenter.new()
        |> NotificationCenter.upsert(
          Notification.new(
            id: "build:test",
            level: :progress,
            title: "Building Minga",
            created_at: 1_000,
            updated_at: 1_000,
            actions: [%{id: "show_logs", label: "Show logs"}]
          )
        )
        |> NotificationCenter.upsert(
          Notification.new(
            id: "build:test",
            level: :error,
            title: "Build failed",
            body: "exit 1",
            source: "Build",
            created_at: 2_000,
            actions: [%{id: "retry", label: "Retry"}]
          )
        )

      [notification] = NotificationCenter.list(center)
      assert notification.created_at == 1_000
      assert notification.updated_at == 2_000
      assert notification.level == :error
      assert notification.title == "Build failed"
      assert length(NotificationCenter.list(center)) == 1
    end
  end

  describe "dismiss/2" do
    test "removes only the selected notification" do
      center =
        NotificationCenter.new()
        |> NotificationCenter.upsert(
          Notification.new(
            id: "build:test",
            level: :error,
            title: "Build failed",
            created_at: 1_000
          )
        )
        |> NotificationCenter.upsert(
          Notification.new(id: "other", level: :info, title: "Still here", created_at: 2_000)
        )

      dismissed = NotificationCenter.dismiss(center, "build:test")

      assert [%{id: "other"}] = NotificationCenter.list(dismissed)
      assert NotificationCenter.find(dismissed, "build:test") == nil
    end
  end

  describe "dismiss/3" do
    test "ignores stale dismiss refs and only removes the matching notification" do
      stale_ref = make_ref()
      fresh_ref = make_ref()

      center =
        NotificationCenter.new()
        |> NotificationCenter.upsert(
          Notification.new(
            id: "build:test",
            level: :progress,
            title: "Building Minga",
            created_at: 1_000,
            dismissable: false
          )
          |> Notification.with_dismiss_ref(stale_ref)
        )
        |> NotificationCenter.upsert(
          Notification.new(
            id: "build:test",
            level: :error,
            title: "Build failed",
            created_at: 2_000,
            dismissable: false
          )
          |> Notification.with_dismiss_ref(fresh_ref)
        )
        |> NotificationCenter.upsert(
          Notification.new(
            id: "other",
            level: :info,
            title: "Still here",
            created_at: 3_000
          )
        )

      assert NotificationCenter.find(center, "build:test").dismiss_ref == fresh_ref
      assert NotificationCenter.dismiss(center, "build:test", stale_ref) == center

      dismissed = NotificationCenter.dismiss(center, "build:test", fresh_ref)
      assert NotificationCenter.find(dismissed, "build:test") == nil
      assert [%{id: "other"}] = NotificationCenter.list(dismissed)
    end
  end
end
