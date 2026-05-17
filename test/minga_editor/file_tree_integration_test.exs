defmodule MingaEditor.FileTreeIntegrationTest do
  @moduledoc """
  Thin editor-level smoke tests for file tree integration.

  File tree data-structure behavior, rendering, navigation, and editing commands have focused tests elsewhere. This file only keeps the cross-Editor contracts that are easiest to verify through visible behavior.
  """
  use Minga.Test.EditorCase, async: true

  @moduletag :tmp_dir

  test "opening and closing the tree leaves the editor usable", %{tmp_dir: dir} do
    file = Path.join(dir, "alpha.txt")
    File.write!(file, "alpha content")
    ctx = start_editor("alpha content", file_path: file, project_root: dir)

    send_keys_sync(ctx, "<SPC>op")
    assert_tree_visible(ctx)

    send_keys_sync(ctx, "<SPC>op")
    refute_tree_visible(ctx)

    send_keys_sync(ctx, "i!<Esc>")
    assert buffer_content(ctx) == "!alpha content"
  end

  test "buffer_saved refresh keeps an open tree visible", %{tmp_dir: dir} do
    file = Path.join(dir, "save_test.ex")
    File.write!(file, "x = 1\n")
    ctx = start_editor("x = 1\n", file_path: file, project_root: dir)

    send_keys_sync(ctx, "<SPC>op")
    assert_tree_visible(ctx)

    Minga.Events.broadcast(
      :buffer_saved,
      %Minga.Events.BufferEvent{buffer: ctx.buffer, path: file},
      ctx.events_registry
    )

    editor_state(ctx)
    sync_screen(ctx)

    assert_tree_visible(ctx)
  end

  defp assert_tree_visible(ctx) do
    assert Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))
  end

  defp refute_tree_visible(ctx) do
    refute Enum.any?(screen_text(ctx), &String.contains?(&1, "│"))
  end
end
