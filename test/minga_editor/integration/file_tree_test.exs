defmodule Minga.Integration.FileTreeTest do
  @moduledoc """
  Thin integration smoke tests for file tree rendering and editor focus handoff.

  File tree data structure behavior belongs in lower-level project tests. This file keeps only the behavior that needs a live Editor, key routing, GUI actions, and a rendered screen.
  """
  # Mutates the global built-in FileTree sidebar registry while rendering through live editors.
  use Minga.Test.EditorCase, async: false

  alias Minga.Project.FileTree

  @moduletag :tmp_dir

  defp setup_fixture(%{tmp_dir: dir}) do
    File.mkdir_p!(Path.join(dir, "subdir"))
    File.write!(Path.join(dir, "alpha.txt"), "alpha content")
    File.write!(Path.join(dir, "beta.txt"), "beta content")
    File.write!(Path.join(dir, "subdir/gamma.txt"), "gamma content")

    file = Path.join(dir, "alpha.txt")
    %{file: file, project_root: dir}
  end

  defp start_project_editor(dir) do
    %{file: file, project_root: root} = setup_fixture(%{tmp_dir: dir})
    start_editor("alpha content", file_path: file, project_root: root)
  end

  defp open_file_tree(ctx) do
    send_keys_sync(ctx, "<Space>op")
    assert file_tree_open?(ctx)
    assert file_tree_contains?(ctx, "alpha.txt")
    ctx
  end

  describe "file tree integration" do
    test "SPC o p toggles the rendered tree panel", %{tmp_dir: dir} do
      ctx = start_project_editor(dir)

      ctx = open_file_tree(ctx)

      send_keys_sync(ctx, "<Space>op")

      refute file_tree_open?(ctx)
    end

    test "opening a file from the tree returns to normal editing behavior", %{tmp_dir: dir} do
      ctx =
        dir
        |> start_project_editor()
        |> open_file_tree()

      send_keys_sync(ctx, "G<CR>")

      assert active_content(ctx) == "beta content"

      send_keys_sync(ctx, "i!<Esc>")

      assert active_content(ctx) == "!beta content"
    end

    test "GUI open in split targets the new split while tree is focused", %{tmp_dir: dir} do
      ctx =
        dir
        |> start_project_editor()
        |> open_file_tree()

      send_gui_action(ctx, {:file_tree_open_in_split, 2})

      assert has_split?(ctx)
      assert window_count(ctx) == 2
      assert active_content(ctx) == "beta content"
    end

    test "nested directories expand and collapse in the rendered tree", %{tmp_dir: dir} do
      ctx =
        dir
        |> start_project_editor()
        |> open_file_tree()

      send_keys_sync(ctx, "ggl")

      assert file_tree_contains?(ctx, "gamma.txt"), "expanding subdir should show gamma.txt"

      send_keys_sync(ctx, "h")

      refute file_tree_contains?(ctx, "gamma.txt"), "collapsing subdir should hide gamma.txt"
    end
  end

  describe "filtering reads the project cache (#2377)" do
    test "filtering the active project root matches descendants from the cache", %{tmp_dir: dir} do
      ctx = start_project_editor(dir)

      Minga.Events.subscribe(:project_rebuilt)
      Minga.Project.switch(dir)
      await_project_rebuild(dir)

      ctx = open_file_tree(ctx)

      # `/` enters filtering, then type a needle that only matches a nested file.
      send_keys_sync(ctx, "/gamma")

      assert file_tree_contains?(ctx, "gamma.txt"),
             "filtering should surface the nested match from the cache without expanding"

      refute file_tree_contains?(ctx, "alpha.txt"),
             "non-matching entries should be filtered out"
    end

    test "an open filtered tree refreshes when the project cache rebuilds", %{tmp_dir: dir} do
      %{file: file, project_root: root} = setup_fixture(%{tmp_dir: dir})

      # Share the default event registry with the global Minga.Project so the
      # editor receives its :project_rebuilt broadcasts.
      registry = Minga.Events.default_registry()

      ctx =
        start_editor("alpha content",
          file_path: file,
          project_root: root,
          events_registry: registry
        )

      Minga.Events.subscribe(:project_rebuilt, registry)
      Minga.Project.switch(dir)
      await_project_rebuild(dir)

      ctx = open_file_tree(ctx)
      send_keys_sync(ctx, "/delta")

      refute file_tree_contains?(ctx, "delta.txt")

      # Add a matching file and rebuild the cache; the open filtered tree should
      # pick it up on the :project_rebuilt event.
      File.write!(Path.join(dir, "delta.txt"), "delta content")
      Minga.Project.invalidate()
      await_project_rebuild(dir)
      _ = editor_state(ctx)

      assert file_tree_contains?(ctx, "delta.txt"),
             "the filtered tree should re-filter the rebuilt cache on :project_rebuilt"
    end
  end

  defp await_project_rebuild(root) do
    if Minga.Project.rebuilding?() do
      assert_receive {:minga_event, :project_rebuilt,
                      %Minga.Events.ProjectRebuiltEvent{root: ^root}},
                     5_000
    end

    _ = :sys.get_state(Minga.Project)
  end

  defp file_tree_contains?(ctx, name) do
    ctx
    |> editor_state()
    |> MingaEditor.State.file_tree_state()
    |> Map.get(:tree)
    |> case do
      %FileTree{} = tree ->
        tree
        |> FileTree.visible_entries()
        |> Enum.any?(&(Path.basename(&1.path) == name))

      _ ->
        false
    end
  end
end
