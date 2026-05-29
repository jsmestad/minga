defmodule Minga.RenderModel.UI.StatusBarTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.StatusBar
  alias Minga.RenderModel.UI.StatusBar.Data
  alias Minga.RenderModel.UI.StatusBar.Workspace

  describe "%StatusBar{}" do
    test "requires semantic content kind and data" do
      model = %StatusBar{content_kind: :buffer, data: %Data{mode: :normal}}

      assert model.content_kind == :buffer
      assert model.data.mode == :normal
    end

    test "carries active workspace summary" do
      workspace = %Workspace{id: 1, kind: :agent, label: "Agent", icon: "cpu"}
      model = %StatusBar{content_kind: :agent, data: %Data{mode: :insert}, workspace: workspace}

      assert model.workspace == workspace
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(StatusBar, %{})
      end
    end
  end
end
