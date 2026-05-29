defmodule Minga.RenderModel.UI.ExtensionPanelTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.ExtensionPanel
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Text
  alias Minga.RenderModel.UI.ExtensionPanel.Panel

  describe "%ExtensionPanel{}" do
    test "defaults to no panels" do
      model = %ExtensionPanel{}

      assert model.panels == []
    end

    test "stores semantic panel entries" do
      panel = %Panel{
        extension: "demo",
        panel_id: "status",
        title: "Status",
        position: :bottom,
        size: {:percent, 30},
        visible?: true,
        content: [%Text{text: "Hello"}]
      }

      model = %ExtensionPanel{panels: [panel]}

      assert [%Panel{extension: "demo", title: "Status", content: [%Text{text: "Hello"}]}] =
               model.panels
    end
  end
end
