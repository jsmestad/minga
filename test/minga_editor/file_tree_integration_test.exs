defmodule MingaEditor.FileTreeIntegrationTest do
  @moduledoc """
  Thin editor-level smoke tests for file tree integration.

  File tree data-structure behavior, rendering, navigation, and editing commands have focused tests elsewhere. This file only keeps the cross-Editor contracts that are easiest to verify through visible behavior.
  """
  use Minga.Test.EditorCase, async: true, rendering: :disabled

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

    _ = editor_state(ctx)

    assert_tree_visible(ctx)
  end

  test "browse project while the tree is hidden reuses the existing buffer (no leak)", %{
    tmp_dir: dir
  } do
    file = Path.join(dir, "alpha.txt")
    File.write!(file, "alpha content")
    ctx = start_editor("alpha content", file_path: file, project_root: dir)

    # Open the tree and capture its backing buffer pid.
    state = send_keys_sync(ctx, "<SPC>op")
    assert_tree_visible(ctx)
    buffer = tree_buffer(state)
    assert is_pid(buffer)

    # Hide the sidebar. The tree stays loaded, so the buffer keeps running.
    send_keys_sync(ctx, "<SPC>op")
    refute_tree_visible(ctx)
    assert Process.alive?(buffer)

    # Browse project while hidden must reveal the existing tree, not rebuild it.
    # Before the fix this called open/1, spawning a second unlisted buffer and
    # orphaning the first (#2626 leak).
    state = send_keys_sync(ctx, "<SPC>p.")
    assert_tree_visible(ctx)
    assert tree_buffer(state) == buffer, "expected the existing tree buffer to be reused"
    assert Process.alive?(buffer)
  end

  test "browse project builds a tree when none is loaded", %{tmp_dir: dir} do
    file = Path.join(dir, "alpha.txt")
    File.write!(file, "alpha content")
    ctx = start_editor("alpha content", file_path: file, project_root: dir)

    refute_tree_visible(ctx)

    state = send_keys_sync(ctx, "<SPC>p.")

    assert_tree_visible(ctx)
    assert is_pid(tree_buffer(state))
  end

  test "browse project while visible focuses without rebuilding the buffer", %{tmp_dir: dir} do
    file = Path.join(dir, "alpha.txt")
    File.write!(file, "alpha content")
    ctx = start_editor("alpha content", file_path: file, project_root: dir)

    state = send_keys_sync(ctx, "<SPC>op")
    assert_tree_visible(ctx)
    buffer = tree_buffer(state)

    state = send_keys_sync(ctx, "<SPC>p.")

    assert_tree_visible(ctx)
    assert tree_buffer(state) == buffer
    assert Process.alive?(buffer)
  end

  defp assert_tree_visible(ctx) do
    assert file_tree_open?(ctx)
  end

  defp refute_tree_visible(ctx) do
    refute file_tree_open?(ctx)
  end

  defp tree_buffer(state) do
    state |> MingaEditor.State.file_tree_state() |> Map.get(:buffer)
  end
end
