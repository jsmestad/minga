defmodule Minga.FileWatcherTest do
  @moduledoc """
  Tests for the FileWatcher GenServer — watch/unwatch, debouncing, and
  subscriber notifications.
  """

  # Uses file-system watcher resources that can block under concurrent full-suite load, so keep this file serialized.
  use ExUnit.Case, async: false

  alias Minga.FileWatcher

  @sync_timeout 15_000

  defp start_watcher(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:debounce_ms, 10)
      |> Keyword.put(:name, :"watcher_#{:erlang.unique_integer([:positive])}")
      # Disable global :buffer_opened subscription so concurrent tests
      # don't flood this watcher's mailbox and cause timing flakes.
      |> Keyword.put_new(:subscribe_events, false)

    start_supervised!({FileWatcher, opts}, id: opts[:name])
  end

  test "watch_path and unwatch_path succeed" do
    watcher = start_watcher()
    assert :ok == FileWatcher.watch_path(watcher, "/tmp/test.txt")
    assert :ok == FileWatcher.unwatch_path(watcher, "/tmp/test.txt")
  end

  test "watch_directory and unwatch_directory succeed" do
    watcher = start_watcher()
    assert :ok == FileWatcher.watch_directory(watcher, "/tmp/project")
    assert :ok == FileWatcher.unwatch_directory(watcher, "/tmp/project")
  end

  test "subscribe registers the caller" do
    watcher = start_watcher()
    assert :ok == FileWatcher.subscribe(watcher, self())
  end

  test "unwatching a path not watched is a no-op" do
    watcher = start_watcher()
    assert :ok == FileWatcher.unwatch_path(watcher, "/nonexistent")
  end

  test "check_all sends notifications for all watched files" do
    watcher = start_watcher(subscriber: self())

    FileWatcher.watch_path(watcher, "/tmp/a.txt")
    FileWatcher.watch_path(watcher, "/tmp/b.txt")
    FileWatcher.check_all(watcher)

    # check_all is a cast; barrier ensures it's processed before asserting
    :sys.get_state(watcher, @sync_timeout)

    assert_receive {:file_changed_on_disk, "/tmp/a.txt"}, 50
    assert_receive {:file_changed_on_disk, "/tmp/b.txt"}, 50
  end

  test "file events are debounced" do
    watcher = start_watcher(subscriber: self(), debounce_ms: 10)
    path = "/tmp/debounce_test.txt"

    FileWatcher.watch_path(watcher, path)

    # Simulate rapid file events
    for _ <- 1..5 do
      send(watcher, {:file_event, nil, {path, [:modified]}})
    end

    # Ensure the watcher has processed all 5 events and rescheduled
    # the debounce timer before we start waiting for the result.
    :sys.get_state(watcher, @sync_timeout)

    # Should receive only one notification after debounce
    assert_receive {:file_changed_on_disk, ^path}, 500
    refute_receive {:file_changed_on_disk, ^path}, 100
  end

  test "events for unwatched files are ignored" do
    watcher = start_watcher(subscriber: self())

    FileWatcher.watch_path(watcher, "/tmp/watched.txt")
    send(watcher, {:file_event, nil, {"/tmp/other.txt", [:modified]}})

    # Flush the watcher's mailbox so the event is processed
    :sys.get_state(watcher, @sync_timeout)
    refute_receive {:file_changed_on_disk, _}, 50
  end

  test "events under watched project directories are forwarded" do
    watcher = start_watcher(subscriber: self(), debounce_ms: 10)
    root = "/tmp/project-tree-watch"
    path = Path.join(root, "new_file.ex")

    FileWatcher.watch_directory(watcher, root)
    send(watcher, {:file_event, nil, {path, [:created]}})
    :sys.get_state(watcher, @sync_timeout)

    assert_receive {:file_changed_on_disk, ^path}, 500
  end

  test "unwatch_directory stops forwarding project directory events" do
    watcher = start_watcher(subscriber: self(), debounce_ms: 10)
    root = "/tmp/project-tree-unwatch"
    path = Path.join(root, "new_file.ex")

    FileWatcher.watch_directory(watcher, root)
    FileWatcher.unwatch_directory(watcher, root)
    send(watcher, {:file_event, nil, {path, [:created]}})
    :sys.get_state(watcher, @sync_timeout)

    refute_receive {:file_changed_on_disk, ^path}, 50
  end

  test "watch_directory is idempotent for project directory registrations" do
    watcher = start_watcher(subscriber: self())
    root = "/tmp/project-tree-idempotent"

    FileWatcher.watch_directory(watcher, root)
    first_state = :sys.get_state(watcher, @sync_timeout)
    FileWatcher.watch_directory(watcher, root)
    second_state = :sys.get_state(watcher, @sync_timeout)

    assert first_state.watched_dirs == second_state.watched_dirs
    assert first_state.watcher == second_state.watcher
  end

  test "check_all notifies watched project directories" do
    watcher = start_watcher(subscriber: self())
    root = "/tmp/project-tree-check-all"

    FileWatcher.watch_directory(watcher, root)
    FileWatcher.check_all(watcher)
    :sys.get_state(watcher, @sync_timeout)

    assert_receive {:file_changed_on_disk, ^root}, 50
  end

  test "unwatch_directory_tree removes nested project directory registrations" do
    watcher = start_watcher(subscriber: self(), debounce_ms: 10)
    root = "/tmp/project-tree-root-unwatch"
    nested = Path.join(root, "lib")
    path = Path.join(nested, "new_file.ex")

    FileWatcher.watch_directory(watcher, root)
    FileWatcher.watch_directory(watcher, nested)
    FileWatcher.unwatch_directory_tree(watcher, root)
    send(watcher, {:file_event, nil, {path, [:created]}})
    state = :sys.get_state(watcher, @sync_timeout)

    assert state.watched_project_dirs == MapSet.new()
    refute_receive {:file_changed_on_disk, ^path}, 50
  end

  test "check_all is safe after subscriber dies" do
    task = Task.async(fn -> :ok end)
    Task.await(task)

    watcher = start_watcher()
    FileWatcher.subscribe(watcher, task.pid)

    # Barrier: ensure :DOWN is processed
    :sys.get_state(watcher, @sync_timeout)

    # check_all should not crash, and we should not receive anything
    FileWatcher.watch_path(watcher, "/tmp/a.txt")
    FileWatcher.check_all(watcher)
    :sys.get_state(watcher, @sync_timeout)
    refute_receive {:file_changed_on_disk, _}, 50
  end

  test "re-subscribing replaces the old subscriber" do
    watcher = start_watcher()

    # First subscriber
    {:ok, agent1} = Agent.start_link(fn -> [] end)
    FileWatcher.subscribe(watcher, agent1)

    # Replace with self
    FileWatcher.subscribe(watcher, self())

    FileWatcher.watch_path(watcher, "/tmp/resub.txt")
    FileWatcher.check_all(watcher)
    :sys.get_state(watcher, @sync_timeout)

    # New subscriber (self) gets the notification
    assert_receive {:file_changed_on_disk, "/tmp/resub.txt"}, 50

    # Old subscriber does not
    assert Agent.get(agent1, & &1) == []
  end
end
