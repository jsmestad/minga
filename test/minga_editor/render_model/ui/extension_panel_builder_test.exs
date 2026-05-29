defmodule MingaEditor.RenderModel.UI.ExtensionPanelBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.ExtensionPanel
  alias MingaEditor.RenderModel.UI.ExtensionPanelBuilder

  describe "build/0" do
    test "builds extension panel model with empty panels" do
      model = ExtensionPanelBuilder.build()

      assert %ExtensionPanel{} = model
      assert model.panels == []
    end
  end
end
