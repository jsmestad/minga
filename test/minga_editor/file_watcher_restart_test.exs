defmodule MingaEditor.FileWatcherRestartTest do
  @moduledoc "Production Editor-to-FileWatcher reconstruction behavior."

  use Minga.Test.EditorCase, async: false, rendering: :disabled

  alias Minga.FileWatcher
  alias Minga.FileWatcher.ReadyEvent
  alias Minga.Project.FileTree
  alias Minga.Test.FileTreeWatcherRestartRaceBackend
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileTree.Freshness
  alias MingaEditor.FileTree.WatcherSync
  alias MingaEditor.FileWatcherHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @tag :tmp_dir
  test "editor reconstructs open-file authority after an independent watcher restart", %{
    tmp_dir: dir
  } do
    file = Path.join(dir, "open.txt")
    File.write!(file, "open")
    registry = start_events_registry()
    Minga.Events.subscribe(:file_watcher_ready, registry)

    watcher =
      start_supervised!(
        {FileWatcher, name: FileWatcher, debounce_ms: 10, events_registry: registry},
        id: FileWatcher
      )

    assert_receive {:minga_event, :file_watcher_ready, %ReadyEvent{watcher: ^watcher}}, 500

    ctx = start_editor("open", file_path: file, events_registry: registry)
    initial_state = :sys.get_state(watcher)
    assert initial_state.subscriber == ctx.editor
    assert initial_state.watched_files == MapSet.new([file])

    ref = Process.monitor(watcher)
    Process.exit(watcher, :kill)
    assert_receive {:DOWN, ^ref, :process, ^watcher, :killed}, 500

    assert_receive {:minga_event, :file_watcher_ready, %ReadyEvent{watcher: replacement}}, 1_000

    replacement_state = await_authority(replacement, ctx.editor, file)
    assert replacement_state.subscriber == ctx.editor
    assert is_reference(replacement_state.subscriber_monitor)
    assert replacement_state.watched_files == MapSet.new([file])
    assert ctx.buffer == editor_state(ctx).workspace.buffers.active
  end

  @tag :tmp_dir
  test "editor routes repeated buffer lifecycle intent idempotently", %{tmp_dir: dir} do
    initial = Path.join(dir, "initial.txt")
    opened = Path.join(dir, "opened.txt")
    File.write!(initial, "initial")
    registry = start_events_registry()

    watcher =
      start_supervised!(
        {FileWatcher, name: FileWatcher, debounce_ms: 10, events_registry: registry},
        id: FileWatcher
      )

    _ctx = start_editor("initial", file_path: initial, events_registry: registry)
    opened_event = %Minga.Events.BufferEvent{buffer: self(), path: opened}
    Minga.Events.broadcast(:buffer_opened, opened_event, registry)
    Minga.Events.broadcast(:buffer_opened, opened_event, registry)

    assert await_watched_files(watcher, MapSet.new([initial, opened])).watched_dirs ==
             MapSet.new([dir])

    Minga.Events.broadcast(
      :buffer_closed,
      %Minga.Events.BufferClosedEvent{buffer: self(), path: opened},
      registry
    )

    assert await_watched_files(watcher, MapSet.new([initial])).watched_dirs == MapSet.new([dir])
  end

  @tag :tmp_dir
  test "restart replay cancels blocked stale watcher sync before restoring newer intent", %{
    tmp_dir: dir
  } do
    old_root = Path.join(dir, "old")
    new_root = Path.join(dir, "new")
    old_event = Path.join(old_root, "stale.ex")
    new_event = Path.join(new_root, "current.ex")
    File.mkdir_p!(old_root)
    File.mkdir_p!(new_root)
    registry = start_events_registry()
    Minga.Events.subscribe(:file_watcher_ready, registry)

    old_watcher =
      start_supervised!(
        {FileWatcher, name: FileWatcher, debounce_ms: 10, events_registry: registry},
        id: FileWatcher
      )

    assert_receive {:minga_event, :file_watcher_ready, %ReadyEvent{watcher: ^old_watcher}}, 500

    scheduler = start_scheduler()
    file_tree = FileTreeState.open(%FileTreeState{}, FileTree.new(old_root), nil)

    state = %EditorState{
      workspace: %SessionState{file_tree: file_tree},
      effect_scheduler: scheduler
    }

    state =
      Freshness.synchronize_watchers(state,
        watcher_backend: FileTreeWatcherRestartRaceBackend,
        watcher_context: {self(), :stale}
      )

    assert_receive {:restart_race_watcher_blocked, :stale, ^old_root, stale_worker}, 500
    stale_ref = Process.monitor(stale_worker)

    watcher_ref = Process.monitor(old_watcher)
    Process.exit(old_watcher, :kill)
    assert_receive {:DOWN, ^watcher_ref, :process, ^old_watcher, :killed}, 500

    assert_receive {:minga_event, :file_watcher_ready, %ReadyEvent{watcher: replacement}}, 1_000

    current_file_tree =
      FileTreeState.begin_root_scan(state.workspace.file_tree, FileTree.new(new_root), :reroot)

    current_state = %{
      state
      | workspace: SessionState.set_file_tree(state.workspace, current_file_tree)
    }

    assert ^current_state = FileWatcherHelpers.restore_authority(current_state, replacement)
    assert_receive {:DOWN, ^stale_ref, :process, ^stale_worker, :killed}, 500

    send(stale_worker, {:release_restart_race_watcher, :stale})
    replacement_state = :sys.get_state(replacement)
    assert replacement_state.watched_project_dirs == MapSet.new([new_root])
    assert replacement_state.watched_dirs == MapSet.new([new_root])
    assert EffectScheduler.stats(scheduler).running == 0
    refute EffectScheduler.active?(scheduler, WatcherSync)

    send(replacement, {:file_event, nil, {old_event, [:created]}})
    send(replacement, {:file_event, nil, {new_event, [:created]}})
    :sys.get_state(replacement)

    assert_receive {:file_changed_on_disk, ^new_event}, 500
    refute_receive {:file_changed_on_disk, ^old_event}, 50
  end

  defp start_events_registry do
    registry = :"editor_file_watcher_events_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: registry}, id: registry)
    registry
  end

  defp start_scheduler do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec({EffectScheduler, task_supervisor: task_supervisor}, id: make_ref())
      )

    :ok = EffectScheduler.attach(scheduler, self())
    scheduler
  end

  defp await_authority(watcher, editor, file, attempts \\ 100)

  defp await_authority(watcher, editor, file, attempts) when attempts > 0 do
    state = :sys.get_state(watcher)

    if state.subscriber == editor and state.watched_files == MapSet.new([file]) do
      state
    else
      receive do
      after
        10 -> await_authority(watcher, editor, file, attempts - 1)
      end
    end
  end

  defp await_authority(_watcher, _editor, _file, 0), do: flunk("watch authority was not restored")

  defp await_watched_files(watcher, expected, attempts \\ 100)

  defp await_watched_files(watcher, expected, attempts) when attempts > 0 do
    state = :sys.get_state(watcher)

    if state.watched_files == expected do
      state
    else
      receive do
      after
        10 -> await_watched_files(watcher, expected, attempts - 1)
      end
    end
  end

  defp await_watched_files(_watcher, _expected, 0), do: flunk("watch intent did not converge")
end
