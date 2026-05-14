defmodule MingaEditor.FileTree.RowsTest do
  @moduledoc "Tests semantic row construction for file-tree renderers."

  use ExUnit.Case, async: true

  alias Minga.Project.FileTree
  alias MingaEditor.FileTree.Rows

  @moduletag :tmp_dir

  describe "from_tree/2" do
    test "marks selected and focused rows", %{tmp_dir: tmp_dir} do
      tree =
        tmp_dir
        |> flat_tree()
        |> FileTree.select(1)

      rows = Rows.from_tree(tree, focused: true)

      assert Enum.at(rows, 0).selected? == false
      selected = Enum.at(rows, 1)
      assert selected.selected? == true
      assert selected.focused? == true
    end

    test "marks active, dirty, and git state independently", %{tmp_dir: tmp_dir} do
      tree = flat_tree(tmp_dir)
      file_path = Path.join(tmp_dir, "alpha.ex")

      [row | _] =
        Rows.from_tree(tree,
          active_path: file_path,
          dirty_paths: MapSet.new([file_path]),
          git_status: %{file_path => :modified}
        )

      assert row.path == file_path
      assert row.active? == true
      assert row.dirty? == true
      assert row.git_status == :modified
    end

    test "does not mark directories dirty", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      tree = FileTree.new(tmp_dir)
      dir_path = Path.join(tmp_dir, "lib")

      [row] = Rows.from_tree(tree, dirty_paths: MapSet.new([dir_path]))

      assert row.directory? == true
      assert row.dirty? == false
    end

    test "attaches inline editing metadata only to the edited index", %{tmp_dir: tmp_dir} do
      tree = flat_tree(tmp_dir)
      editing = %{index: 1, text: "renamed.ex", type: :rename, original_name: "beta.ex"}

      rows = Rows.from_tree(tree, editing: editing)

      assert Enum.at(rows, 0).editing == nil
      assert Enum.at(rows, 1).editing == editing
    end

    test "preserves nested depth, guides, and last-child metadata", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join([tmp_dir, "lib", "minga"]))
      File.write!(Path.join([tmp_dir, "lib", "minga", "editor.ex"]), "")

      tree =
        FileTree.new(tmp_dir)
        |> FileTree.expand_path(Path.join(tmp_dir, "lib"))
        |> FileTree.expand_path(Path.join([tmp_dir, "lib", "minga"]))

      row =
        tree
        |> Rows.from_tree()
        |> Enum.find(&(&1.name == "editor.ex"))

      assert row.depth == 2
      assert row.guides == [false, false]
      assert row.last_child? == true
      assert row.relative_path == "lib/minga/editor.ex"
    end

    test "returns no rows for an empty visible tree", %{tmp_dir: tmp_dir} do
      assert Rows.from_tree(FileTree.new(tmp_dir)) == []
    end
  end

  defp flat_tree(tmp_dir) do
    File.write!(Path.join(tmp_dir, "alpha.ex"), "")
    File.write!(Path.join(tmp_dir, "beta.ex"), "")
    FileTree.new(tmp_dir)
  end
end
