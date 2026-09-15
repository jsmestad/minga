defmodule MingaEditor.FileChangeTest do
  @moduledoc """
  Editor-level file-change behavior.

  These tests assert observable buffer outcomes and the conflict prompt contract. Lower-level save-state and mtime conflict rules live in buffer tests.
  """

  use Minga.Test.EditorCase, async: true, rendering: :disabled
  alias Minga.FileWatcher
  alias Minga.FileWatcher.ReadyEvent
  alias Minga.Project.FileTree
  alias MingaEditor.FileWatcherHelpers
  alias MingaEditor.Handlers.EventDispatcher
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState

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
        buffers: %Buffers{active: buf, list: [buf], active_index: 0}
      }
    }

    assert ^state = FileWatcherHelpers.handle_file_change(state, path)
  end

  @tag :tmp_dir
  test "authority restore derives open files and expanded project directories", %{tmp_dir: dir} do
    file = Path.join(dir, "open.txt")
    project = Path.join(dir, "project")
    project_file = Path.join(project, "new.ex")
    File.write!(file, "open")
    File.mkdir_p!(project)

    buffer = start_supervised!({BufferProcess, file_path: file}, id: make_ref())
    file_tree = FileTreeState.open(%FileTreeState{}, FileTree.new(project), nil)

    state = %EditorState{
      workspace: %MingaEditor.Session.State{
        buffers: %Buffers{active: buffer, list: [buffer]},
        file_tree: file_tree
      }
    }

    name = :"helper_watcher_#{:erlang.unique_integer([:positive])}"

    watcher =
      start_supervised!(
        {FileWatcher,
         name: name,
         debounce_ms: 10,
         events_registry: :"missing_helper_events_#{:erlang.unique_integer([:positive])}"},
        id: name
      )

    assert ^state =
             EventDispatcher.dispatch(
               state,
               :file_watcher_ready,
               %ReadyEvent{watcher: watcher},
               :message
             )

    watcher_state = :sys.get_state(watcher)
    assert watcher_state.subscriber == self()
    assert watcher_state.watched_files == MapSet.new([file])
    assert watcher_state.watched_project_dirs == MapSet.new([project])

    send(watcher, {:file_event, nil, {project_file, [:created]}})
    :sys.get_state(watcher)
    assert_receive {:file_changed_on_disk, ^project_file}, 500
  end

  defp notify_file_changed(ctx, path) do
    send(ctx.editor, {:file_changed_on_disk, Path.expand(path)})
    _ = editor_state(ctx)
    :ok
  end
end
