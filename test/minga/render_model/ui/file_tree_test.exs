defmodule Minga.RenderModel.UI.FileTreeTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.FileTree
  alias Minga.RenderModel.UI.FileTree.Row

  describe "%FileTree{}" do
    test "defaults to hidden with no rows" do
      file_tree = %FileTree{}

      assert file_tree.status == :hidden
      assert file_tree.rows == []
      assert file_tree.selected_id == ""
    end

    test "carries ready rows and selection" do
      row = %Row{
        id: "/project/lib",
        path: "/project/lib",
        name: "lib",
        icon: "󰉋",
        depth: 0,
        guides: []
      }

      file_tree = %FileTree{
        root_path: "/project",
        tree_width: 30,
        status: :ready,
        selected_id: row.id,
        rows: [row]
      }

      assert file_tree.status == :ready
      assert file_tree.rows == [row]
      assert file_tree.selected_id == row.id
    end
  end
end
