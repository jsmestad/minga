defmodule Minga.FileTreeTest do
  use ExUnit.Case, async: true

  alias Minga.FileTree

  @tag :tmp_dir
  test "new/1 creates tree with root expanded", %{tmp_dir: tmp_dir} do
    tree = FileTree.new(tmp_dir)
    assert tree.root == Path.expand(tmp_dir)
    assert MapSet.member?(tree.expanded, tree.root)
    assert tree.cursor == 0
    assert tree.show_hidden == false
  end

  describe "visible_entries/1" do
    @tag :tmp_dir
    test "lists files and directories sorted (dirs first, then alpha)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "zebra.txt"), "")
      File.write!(Path.join(tmp_dir, "alpha.txt"), "")
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.mkdir_p!(Path.join(tmp_dir, "app"))

      tree = FileTree.new(tmp_dir)
      entries = FileTree.visible_entries(tree)
      names = Enum.map(entries, & &1.name)

      assert names == ["app", "lib", "alpha.txt", "zebra.txt"]
    end

    @tag :tmp_dir
    test "hides dotfiles by default", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".hidden"), "")
      File.write!(Path.join(tmp_dir, "visible.txt"), "")

      tree = FileTree.new(tmp_dir)
      names = Enum.map(FileTree.visible_entries(tree), & &1.name)

      assert names == ["visible.txt"]
    end

    @tag :tmp_dir
    test "shows dotfiles when show_hidden is true", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".hidden"), "")
      File.write!(Path.join(tmp_dir, "visible.txt"), "")

      tree = FileTree.new(tmp_dir) |> FileTree.toggle_hidden()
      names = Enum.map(FileTree.visible_entries(tree), & &1.name)

      assert ".hidden" in names
      assert "visible.txt" in names
    end

    @tag :tmp_dir
    test "ignores default ignored directories", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      File.mkdir_p!(Path.join(tmp_dir, "node_modules"))
      File.mkdir_p!(Path.join(tmp_dir, "_build"))
      File.mkdir_p!(Path.join(tmp_dir, "src"))

      tree = FileTree.new(tmp_dir) |> FileTree.toggle_hidden()
      names = Enum.map(FileTree.visible_entries(tree), & &1.name)

      assert "src" in names
      refute ".git" in names
      refute "node_modules" in names
      refute "_build" in names
    end

    @tag :tmp_dir
    test "unexpanded directories do not show children", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join([tmp_dir, "lib", "app.ex"]), "")

      tree = FileTree.new(tmp_dir)
      entries = FileTree.visible_entries(tree)

      assert length(entries) == 1
      assert hd(entries).name == "lib"
      assert hd(entries).dir? == true
    end

    @tag :tmp_dir
    test "expanded directories show children with increased depth", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join([tmp_dir, "lib", "app.ex"]), "")
      File.write!(Path.join(tmp_dir, "mix.exs"), "")

      tree = FileTree.new(tmp_dir)
      # Expand lib
      tree = %{tree | expanded: MapSet.put(tree.expanded, Path.join(tmp_dir, "lib"))}

      entries = FileTree.visible_entries(tree)
      names = Enum.map(entries, & &1.name)

      assert names == ["lib", "app.ex", "mix.exs"]
      assert Enum.at(entries, 0).depth == 0
      assert Enum.at(entries, 1).depth == 1
    end
  end

  describe "navigation" do
    @tag :tmp_dir
    test "move_down increments cursor", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.txt"), "")
      File.write!(Path.join(tmp_dir, "b.txt"), "")

      tree = FileTree.new(tmp_dir) |> FileTree.move_down()
      assert tree.cursor == 1
    end

    @tag :tmp_dir
    test "move_down clamps to last entry", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "only.txt"), "")

      tree = FileTree.new(tmp_dir) |> FileTree.move_down() |> FileTree.move_down()
      assert tree.cursor == 0
    end

    @tag :tmp_dir
    test "move_up decrements cursor", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.txt"), "")
      File.write!(Path.join(tmp_dir, "b.txt"), "")

      tree = FileTree.new(tmp_dir) |> FileTree.move_down() |> FileTree.move_up()
      assert tree.cursor == 0
    end

    @tag :tmp_dir
    test "move_up clamps to zero", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.txt"), "")

      tree = FileTree.new(tmp_dir) |> FileTree.move_up()
      assert tree.cursor == 0
    end
  end

  describe "toggle_expand/1" do
    @tag :tmp_dir
    test "expands a collapsed directory at cursor", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "src"))
      File.write!(Path.join([tmp_dir, "src", "main.ex"]), "")

      tree = FileTree.new(tmp_dir)
      # Cursor at 0 = "src" directory (collapsed)
      assert tree.cursor == 0
      refute MapSet.member?(tree.expanded, Path.join(tmp_dir, "src"))

      tree = FileTree.toggle_expand(tree)
      assert MapSet.member?(tree.expanded, Path.join(tmp_dir, "src"))

      entries = FileTree.visible_entries(tree)
      names = Enum.map(entries, & &1.name)
      assert names == ["src", "main.ex"]
    end

    @tag :tmp_dir
    test "collapses an expanded directory at cursor", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "src"))
      File.write!(Path.join([tmp_dir, "src", "main.ex"]), "")

      tree =
        FileTree.new(tmp_dir)
        |> FileTree.toggle_expand()
        |> FileTree.toggle_expand()

      refute MapSet.member?(tree.expanded, Path.join(tmp_dir, "src"))
      entries = FileTree.visible_entries(tree)
      assert length(entries) == 1
    end

    @tag :tmp_dir
    test "is a no-op on files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "readme.md"), "")

      tree = FileTree.new(tmp_dir)
      tree2 = FileTree.toggle_expand(tree)
      assert tree == tree2
    end
  end

  describe "collapse/1 and expand/1" do
    @tag :tmp_dir
    test "collapse on expanded dir collapses it", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join([tmp_dir, "lib", "a.ex"]), "")

      tree = FileTree.new(tmp_dir) |> FileTree.toggle_expand()
      assert MapSet.member?(tree.expanded, Path.join(tmp_dir, "lib"))

      tree = FileTree.collapse(tree)
      refute MapSet.member?(tree.expanded, Path.join(tmp_dir, "lib"))
    end

    @tag :tmp_dir
    test "collapse on file jumps to parent directory", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join([tmp_dir, "lib", "a.ex"]), "")

      tree = FileTree.new(tmp_dir) |> FileTree.toggle_expand() |> FileTree.move_down()
      assert FileTree.selected_entry(tree).name == "a.ex"

      tree = FileTree.collapse(tree)
      assert tree.cursor == 0
      assert FileTree.selected_entry(tree).name == "lib"
    end

    @tag :tmp_dir
    test "expand on collapsed dir expands it", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join([tmp_dir, "lib", "a.ex"]), "")

      tree = FileTree.new(tmp_dir)
      refute MapSet.member?(tree.expanded, Path.join(tmp_dir, "lib"))

      tree = FileTree.expand(tree)
      assert MapSet.member?(tree.expanded, Path.join(tmp_dir, "lib"))
    end

    @tag :tmp_dir
    test "expand on already-expanded dir moves to first child", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join([tmp_dir, "lib", "a.ex"]), "")

      tree = FileTree.new(tmp_dir) |> FileTree.toggle_expand()
      assert tree.cursor == 0

      tree = FileTree.expand(tree)
      assert tree.cursor == 1
      assert FileTree.selected_entry(tree).name == "a.ex"
    end
  end

  describe "toggle_hidden/1" do
    @tag :tmp_dir
    test "reveals hidden files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), "")
      File.write!(Path.join(tmp_dir, "app.ex"), "")

      tree = FileTree.new(tmp_dir)
      assert length(FileTree.visible_entries(tree)) == 1

      tree = FileTree.toggle_hidden(tree)
      assert length(FileTree.visible_entries(tree)) == 2
    end

    @tag :tmp_dir
    test "clamps cursor when toggling hides entries", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".a"), "")
      File.write!(Path.join(tmp_dir, ".b"), "")
      File.write!(Path.join(tmp_dir, "c.txt"), "")

      tree =
        FileTree.new(tmp_dir)
        |> FileTree.toggle_hidden()
        |> Map.put(:cursor, 2)

      # cursor at 2 = ".b" (hidden). Toggling back hides it, clamp to 0
      tree = FileTree.toggle_hidden(tree)
      assert tree.cursor == 0
    end
  end

  describe "selected_entry/1" do
    @tag :tmp_dir
    test "returns entry at cursor", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "hello.txt"), "")

      tree = FileTree.new(tmp_dir)
      entry = FileTree.selected_entry(tree)
      assert entry.name == "hello.txt"
      assert entry.dir? == false
      assert entry.depth == 0
    end

    @tag :tmp_dir
    test "returns nil for empty directory", %{tmp_dir: tmp_dir} do
      tree = FileTree.new(tmp_dir)
      assert FileTree.selected_entry(tree) == nil
    end
  end

  describe "reveal/2" do
    @tag :tmp_dir
    test "expands ancestors and moves cursor to target file", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join([tmp_dir, "lib", "minga"]))
      File.write!(Path.join([tmp_dir, "lib", "minga", "editor.ex"]), "")

      tree = FileTree.new(tmp_dir)
      tree = FileTree.reveal(tree, Path.join([tmp_dir, "lib", "minga", "editor.ex"]))

      assert MapSet.member?(tree.expanded, Path.join(tmp_dir, "lib"))
      assert MapSet.member?(tree.expanded, Path.join([tmp_dir, "lib", "minga"]))

      entry = FileTree.selected_entry(tree)
      assert entry.name == "editor.ex"
    end
  end

  describe "refresh/1" do
    @tag :tmp_dir
    test "clamps cursor after files are deleted", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.txt"), "")
      File.write!(Path.join(tmp_dir, "b.txt"), "")

      tree = FileTree.new(tmp_dir) |> FileTree.move_down()
      assert tree.cursor == 1

      File.rm!(Path.join(tmp_dir, "b.txt"))
      tree = FileTree.refresh(tree)
      assert tree.cursor == 0
    end
  end
end
