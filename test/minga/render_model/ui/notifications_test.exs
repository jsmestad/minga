defmodule Minga.RenderModel.UI.NotificationsTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Notifications

  describe "%Notifications{}" do
    test "requires items" do
      n = %Notifications{items: []}

      assert n.items == []
    end

    test "raises when items is missing" do
      assert_raise ArgumentError, fn ->
        struct!(Notifications, %{})
      end
    end

    test "accepts notification items" do
      item = %{
        id: "test-1",
        level: :info,
        title: "Test",
        body: "",
        source: "",
        actions: [],
        dismissable: true,
        auto_dismiss_ms: nil,
        created_at: 1_000_000,
        updated_at: 1_000_000
      }

      n = %Notifications{items: [item]}

      assert length(n.items) == 1
      assert hd(n.items).id == "test-1"
    end
  end
end
