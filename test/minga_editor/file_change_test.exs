defmodule MingaEditor.FileChangeTest do
  @moduledoc """
  Editor-level file-change behavior.

  These tests assert observable buffer outcomes and the conflict prompt contract. Lower-level save-state and mtime conflict rules live in buffer tests.
  """

  use Minga.Test.EditorCase, async: true

  @tag :tmp_dir
  test "unmodified buffer silently reloads on file change", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "auto.txt")
    File.write!(path, "original")
    ctx = start_editor("original", file_path: path)

    File.write!(path, "updated externally")
    notify_file_changed(ctx, path)

    assert buffer_content(ctx) == "updated externally"
    assert status_msg(ctx) =~ "reloaded"
  end

  @tag :tmp_dir
  test "modified buffer shows conflict prompt on file change", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "conflict.txt")
    File.write!(path, "original")
    ctx = start_editor("original", file_path: path)
    send_keys_sync(ctx, "ix<Esc>")

    File.write!(path, "external change that is longer")
    notify_file_changed(ctx, path)

    assert status_msg(ctx) =~ "[r]eload"
    assert status_msg(ctx) =~ "[k]eep"
  end

  @tag :tmp_dir
  test "pressing r during conflict prompt reloads the buffer", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "resolve_r.txt")
    File.write!(path, "original")
    ctx = start_editor("original", file_path: path)
    send_keys_sync(ctx, "ix<Esc>")

    File.write!(path, "reloaded content")
    notify_file_changed(ctx, path)
    send_key_sync(ctx, ?r)
    sync_screen(ctx)

    assert buffer_content(ctx) == "reloaded content"
    assert status_msg(ctx) =~ "reloaded"
    refute conflict_open?(ctx)
  end

  @tag :tmp_dir
  test "pressing k during conflict prompt keeps local edits", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "resolve_k.txt")
    File.write!(path, "original")
    ctx = start_editor("original", file_path: path)
    send_keys_sync(ctx, "ilocal<Esc>")

    File.write!(path, "external modification")
    notify_file_changed(ctx, path)
    send_key_sync(ctx, ?k)
    sync_screen(ctx)

    assert String.contains?(buffer_content(ctx), "local")
    refute conflict_open?(ctx)
    assert BufferProcess.save(ctx.buffer) == {:error, :file_changed}
  end

  @tag :tmp_dir
  test "other keys during conflict prompt leave the prompt active", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "ignore.txt")
    File.write!(path, "original")
    ctx = start_editor("original", file_path: path)
    send_keys_sync(ctx, "ix<Esc>")

    File.write!(path, "external modification")
    notify_file_changed(ctx, path)
    send_key_sync(ctx, ?j)
    sync_screen(ctx)

    assert conflict_open?(ctx)
  end

  defp notify_file_changed(ctx, path) do
    send(ctx.editor, {:file_changed_on_disk, Path.expand(path)})
    editor_state(ctx)
    sync_screen(ctx)
    :ok
  end
end
