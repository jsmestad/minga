defmodule Minga.Project.FileTreeTest do
  use ExUnit.Case, async: true

  alias Minga.Project.FileTree

  defp touch(path), do: File.write!(path, "")
  defp mkdir(path), do: File.mkdir_p!(path)
  defp names(tree), do: tree |> FileTree.visible_entries() |> Enum.map(& &1.name)
  defp paths(tree), do: tree |> FileTree.visible_entries() |> Enum.map(& &1.path)
  defp selected_name(tree), do: tree |> FileTree.selected_entry() |> Map.get(:name)

  defp expand_path(tree, parts) when is_list(parts) do
    FileTree.expand_path(tree, Path.join([tree.root | parts]))
  end

  describe "construction and visible entries" do
    @tag :tmp_dir
    test "starts at the expanded root with default display options", %{tmp_dir: tmp_dir} do
      tree = FileTree.new(tmp_dir)

      assert tree.root == Path.expand(tmp_dir)
      assert MapSet.member?(tree.expanded, tree.root)
      assert tree.cursor == 0
      assert tree.show_hidden == false
      assert tree.width == 30
    end

    @tag :tmp_dir
    test "lists directories before files, sorted alphabetically", %{tmp_dir: tmp_dir} do
      touch(Path.join(tmp_dir, "zebra.txt"))
      touch(Path.join(tmp_dir, "alpha.txt"))
      mkdir(Path.join(tmp_dir, "lib"))
      mkdir(Path.join(tmp_dir, "app"))

      assert tmp_dir |> FileTree.new() |> names() == ["app", "lib", "alpha.txt", "zebra.txt"]
    end

    @tag :tmp_dir
    test "filters hidden files and ignored directories independently", %{tmp_dir: tmp_dir} do
      touch(Path.join(tmp_dir, ".hidden"))
      touch(Path.join(tmp_dir, "visible.txt"))
      mkdir(Path.join(tmp_dir, ".git"))
      mkdir(Path.join(tmp_dir, "node_modules"))
      mkdir(Path.join(tmp_dir, "_build"))
      mkdir(Path.join(tmp_dir, "src"))

      hidden_names = tmp_dir |> FileTree.new() |> names()
      shown_names = tmp_dir |> FileTree.new() |> FileTree.toggle_hidden() |> names()

      assert hidden_names == ["src", "visible.txt"]
      assert ".hidden" in shown_names
      assert "visible.txt" in shown_names
      assert "src" in shown_names
      refute ".git" in shown_names
      refute "node_modules" in shown_names
      refute "_build" in shown_names
    end

    @tag :tmp_dir
    test "only expanded directories expose children and child depth", %{tmp_dir: tmp_dir} do
      mkdir(Path.join(tmp_dir, "lib"))
      touch(Path.join([tmp_dir, "lib", "app.ex"]))
      touch(Path.join(tmp_dir, "mix.exs"))

      collapsed = FileTree.new(tmp_dir)
      expanded = expand_path(collapsed, ["lib"])

      assert names(collapsed) == ["lib", "mix.exs"]

      entries = FileTree.visible_entries(expanded)
      assert Enum.map(entries, & &1.name) == ["lib", "app.ex", "mix.exs"]
      assert Enum.map(entries, & &1.depth) == [0, 1, 0]
    end
  end

  describe "navigation" do
    @tag :tmp_dir
    test "move_up, move_down, and select clamp to visible entries", %{tmp_dir: tmp_dir} do
      touch(Path.join(tmp_dir, "a.txt"))
      touch(Path.join(tmp_dir, "b.txt"))

      tree = FileTree.new(tmp_dir)

      assert selected_name(FileTree.move_up(tree)) == "a.txt"
      assert selected_name(FileTree.move_down(tree)) == "b.txt"
      assert selected_name(tree |> FileTree.move_down() |> FileTree.move_down()) == "b.txt"
      assert selected_name(FileTree.select(tree, -10)) == "a.txt"
      assert selected_name(FileTree.select(tree, 99)) == "b.txt"
    end

    @tag :tmp_dir
    test "selected_entry returns nil when no entries are visible", %{tmp_dir: tmp_dir} do
      assert FileTree.selected_entry(FileTree.new(tmp_dir)) == nil
    end
  end

  describe "expansion and collapse" do
    @tag :tmp_dir
    test "toggle_expand expands and collapses the directory at the cursor", %{tmp_dir: tmp_dir} do
      mkdir(Path.join(tmp_dir, "src"))
      touch(Path.join([tmp_dir, "src", "main.ex"]))

      tree = FileTree.new(tmp_dir)

      assert names(tree) == ["src"]
      assert tree |> FileTree.toggle_expand() |> names() == ["src", "main.ex"]
      assert tree |> FileTree.toggle_expand() |> FileTree.toggle_expand() |> names() == ["src"]
    end

    @tag :tmp_dir
    test "toggle_expand is a no-op on files", %{tmp_dir: tmp_dir} do
      touch(Path.join(tmp_dir, "readme.md"))

      tree = FileTree.new(tmp_dir)
      toggled = FileTree.toggle_expand(tree)

      assert names(toggled) == ["readme.md"]
      assert toggled.cursor == tree.cursor
      assert toggled.root == tree.root
    end

    @tag :tmp_dir
    test "collapse and expand move between a directory and its children", %{tmp_dir: tmp_dir} do
      mkdir(Path.join(tmp_dir, "lib"))
      touch(Path.join([tmp_dir, "lib", "a.ex"]))

      tree = FileTree.new(tmp_dir)

      assert tree |> FileTree.expand() |> names() == ["lib", "a.ex"]
      assert tree |> FileTree.expand() |> FileTree.expand() |> selected_name() == "a.ex"

      assert tree
             |> FileTree.expand()
             |> FileTree.expand()
             |> FileTree.collapse()
             |> selected_name() == "lib"

      assert tree |> FileTree.expand() |> FileTree.collapse() |> names() == ["lib"]
    end

    @tag :tmp_dir
    test "collapse_all keeps only the root expanded and resets selection", %{tmp_dir: tmp_dir} do
      mkdir(Path.join([tmp_dir, "lib", "minga"]))
      touch(Path.join([tmp_dir, "lib", "minga", "editor.ex"]))
      touch(Path.join(tmp_dir, "mix.exs"))

      tree =
        FileTree.new(tmp_dir)
        |> expand_path(["lib"])
        |> expand_path(["lib", "minga"])
        |> FileTree.select(3)

      collapsed = FileTree.collapse_all(tree)

      assert names(collapsed) == ["lib", "mix.exs"]
      assert selected_name(collapsed) == "lib"
      assert MapSet.equal?(collapsed.expanded, MapSet.new([collapsed.root]))
    end
  end

  describe "hidden files" do
    @tag :tmp_dir
    test "toggle_hidden reveals hidden files and clamps selection when they disappear", %{
      tmp_dir: tmp_dir
    } do
      touch(Path.join(tmp_dir, ".a"))
      touch(Path.join(tmp_dir, ".b"))
      touch(Path.join(tmp_dir, "c.txt"))

      shown = tmp_dir |> FileTree.new() |> FileTree.toggle_hidden() |> FileTree.select(2)

      assert names(shown) == [".a", ".b", "c.txt"]
      assert selected_name(shown) == "c.txt"

      hidden = FileTree.toggle_hidden(shown)
      assert names(hidden) == ["c.txt"]
      assert selected_name(hidden) == "c.txt"
    end
  end

  describe "reveal and guide metadata" do
    @tag :tmp_dir
    test "reveal expands ancestors and selects the target file", %{tmp_dir: tmp_dir} do
      mkdir(Path.join([tmp_dir, "lib", "minga"]))
      target = Path.join([tmp_dir, "lib", "minga", "editor.ex"])
      touch(target)

      tree = FileTree.new(tmp_dir) |> FileTree.reveal(target)

      assert names(tree) == ["lib", "minga", "editor.ex"]
      assert selected_name(tree) == "editor.ex"
    end

    @tag :tmp_dir
    test "visible entries expose renderer guide metadata", %{tmp_dir: tmp_dir} do
      mkdir(Path.join([tmp_dir, "lib", "nested"]))
      touch(Path.join([tmp_dir, "lib", "app.ex"]))
      touch(Path.join([tmp_dir, "lib", "nested", "deep.ex"]))
      touch(Path.join(tmp_dir, "mix.exs"))

      entries =
        tmp_dir
        |> FileTree.new()
        |> expand_path(["lib"])
        |> expand_path(["lib", "nested"])
        |> FileTree.visible_entries()

      assert Enum.map(entries, &{&1.name, &1.depth, &1.last_child?, &1.guides}) == [
               {"lib", 0, false, []},
               {"nested", 1, false, [true]},
               {"deep.ex", 2, true, [true, true]},
               {"app.ex", 1, true, [true]},
               {"mix.exs", 0, true, []}
             ]
    end
  end

  describe "cache and refresh" do
    @tag :tmp_dir
    test "ensure_entries caches visible entries until refresh", %{tmp_dir: tmp_dir} do
      touch(Path.join(tmp_dir, "a.txt"))

      tree = FileTree.new(tmp_dir) |> FileTree.ensure_entries()
      touch(Path.join(tmp_dir, "b.txt"))

      assert names(tree) == ["a.txt"]
      assert tree |> FileTree.refresh() |> names() == ["a.txt", "b.txt"]
    end

    @tag :tmp_dir
    test "structural operations recompute visible entries", %{tmp_dir: tmp_dir} do
      mkdir(Path.join(tmp_dir, "src"))
      touch(Path.join([tmp_dir, "src", "main.ex"]))
      touch(Path.join(tmp_dir, ".env"))

      tree = FileTree.new(tmp_dir) |> FileTree.ensure_entries()

      assert names(FileTree.toggle_expand(tree)) == ["src", "main.ex"]
      assert names(FileTree.toggle_hidden(tree)) == ["src", ".env"]
    end

    @tag :tmp_dir
    test "refresh clamps selection after entries are removed", %{tmp_dir: tmp_dir} do
      touch(Path.join(tmp_dir, "a.txt"))
      touch(Path.join(tmp_dir, "b.txt"))

      tree = FileTree.new(tmp_dir) |> FileTree.move_down()
      File.rm!(Path.join(tmp_dir, "b.txt"))

      assert tree |> FileTree.refresh() |> selected_name() == "a.txt"
    end
  end

  describe "filtering and re-rooting" do
    @tag :tmp_dir
    test "set_filter matches descendants without requiring expansion", %{tmp_dir: tmp_dir} do
      mkdir(Path.join(tmp_dir, "lib"))
      touch(Path.join([tmp_dir, "lib", "target.ex"]))
      touch(Path.join(tmp_dir, "other.txt"))

      tree = FileTree.new(tmp_dir) |> FileTree.set_filter("target")

      assert names(tree) == ["target.ex"]
      assert FileTree.selected_entry(tree).depth == 1
    end

    @tag :tmp_dir
    test "set_filter does not match every entry just because the root path matches", %{
      tmp_dir: tmp_dir
    } do
      matching_root = Path.join(tmp_dir, "rootneedle")
      mkdir(matching_root)
      touch(Path.join(matching_root, "alpha.txt"))
      touch(Path.join(matching_root, "beta.txt"))

      assert matching_root
             |> FileTree.new()
             |> FileTree.set_filter("rootneedle")
             |> FileTree.visible_entries() == []
    end

    @tag :tmp_dir
    test "set_filter skips symlinked directories while descending", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "root")
      nested = Path.join(root, "nested")
      link = Path.join(root, "link")
      mkdir(nested)
      touch(Path.join(nested, "target.ex"))

      case File.ln_s(nested, link) do
        :ok -> :ok
        {:error, reason} -> flunk("symlink creation failed: #{inspect(reason)}")
      end

      assert root |> FileTree.new() |> FileTree.set_filter("target") |> paths() == [
               Path.join(nested, "target.ex")
             ]
    end

    @tag :tmp_dir
    test "clear_filter restores unfiltered entries", %{tmp_dir: tmp_dir} do
      touch(Path.join(tmp_dir, "alpha.txt"))
      touch(Path.join(tmp_dir, "beta.txt"))

      tree = tmp_dir |> FileTree.new() |> FileTree.set_filter("alpha") |> FileTree.clear_filter()

      assert names(tree) == ["alpha.txt", "beta.txt"]
    end

    @tag :tmp_dir
    test "reroot preserves display settings and opens the new root", %{tmp_dir: tmp_dir} do
      next_root = Path.join(tmp_dir, "child")
      mkdir(next_root)

      tree =
        tmp_dir
        |> FileTree.new(width: 42)
        |> FileTree.toggle_hidden()
        |> FileTree.set_filter("ex")

      rerooted = FileTree.reroot(tree, next_root)

      assert rerooted.root == Path.expand(next_root)
      assert rerooted.width == 42
      assert rerooted.show_hidden == true
      assert rerooted.filter == "ex"
      assert MapSet.member?(rerooted.expanded, Path.expand(next_root))
    end
  end
end
