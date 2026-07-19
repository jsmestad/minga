defmodule MingaEditor.FileChangeTest do
  @moduledoc """
  Editor-level file-change behavior.

  These tests assert observable buffer outcomes and the conflict prompt contract. Lower-level save-state and mtime conflict rules live in buffer tests.
  """

  use Minga.Test.EditorCase, async: true, rendering: :disabled
  alias MingaEditor.FileWatcherHelpers
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers

  @tag :tmp_dir
  test "unmodified buffer silently reloads on file change", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "auto.txt")
    File.write!(path, "original")
    ctx = start_editor("original", file_path: path)

    File.write!(path, "updated externally")
    notify_file_changed(ctx, path)

    assert buffer_content(ctx) == "updated externally"
    assert notice_message(ctx) =~ "reloaded"
  end

  @tag :tmp_dir
  test "modified buffer shows conflict prompt on file change", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "conflict.txt")
    File.write!(path, "original")
    ctx = start_editor("original", file_path: path)
    send_keys_sync(ctx, "ix<Esc>")

    File.write!(path, "external change that is longer")
    notify_file_changed(ctx, path)

    assert notice_message(ctx) =~ "[r]eload"
    assert notice_message(ctx) =~ "[k]eep"
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

    assert buffer_content(ctx) == "reloaded content"
    assert notice_message(ctx) =~ "reloaded"
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

    assert conflict_open?(ctx)
  end

  @tag :tmp_dir
  test "stale buffer that exits after path lookup leaves state unchanged", %{tmp_dir: tmp_dir} do
    path = Path.expand(Path.join(tmp_dir, "stale.txt"))
    File.write!(path, "external")

    buf =
      spawn_link(fn ->
        receive do
          {:"$gen_call", from, :file_path} ->
            GenServer.reply(from, path)
        end
      end)

    state = %EditorState{
      workspace: %MingaEditor.Session.State{
        viewport: MingaEditor.Viewport.new(24, 80),
        buffers: %Buffers{active: buf, list: [buf], active_index: 0}
      }
    }

    assert ^state = FileWatcherHelpers.handle_file_change(state, path)
  end

  defp notify_file_changed(ctx, path) do
    send(ctx.editor, {:file_changed_on_disk, Path.expand(path)})
    _ = editor_state(ctx)
    :ok
  end
end
