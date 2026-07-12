defmodule Minga.FileWatcherTest do
  @moduledoc """
  FileWatcher behavior through its public API and subscriber messages.
  """

  # Each watcher has a private name and receives synthetic events without subscribing to the OS watcher.
  use ExUnit.Case, async: true

  alias Minga.FileWatcher

  @moduletag :tmp_dir
  @sync_timeout 15_000

  defp start_watcher(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:debounce_ms, 10)
      |> Keyword.put(:name, :"watcher_#{:erlang.unique_integer([:positive])}")
      |> Keyword.put_new(:subscribe_events, false)

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

  defp sync_watcher(watcher) do
    :sys.get_state(watcher, @sync_timeout)
    :ok
  end
end
