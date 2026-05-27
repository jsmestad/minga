defmodule Minga.RenderModel.UI.FileTreeTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.FileTree

  describe "%FileTree{}" do
    test "requires encoded and fingerprint" do
      ft = %FileTree{
        encoded: <<0x93, 0, 0, 0, 5, "data">>,
        fingerprint: {:no_tree, "/tmp"}
      }

      assert ft.encoded == <<0x93, 0, 0, 0, 5, "data">>
      assert ft.fingerprint == {:no_tree, "/tmp"}
      assert ft.selection_encoded == nil
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(FileTree, %{})
      end
    end

    test "accepts ready fingerprint with selection_encoded" do
      ft = %FileTree{
        encoded: <<0x93, "full_tree_data">>,
        selection_encoded: <<0x94, "selection_data">>,
        fingerprint: {:ready, 111, 222}
      }

      assert ft.selection_encoded == <<0x94, "selection_data">>
      assert {:ready, 111, 222} = ft.fingerprint
    end

    test "accepts file_tree_state fingerprint" do
      ft = %FileTree{
        encoded: <<0x93, "state">>,
        fingerprint: {:file_tree_state, "/project", 250, :loading}
      }

      assert {:file_tree_state, "/project", 250, :loading} = ft.fingerprint
    end
  end
end
