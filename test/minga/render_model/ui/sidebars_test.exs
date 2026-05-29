defmodule Minga.RenderModel.UI.SidebarsTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Sidebars
  alias Minga.RenderModel.UI.Sidebars.Sidebar

  describe "%Sidebars{}" do
    test "defaults to no active sidebar and no entries" do
      sidebars = %Sidebars{}

      assert sidebars.active_id == ""
      assert sidebars.sidebars == []
    end

    test "carries semantic sidebar entries" do
      sidebar = %Sidebar{
        id: "files",
        display_name: "Files",
        semantic_kind: "file_tree",
        order: 10
      }

      sidebars = %Sidebars{active_id: "files", sidebars: [sidebar]}

      assert sidebars.active_id == "files"
      assert sidebars.sidebars == [sidebar]
    end
  end
end
