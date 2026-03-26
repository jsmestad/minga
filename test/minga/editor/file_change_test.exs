defmodule Minga.Editor.FileChangeTest do
  @moduledoc """
  Integration tests for editor file-change detection and conflict prompts.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer.Server, as: BufferServer

  @tag :tmp_dir
  test "unmodified buffer silently reloads on file change", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "auto.txt")
    File.write!(path, "original")

    ctx = start_editor("original", file_path: path)

    # Simulate external modification (mtime must advance past stored value)
    File.write!(path, "updated externally")

    # Send file change notification directly to the editor
    send(ctx.editor, {:file_changed_on_disk, Path.expand(path)})
    _ = :sys.get_state(ctx.editor)

    # Buffer should have new content
    content = BufferServer.content(ctx.buffer)
    assert content == "updated externally"

    # Status message should confirm reload
    state = :sys.get_state(ctx.editor)
    assert state.shell_state.status_msg =~ "reloaded"
  end

  @tag :tmp_dir
  test "modified buffer shows conflict prompt on file change", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "conflict.txt")
    File.write!(path, "original")

    ctx = start_editor("original", file_path: path)

    # Make local edit to dirty the buffer
    send_keys_sync(ctx, "ix<Esc>")

    # Simulate external modification
    File.write!(path, "external change that is longer")

    # Send file change notification
    send(ctx.editor, {:file_changed_on_disk, Path.expand(path)})
    _ = :sys.get_state(ctx.editor)

    state = :sys.get_state(ctx.editor)
    assert state.workspace.pending_conflict != nil
    assert state.shell_state.status_msg =~ "[r]eload"
    assert state.shell_state.status_msg =~ "[k]eep"
  end

  @tag :tmp_dir
  test "pressing r during conflict prompt reloads the buffer", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "resolve_r.txt")
    File.write!(path, "original")

    ctx = start_editor("original", file_path: path)

    # Dirty the buffer
    send_keys_sync(ctx, "ix<Esc>")

    # External change
    File.write!(path, "reloaded content")

    # Trigger conflict
    send(ctx.editor, {:file_changed_on_disk, Path.expand(path)})
    _ = :sys.get_state(ctx.editor)

    # Press r to reload
    send_key_sync(ctx, ?r)

    content = BufferServer.content(ctx.buffer)
    assert content == "reloaded content"

    state = :sys.get_state(ctx.editor)
    assert state.shell_state.status_msg =~ "reloaded"
    assert state.workspace.pending_conflict == nil
  end

  @tag :tmp_dir
  test "pressing k during conflict prompt keeps local edits", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "resolve_k.txt")
    File.write!(path, "original")

    ctx = start_editor("original", file_path: path)

    # Dirty the buffer
    send_keys_sync(ctx, "ilocal<Esc>")

    # External change
    File.write!(path, "external modification")

    # Trigger conflict
    send(ctx.editor, {:file_changed_on_disk, Path.expand(path)})
    _ = :sys.get_state(ctx.editor)

    # Press k to keep
    send_key_sync(ctx, ?k)

    content = BufferServer.content(ctx.buffer)
    assert String.contains?(content, "local")

    state = :sys.get_state(ctx.editor)
    assert state.workspace.pending_conflict == nil
  end

  @tag :tmp_dir
  test "other keys during conflict prompt are ignored", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "ignore.txt")
    File.write!(path, "original")

    ctx = start_editor("original", file_path: path)
    send_keys_sync(ctx, "ix<Esc>")

    File.write!(path, "external modification")

    send(ctx.editor, {:file_changed_on_disk, Path.expand(path)})
    _ = :sys.get_state(ctx.editor)

    # Press j — should be ignored, prompt should still be active
    send(ctx.editor, {:minga_input, {:key_press, ?j, 0}})
    _ = :sys.get_state(ctx.editor)

    state = :sys.get_state(ctx.editor)
    assert state.workspace.pending_conflict != nil
  end

  @tag :tmp_dir
  test "file change with no matching buffer is a no-op", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "noop.txt")
    File.write!(path, "hello")

    ctx = start_editor("hello", file_path: path)

    # Send notification for a different file
    send(ctx.editor, {:file_changed_on_disk, "/tmp/nonexistent.txt"})
    _ = :sys.get_state(ctx.editor)

    state = :sys.get_state(ctx.editor)
    assert state.workspace.pending_conflict == nil
    assert state.shell_state.status_msg == nil
  end

  @tag :tmp_dir
  test "file deletion doesn't crash", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "deleted.txt")
    File.write!(path, "exists")

    ctx = start_editor("exists", file_path: path)

    File.rm!(path)

    send(ctx.editor, {:file_changed_on_disk, Path.expand(path)})
    _ = :sys.get_state(ctx.editor)

    assert Process.alive?(ctx.editor)
  end
end
