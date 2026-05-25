defmodule Minga.Integration.FileTreeTest do
  @moduledoc """
  Thin integration smoke tests for file tree rendering and editor focus handoff.

  File tree data structure behavior belongs in lower-level project tests. This file keeps only the behavior that needs a live Editor, key routing, GUI actions, and a rendered screen.
  """
  # Mutates the global built-in FileTree sidebar registry while rendering through live editors.
  use Minga.Test.EditorCase, async: false

  alias Minga.Test.HeadlessPort

  @moduletag :tmp_dir
  @sync_timeout 15_000

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
    assert screen_contains?(ctx, "alpha.txt")
    assert Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))
    ctx
  end

  defp send_gui_action(%{editor: editor, port: port}, action) do
    _ = GenServer.call(editor, :api_mode, @sync_timeout)
    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:gui_action, action}})
    {:ok, snapshot} = HeadlessPort.collect_frame(ref, @sync_timeout)
    Process.put({:last_frame_snapshot, port}, snapshot)
    :ok
  end

  describe "file tree integration" do
    test "SPC o p toggles the rendered tree panel", %{tmp_dir: dir} do
      ctx = start_project_editor(dir)

      ctx = open_file_tree(ctx)

      send_keys_sync(ctx, "<Space>op")

      refute String.contains?(screen_row(ctx, 1), "│"),
             "separator should be gone after closing tree"
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

      assert screen_contains?(ctx, "gamma.txt"), "expanding subdir should show gamma.txt"

      send_keys_sync(ctx, "h")

      refute screen_contains?(ctx, "gamma.txt"), "collapsing subdir should hide gamma.txt"
    end
  end
end
