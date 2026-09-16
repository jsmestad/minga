defmodule MingaEditor.Input.FileTreeNewFileRecoveryTest do
  @moduledoc "Production input-dispatch regressions for recoverable New File failures."

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias Minga.Buffer
  alias Minga.Project.FileTree
  alias MingaEditor.State.FileTree, as: FileTreeState

  @moduletag :tmp_dir
  @backspace 127

  test "invalid paths and controlled permission failures retain input until a successful retry",
       %{
         tmp_dir: dir
       } do
    active_path = Path.join(dir, "active.txt")
    blocker = Path.join(dir, "regular-file.txt")
    File.write!(active_path, "saved bytes")
    File.write!(blocker, "original bytes")

    ctx =
      start_editor("working copy",
        file_path: active_path,
        project_root: dir,
        file_tree_new_file_backend: Minga.Test.FileTreeNewFileBackend
      )

    :ok = Buffer.insert_char(ctx.buffer, "!")
    original_buffer_count = buffer_count(ctx)

    open_file_tree(ctx)
    state = send_key_sync(ctx, ?a)
    assert FileTreeState.editing(state.workspace.file_tree).text == ""

    invalid_name = "regular-file.txt/child.txt"
    state = send_keys_sync(ctx, invalid_name <> "<CR>")

    assert FileTreeState.editing(state.workspace.file_tree).text == invalid_name
    assert notice_message(ctx) =~ "New file failed to create parent directory #{blocker}"
    assert notice_message(ctx) =~ "not a directory"
    assert Process.alive?(ctx.editor)
    assert buffer_count(ctx) == original_buffer_count
    assert File.read!(blocker) == "original bytes"
    assert File.read!(active_path) == "saved bytes"
    assert Buffer.content(ctx.buffer) == "!saved bytes"
    assert Buffer.dirty?(ctx.buffer)

    unique = System.unique_integer([:positive])
    denied_parent = "created-parent-#{unique}"
    denied_name = Path.join(denied_parent, "permission-denied.txt")
    _state = replace_input(ctx, invalid_name, denied_name)
    state = send_key_sync(ctx, 13)

    assert FileTreeState.editing(state.workspace.file_tree).text == denied_name
    assert notice_message(ctx) =~ "New file failed to create #{Path.join(dir, denied_name)}"
    assert notice_message(ctx) =~ "permission denied"
    assert File.dir?(Path.join(dir, denied_parent))
    refute File.exists?(Path.join(dir, denied_name))
    assert buffer_count(ctx) == original_buffer_count
    assert Buffer.dirty?(ctx.buffer)

    state =
      wait_until(
        ctx,
        fn state -> tree_contains?(state, Path.join(dir, denied_parent)) end,
        message: "partial parent creation was not reconciled into the file tree"
      )

    assert FileTreeState.editing(state.workspace.file_tree).text == denied_name

    retry_name = "recovered-#{unique}.txt"
    _state = replace_input(ctx, denied_name, retry_name)
    state = send_key_sync(ctx, 13)
    recovered = Path.join(dir, retry_name)

    assert FileTreeState.editing(state.workspace.file_tree) == nil
    assert File.exists?(recovered)
    assert buffer_count(ctx) == original_buffer_count + 1
    assert Process.alive?(ctx.editor)
    assert Buffer.dirty?(ctx.buffer)

    state =
      wait_until(
        ctx,
        fn state -> tree_contains?(state, recovered) end,
        message: "successfully created file was not refreshed into the file tree"
      )

    assert Buffer.file_path(state.workspace.buffers.active) == recovered

    _state = send_keys_sync(ctx, "qiusable<Esc>")
    active_buffer = editor_state(ctx).workspace.buffers.active
    assert Buffer.content(active_buffer) == "usable"
    assert Buffer.dirty?(active_buffer)
  end

  test "created file is refreshed into the tree when opening its buffer fails", %{tmp_dir: dir} do
    active_path = Path.join(dir, "active.txt")
    File.write!(active_path, "saved bytes")

    ctx =
      start_editor("working copy",
        file_path: active_path,
        project_root: dir,
        file_tree_new_file_backend: Minga.Test.FileTreeNewFileBackend
      )

    original_buffer_count = buffer_count(ctx)

    open_file_tree(ctx)
    _state = send_key_sync(ctx, ?a)
    created_name = "open-fails-#{System.unique_integer([:positive])}.txt"
    state = send_keys_sync(ctx, created_name <> "<CR>")
    created = Path.join(dir, created_name)

    assert FileTreeState.editing(state.workspace.file_tree) == nil
    assert File.exists?(created)
    assert buffer_count(ctx) == original_buffer_count

    assert notice_message(ctx) ==
             "Created #{created}, but opening its buffer failed: I/O error"

    state =
      wait_until(
        ctx,
        fn state -> tree_contains?(state, created) end,
        message: "created file was not refreshed into the file tree"
      )

    assert Enum.any?(
             FileTree.visible_entries(FileTreeState.tree(state.workspace.file_tree)),
             &(&1.path == created)
           )
  end

  defp open_file_tree(ctx) do
    _state = send_keys_sync(ctx, "<Space>op")
    assert file_tree_open?(ctx)
  end

  defp replace_input(ctx, previous, replacement) do
    Enum.each(String.graphemes(previous), fn _grapheme -> send_key_sync(ctx, @backspace) end)
    send_keys_sync(ctx, replacement)
  end

  defp tree_contains?(state, path) do
    state.workspace.file_tree
    |> FileTreeState.tree()
    |> FileTree.visible_entries()
    |> Enum.any?(&(&1.path == path))
  end
end
