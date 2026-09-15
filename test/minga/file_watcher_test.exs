defmodule Minga.FileWatcherTest do
  @moduledoc """
  FileWatcher behavior through its public API and subscriber messages.
  """

  # Each watcher has a private name and receives synthetic events without subscribing to the OS watcher.
  use ExUnit.Case, async: true

  alias Minga.FileWatcher
  alias Minga.FileWatcher.ReadyEvent

  @moduletag :tmp_dir
  @sync_timeout 15_000

  defp start_watcher(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:debounce_ms, 10)
      |> Keyword.put(:name, :"watcher_#{:erlang.unique_integer([:positive])}")
      |> Keyword.put_new(
        :events_registry,
        :"missing_watcher_events_#{:erlang.unique_integer([:positive])}"
      )

    start_supervised!({FileWatcher, opts}, id: opts[:name])
  end

  test "watch and unwatch calls are safe", %{tmp_dir: dir} do
    watcher = start_watcher()
    file = Path.join(dir, "test.txt")
    project = Path.join(dir, "project")

    assert :ok == FileWatcher.watch_path(watcher, file)
    assert :ok == FileWatcher.unwatch_path(watcher, file)
    assert :ok == FileWatcher.unwatch_path(watcher, file)
    assert :ok == FileWatcher.watch_directory(watcher, project)
    assert :ok == FileWatcher.unwatch_directory(watcher, project)
    assert :ok == FileWatcher.unwatch_directory_tree(watcher, dir)
  end

  test "file events are debounced", %{tmp_dir: dir} do
    watcher = start_watcher(subscriber: self(), debounce_ms: 10)
    path = Path.join(dir, "debounce_test.txt")
    FileWatcher.watch_path(watcher, path)

    for _ <- 1..5 do
      send(watcher, {:file_event, nil, {path, [:modified]}})
    end

    sync_watcher(watcher)

    assert_receive {:file_changed_on_disk, ^path}, 500
    refute_receive {:file_changed_on_disk, ^path}, 100
  end

  test "events under watched project directories are forwarded", %{tmp_dir: dir} do
    watcher = start_watcher(subscriber: self(), debounce_ms: 10)
    root = Path.join(dir, "project-tree-watch")
    path = Path.join(root, "new_file.ex")

    FileWatcher.watch_directory(watcher, root)
    send(watcher, {:file_event, nil, {path, [:created]}})
    sync_watcher(watcher)

    assert_receive {:file_changed_on_disk, ^path}, 500
  end

  test "unwatch_directory_tree stops nested project directory events", %{tmp_dir: dir} do
    watcher = start_watcher(subscriber: self(), debounce_ms: 10)
    root = Path.join(dir, "project-tree-root-unwatch")
    nested = Path.join(root, "lib")
    path = Path.join(nested, "new_file.ex")

    FileWatcher.watch_directory(watcher, root)
    FileWatcher.watch_directory(watcher, nested)
    FileWatcher.unwatch_directory_tree(watcher, root)
    send(watcher, {:file_event, nil, {path, [:created]}})
    sync_watcher(watcher)

    refute_receive {:file_changed_on_disk, ^path}, 50
  end

  test "repeated file registration is idempotent and one release removes its watch", %{
    tmp_dir: dir
  } do
    watcher = start_watcher(subscriber: self(), debounce_ms: 100)
    first = Path.join(dir, "first.txt")
    second = Path.join(dir, "second.txt")

    FileWatcher.watch_path(watcher, first)
    FileWatcher.watch_path(watcher, first)
    FileWatcher.watch_path(watcher, second)
    FileWatcher.unwatch_path(watcher, first)

    state = :sys.get_state(watcher, @sync_timeout)
    assert state.watched_files == MapSet.new([second])
    assert state.watched_dirs == MapSet.new([dir])

    send(watcher, {:file_event, nil, {second, [:modified]}})
    sync_watcher(watcher)
    assert_receive {:file_changed_on_disk, ^second}, 500

    send(watcher, {:file_event, nil, {second, [:modified]}})
    sync_watcher(watcher)
    FileWatcher.unwatch_path(watcher, second)

    state = :sys.get_state(watcher, @sync_timeout)
    assert state.watched_files == MapSet.new()
    assert state.watched_dirs == MapSet.new()
    assert state.watcher == nil
    assert state.pending == %{}
    refute_receive {:file_changed_on_disk, ^second}, 150
  end

  test "authority restore monitors the subscriber before reconstructed events publish", %{
    tmp_dir: dir
  } do
    watcher = start_watcher(debounce_ms: 10)
    file = Path.join(dir, "restored.txt")
    project = Path.join(dir, "project")
    project_file = Path.join(project, "created.txt")

    send(watcher, {:file_event, nil, {file, [:modified]}})
    sync_watcher(watcher)

    FileWatcher.restore_authority(watcher, self(), [file, file], [project, project])
    state = :sys.get_state(watcher, @sync_timeout)

    assert state.subscriber == self()
    assert is_reference(state.subscriber_monitor)
    assert state.watched_files == MapSet.new([file])
    assert state.watched_project_dirs == MapSet.new([project])
    assert watcher in elem(Process.info(self(), :monitored_by), 1)
    refute_receive {:file_changed_on_disk, ^file}, 50

    send(watcher, {:file_event, nil, {file, [:modified]}})
    send(watcher, {:file_event, nil, {project_file, [:created]}})
    sync_watcher(watcher)

    assert_receive {:file_changed_on_disk, ^file}, 500
    assert_receive {:file_changed_on_disk, ^project_file}, 500
  end

  test "replacement watcher announces readiness and accepts reconstructed authority", %{
    tmp_dir: dir
  } do
    registry = start_events_registry()
    Minga.Events.subscribe(:file_watcher_ready, registry)
    name = :"restartable_watcher_#{:erlang.unique_integer([:positive])}"
    file = Path.join(dir, "open.txt")
    project = Path.join(dir, "project")
    project_file = Path.join(project, "new.ex")

    watcher =
      start_supervised!(
        {FileWatcher, name: name, debounce_ms: 10, events_registry: registry},
        id: name
      )

    assert_receive {:minga_event, :file_watcher_ready, %ReadyEvent{watcher: ^watcher}}, 500
    FileWatcher.restore_authority(watcher, self(), [file], [project])

    ref = Process.monitor(watcher)
    Process.exit(watcher, :kill)
    assert_receive {:DOWN, ^ref, :process, ^watcher, :killed}, 500

    assert_receive {:minga_event, :file_watcher_ready, %ReadyEvent{watcher: replacement}}, 1_000
    refute replacement == watcher

    FileWatcher.restore_authority(replacement, self(), [file], [project])
    send(replacement, {:file_event, nil, {file, [:modified]}})
    send(replacement, {:file_event, nil, {project_file, [:created]}})
    sync_watcher(replacement)

    assert_receive {:file_changed_on_disk, ^file}, 500
    assert_receive {:file_changed_on_disk, ^project_file}, 500
  end

  defp start_events_registry do
    registry = :"file_watcher_events_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: registry}, id: registry)
    registry
  end

  defp sync_watcher(watcher) do
    :sys.get_state(watcher, @sync_timeout)
    :ok
  end
end
