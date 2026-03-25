defmodule Minga.Project.FileTreeTest do
  use ExUnit.Case, async: true

  alias Minga.Project.FileTree

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
      # Structural state unchanged (expanded set, cursor, root)
      assert tree2.expanded == tree.expanded
      assert tree2.cursor == tree.cursor
      assert tree2.root == tree.root
      # Cache is populated as a side effect of checking the entry
      assert is_list(tree2.entries)
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

  describe "entry guide metadata" do
    @tag :tmp_dir
    test "entries include last_child? and guides fields", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.txt"), "")
      File.write!(Path.join(tmp_dir, "b.txt"), "")

      tree = FileTree.new(tmp_dir)
      entries = FileTree.visible_entries(tree)

      # All depth-0 entries have empty guides list
      assert Enum.all?(entries, fn e -> e.guides == [] end)

      # First file is not last child, second is
      first = Enum.at(entries, 0)
      last = Enum.at(entries, 1)
      assert first.last_child? == false
      assert last.last_child? == true
    end

    @tag :tmp_dir
    test "single entry is marked as last child", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "only.txt"), "")

      tree = FileTree.new(tmp_dir)
      [entry] = FileTree.visible_entries(tree)

      assert entry.last_child? == true
      assert entry.guides == []
    end

    @tag :tmp_dir
    test "nested entries have correct guide flags for ancestor columns", %{tmp_dir: tmp_dir} do
      # Create: lib/ (not last) -> app.ex (last child of lib)
      #         mix.exs (last sibling at depth 0)
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join([tmp_dir, "lib", "app.ex"]), "")
      File.write!(Path.join(tmp_dir, "mix.exs"), "")

      tree = FileTree.new(tmp_dir)
      tree = %{tree | expanded: MapSet.put(tree.expanded, Path.join(tmp_dir, "lib"))}

      entries = FileTree.visible_entries(tree)
      # Expected: lib (depth 0, not last), app.ex (depth 1, last), mix.exs (depth 0, last)
      [lib_entry, app_entry, mix_entry] = entries

      assert lib_entry.last_child? == false
      assert lib_entry.guides == []

      # app.ex is the only child of lib, so it's last_child?
      # Its guides list has one entry: true (because lib is NOT the last sibling,
      # so the depth-0 column should still draw │)
      assert app_entry.last_child? == true
      assert app_entry.guides == [true]

      assert mix_entry.last_child? == true
      assert mix_entry.guides == []
    end

    @tag :tmp_dir
    test "deeply nested entries accumulate guide flags", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join([tmp_dir, "a", "b", "c"]))
      File.write!(Path.join([tmp_dir, "a", "b", "c", "deep.txt"]), "")

      tree = FileTree.new(tmp_dir)

      tree = %{
        tree
        | expanded:
            tree.expanded
            |> MapSet.put(Path.join(tmp_dir, "a"))
            |> MapSet.put(Path.join([tmp_dir, "a", "b"]))
            |> MapSet.put(Path.join([tmp_dir, "a", "b", "c"]))
      }

      entries = FileTree.visible_entries(tree)
      deep = List.last(entries)

      assert deep.name == "deep.txt"
      assert deep.depth == 3
      # All ancestors are last children (only child at each level),
      # so all guide flags should be false (no more siblings = no │)
      assert deep.guides == [false, false, false]
      assert deep.last_child? == true
    end
  end

  describe "collapse_all/1" do
    @tag :tmp_dir
    test "collapses everything except root", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join([tmp_dir, "lib", "minga"]))
      File.write!(Path.join([tmp_dir, "lib", "minga", "editor.ex"]), "")

      tree =
        FileTree.new(tmp_dir)
        |> Map.update!(:expanded, fn exp ->
          exp
          |> MapSet.put(Path.join(tmp_dir, "lib"))
          |> MapSet.put(Path.join([tmp_dir, "lib", "minga"]))
        end)

      assert MapSet.size(tree.expanded) == 3

      tree = FileTree.collapse_all(tree)
      assert MapSet.size(tree.expanded) == 1
      assert MapSet.member?(tree.expanded, tree.root)
    end

    @tag :tmp_dir
    test "clamps cursor to valid range", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join([tmp_dir, "lib", "a.ex"]), "")
      File.write!(Path.join([tmp_dir, "lib", "b.ex"]), "")
      File.write!(Path.join(tmp_dir, "mix.exs"), "")

      tree =
        FileTree.new(tmp_dir)
        |> Map.update!(:expanded, &MapSet.put(&1, Path.join(tmp_dir, "lib")))
        |> Map.put(:cursor, 3)

      # cursor 3 = "mix.exs" with lib expanded. After collapse_all,
      # only root-level entries are visible (lib, mix.exs), cursor clamps to 0.
      tree = FileTree.collapse_all(tree)
      assert tree.cursor == 0
    end

    @tag :tmp_dir
    test "is a no-op on an already-collapsed tree", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.txt"), "")

      tree = FileTree.new(tmp_dir)
      tree2 = FileTree.collapse_all(tree)

      assert tree2.expanded == tree.expanded
      assert tree2.cursor == 0
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

  describe "entry caching" do
    @tag :tmp_dir
    test "visible_entries returns cached results when filesystem changes", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.txt"), "")

      # Use ensure_entries to populate the cache in the struct
      tree = FileTree.new(tmp_dir) |> FileTree.ensure_entries()
      entries1 = FileTree.visible_entries(tree)
      assert length(entries1) == 1

      # Create a new file after the cache is populated
      File.write!(Path.join(tmp_dir, "b.txt"), "")

      # Second call on the SAME struct should return the cached list,
      # not seeing the new file
      entries2 = FileTree.visible_entries(tree)
      assert entries2 == entries1
      assert length(entries2) == 1
    end

    @tag :tmp_dir
    test "ensure_entries populates cache and subsequent visible_entries uses it", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "a.txt"), "")

      tree = FileTree.new(tmp_dir)
      assert tree.entries == nil

      tree = FileTree.ensure_entries(tree)
      assert is_list(tree.entries)
      assert length(tree.entries) == 1

      # Create a new file; cached entries should still show only "a.txt"
      File.write!(Path.join(tmp_dir, "b.txt"), "")
      assert FileTree.visible_entries(tree) == tree.entries
      assert length(FileTree.visible_entries(tree)) == 1
    end

    @tag :tmp_dir
    test "toggle_expand invalidates cache so new entries are computed", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "src"))
      File.write!(Path.join([tmp_dir, "src", "main.ex"]), "")

      tree = FileTree.new(tmp_dir)
      # Populate cache: just "src" (collapsed)
      entries_before = FileTree.visible_entries(tree)
      assert length(entries_before) == 1

      # Expand "src"; this should invalidate the cache
      tree = FileTree.toggle_expand(tree)
      entries_after = FileTree.visible_entries(tree)

      # Now we see both "src" and "main.ex"
      assert length(entries_after) == 2
      names = Enum.map(entries_after, & &1.name)
      assert names == ["src", "main.ex"]
    end

    @tag :tmp_dir
    test "refresh invalidates cache and picks up filesystem changes", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.txt"), "")

      tree = FileTree.new(tmp_dir) |> FileTree.ensure_entries()
      assert length(FileTree.visible_entries(tree)) == 1

      # Create a new file
      File.write!(Path.join(tmp_dir, "b.txt"), "")

      # Stale cache: still 1 entry
      assert length(FileTree.visible_entries(tree)) == 1

      # Refresh should rescan and see both files
      tree = FileTree.refresh(tree)
      assert length(FileTree.visible_entries(tree)) == 2
    end

    @tag :tmp_dir
    test "cursor-only operations preserve the entry cache", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.txt"), "")
      File.write!(Path.join(tmp_dir, "b.txt"), "")

      tree = FileTree.new(tmp_dir) |> FileTree.ensure_entries()
      original_entries = tree.entries

      # move_down preserves cache
      tree = FileTree.move_down(tree)
      assert tree.entries == original_entries
      assert tree.cursor == 1

      # move_up preserves cache
      tree = FileTree.move_up(tree)
      assert tree.entries == original_entries
      assert tree.cursor == 0
    end

    @tag :tmp_dir
    test "toggle_hidden invalidates and recomputes cache", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".hidden"), "")
      File.write!(Path.join(tmp_dir, "visible.txt"), "")

      tree = FileTree.new(tmp_dir) |> FileTree.ensure_entries()
      assert length(tree.entries) == 1

      tree = FileTree.toggle_hidden(tree)
      assert length(tree.entries) == 2
      names = Enum.map(tree.entries, & &1.name)
      assert ".hidden" in names
      assert "visible.txt" in names
    end

    @tag :tmp_dir
    test "collapse_all invalidates cache", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join([tmp_dir, "lib", "a.ex"]), "")

      tree = FileTree.new(tmp_dir) |> FileTree.toggle_expand() |> FileTree.ensure_entries()
      assert length(tree.entries) == 2

      tree = FileTree.collapse_all(tree)
      # Cache invalidated; new entries should show only collapsed "lib"
      assert length(FileTree.visible_entries(tree)) == 1
    end

    @tag :tmp_dir
    test "reveal invalidates cache and sees newly expanded paths", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join([tmp_dir, "lib", "minga"]))
      target = Path.join([tmp_dir, "lib", "minga", "editor.ex"])
      File.write!(target, "")

      tree = FileTree.new(tmp_dir) |> FileTree.ensure_entries()
      # Only "lib" visible (collapsed)
      assert length(tree.entries) == 1

      tree = FileTree.reveal(tree, target)
      # Now lib, minga, and editor.ex are visible
      assert length(tree.entries) == 3
      assert FileTree.selected_entry(tree).name == "editor.ex"
    end

    @tag :tmp_dir
    test "selected_entry uses cached entries for cursor stability", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.txt"), "")
      File.write!(Path.join(tmp_dir, "b.txt"), "")

      # move_down calls ensure_entries internally, so cache is populated
      tree = FileTree.new(tmp_dir) |> FileTree.move_down()
      assert tree.entries != nil
      entry = FileTree.selected_entry(tree)
      assert entry.name == "b.txt"

      # Even if a file is added that would sort before "b.txt",
      # selected_entry on the same struct returns the same entry
      File.write!(Path.join(tmp_dir, "aaa.txt"), "")
      entry2 = FileTree.selected_entry(tree)
      assert entry2.name == "b.txt"
    end
  end
end
