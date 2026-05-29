defmodule Minga.RenderModel.UI.TabBarTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.TabBar
  alias Minga.RenderModel.UI.TabBar.Tab

  describe "%TabBar{}" do
    test "defaults to hidden with no tabs" do
      tab_bar = %TabBar{}

      refute tab_bar.visible?
      assert tab_bar.active_tab_id == nil
      assert tab_bar.tabs == []
    end

    test "carries semantic tab entries" do
      tab = %Tab{id: 1, workspace_id: 0, label: "README.md", icon: "󰈙", dirty?: true}
      tab_bar = %TabBar{visible?: true, active_tab_id: 1, tabs: [tab]}

      assert tab_bar.visible?
      assert tab_bar.tabs == [tab]
    end
  end
end
