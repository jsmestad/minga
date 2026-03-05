defmodule Minga.FileWatcherTest do
  @moduledoc """
  Tests for the FileWatcher GenServer — watch/unwatch, debouncing, and
  subscriber notifications.
  """

  use ExUnit.Case, async: true

  alias Minga.FileWatcher

  defp start_watcher(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:debounce_ms, 10)
      |> Keyword.put(:name, :"watcher_#{:erlang.unique_integer([:positive])}")

    {:ok, pid} = FileWatcher.start_link(opts)
    pid
  end

  test "watch_path and unwatch_path succeed" do
    watcher = start_watcher()
    assert :ok == FileWatcher.watch_path(watcher, "/tmp/test.txt")
    assert :ok == FileWatcher.unwatch_path(watcher, "/tmp/test.txt")
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

    assert_receive {:file_changed_on_disk, "/tmp/a.txt"}, 500
    assert_receive {:file_changed_on_disk, "/tmp/b.txt"}, 500
  end

  test "file events are debounced" do
    watcher = start_watcher(subscriber: self(), debounce_ms: 50)
    path = "/tmp/debounce_test.txt"

    FileWatcher.watch_path(watcher, path)

    # Simulate rapid file events
    for _ <- 1..5 do
      send(watcher, {:file_event, nil, {path, [:modified]}})
    end

    # Should receive only one notification after debounce
    Process.sleep(100)
    assert_receive {:file_changed_on_disk, ^path}
    refute_receive {:file_changed_on_disk, ^path}, 50
  end

  test "events for unwatched files are ignored" do
    watcher = start_watcher(subscriber: self())

    FileWatcher.watch_path(watcher, "/tmp/watched.txt")
    send(watcher, {:file_event, nil, {"/tmp/other.txt", [:modified]}})

    Process.sleep(50)
    refute_receive {:file_changed_on_disk, _}
  end

  test "subscriber down clears subscriber" do
    task = Task.async(fn -> :ok end)
    Task.await(task)

    watcher = start_watcher()
    FileWatcher.subscribe(watcher, task.pid)

    # Give the DOWN message time to arrive
    Process.sleep(20)

    %FileWatcher{subscriber: subscriber} = :sys.get_state(watcher)
    assert subscriber == nil
  end
end
