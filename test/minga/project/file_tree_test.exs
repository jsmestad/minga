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
    test "ignores directories from the configured file_find_excludes list", %{tmp_dir: tmp_dir} do
      # "vendor" is in :file_find_excludes but was never in the old hardcoded
      # @default_ignore, so this proves the tree reads the shared config.
      assert "vendor" in Minga.Config.get(:file_find_excludes)
      mkdir(Path.join(tmp_dir, "vendor"))
      mkdir(Path.join(tmp_dir, "src"))

      names = tmp_dir |> FileTree.new() |> names()

      assert "src" in names
      refute "vendor" in names
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

    test "filters the cached path list in memory without walking the filesystem" do
      # No tmp_dir / no files on disk: a walk would return []. The matches come
      # entirely from the injected cache, proving in-memory filtering (#2377 AC2).
      tree =
        "/nonexistent_project_root"
        |> FileTree.new()
        |> FileTree.put_cached_files(["lib/target.ex", "lib/other.ex", "README.md"])
        |> FileTree.set_filter("target")

      assert names(tree) == ["target.ex"]
      assert paths(tree) == ["/nonexistent_project_root/lib/target.ex"]
    end

    test "cache filtering presents matches flat at depth 0" do
      tree =
        "/root"
        |> FileTree.new()
        |> FileTree.put_cached_files(["a/b/c/deep.ex"])
        |> FileTree.set_filter("deep")

      assert [%{depth: 0, dir?: false, guides: []}] = FileTree.visible_entries(tree)
    end

    test "an empty cache yields no matches and does not walk the filesystem" do
      tree =
        "/nonexistent_project_root"
        |> FileTree.new()
        |> FileTree.put_cached_files([])
        |> FileTree.set_filter("anything")

      assert FileTree.visible_entries(tree) == []
    end

    @tag :tmp_dir
    test "clearing the cache restores the filesystem walk for filtering", %{tmp_dir: tmp_dir} do
      touch(Path.join(tmp_dir, "walked.ex"))

      tree =
        tmp_dir
        |> FileTree.new()
        |> FileTree.put_cached_files(["cached_only.ex"])
        |> FileTree.put_cached_files(nil)
        |> FileTree.set_filter("walked")

      assert names(tree) == ["walked.ex"]
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

  describe "symlinks" do
    @tag :tmp_dir
    test "a symlinked directory is shown as a directory but never descended", %{tmp_dir: tmp_dir} do
      mkdir(Path.join(tmp_dir, "real"))
      touch(Path.join(tmp_dir, "real/inside.txt"))
      :ok = File.ln_s(Path.join(tmp_dir, "real"), Path.join(tmp_dir, "link"))

      entries =
        tmp_dir
        |> FileTree.new()
        |> expand_path(["link"])
        |> FileTree.visible_entries()

      link_entry = Enum.find(entries, &(&1.name == "link"))
      # Shown as an expandable directory (target is a dir, following the link)...
      assert link_entry.dir? == true
      # ...but the target's children are never walked, even when expanded (cycle safety).
      refute "inside.txt" in Enum.map(entries, & &1.name)

      # The real directory still descends normally.
      real_names =
        tmp_dir |> FileTree.new() |> expand_path(["real"]) |> FileTree.visible_entries()

      assert "inside.txt" in Enum.map(real_names, & &1.name)
    end

    @tag :tmp_dir
    test "a symlink to a file is shown as a file", %{tmp_dir: tmp_dir} do
      touch(Path.join(tmp_dir, "target.txt"))
      :ok = File.ln_s(Path.join(tmp_dir, "target.txt"), Path.join(tmp_dir, "alias.txt"))

      alias_entry =
        tmp_dir
        |> FileTree.new()
        |> FileTree.visible_entries()
        |> Enum.find(&(&1.name == "alias.txt"))

      assert alias_entry.dir? == false
    end
  end

  describe "walk telemetry (#2367)" do
    @tag :tmp_dir
    test "emits a [:minga, :file_tree, :walk] span with the entry count", %{tmp_dir: tmp_dir} do
      touch(Path.join(tmp_dir, "a.txt"))
      touch(Path.join(tmp_dir, "b.txt"))

      ref = make_ref()
      parent = self()
      handler_id = {__MODULE__, ref}

      :telemetry.attach(
        handler_id,
        [:minga, :file_tree, :walk, :stop],
        fn _event, measurements, metadata, _ ->
          send(parent, {ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Force a real walk (fresh tree has entries: nil).
      tmp_dir |> FileTree.new() |> FileTree.visible_entries()

      assert_receive {^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.entry_count == 2
      assert metadata.root == Path.expand(tmp_dir)
    end

    @tag :tmp_dir
    test "does not span when entries are already memoized", %{tmp_dir: tmp_dir} do
      touch(Path.join(tmp_dir, "a.txt"))

      ref = make_ref()
      parent = self()
      handler_id = {__MODULE__, ref}

      # Filter on this test's root so a concurrent (async) walk in another test
      # never trips the refute_receive below; telemetry handlers are global.
      expected_root = Path.expand(tmp_dir)

      :telemetry.attach(
        handler_id,
        [:minga, :file_tree, :walk, :stop],
        fn
          _event, _m, %{root: ^expected_root}, _ -> send(parent, {ref, :walked})
          _event, _m, _meta, _ -> :ok
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # First call walks (and memoizes entries); a second ensure_entries on the
      # already-populated tree must not walk again.
      walked = tmp_dir |> FileTree.new() |> FileTree.ensure_entries()
      assert_receive {^ref, :walked}

      FileTree.ensure_entries(walked)
      refute_receive {^ref, :walked}
    end
  end
end
