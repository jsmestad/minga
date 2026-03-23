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
    :sys.get_state(watcher)

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
    :sys.get_state(watcher)

    # Should receive only one notification after debounce
    assert_receive {:file_changed_on_disk, ^path}, 500
    refute_receive {:file_changed_on_disk, ^path}, 100
  end

  test "events for unwatched files are ignored" do
    watcher = start_watcher(subscriber: self())

    FileWatcher.watch_path(watcher, "/tmp/watched.txt")
    send(watcher, {:file_event, nil, {"/tmp/other.txt", [:modified]}})

    # Flush the watcher's mailbox so the event is processed
    :sys.get_state(watcher)
    refute_receive {:file_changed_on_disk, _}, 50
  end

  test "check_all is safe after subscriber dies" do
    task = Task.async(fn -> :ok end)
    Task.await(task)

    watcher = start_watcher()
    FileWatcher.subscribe(watcher, task.pid)

    # Barrier: ensure :DOWN is processed
    :sys.get_state(watcher)

    # check_all should not crash, and we should not receive anything
    FileWatcher.watch_path(watcher, "/tmp/a.txt")
    FileWatcher.check_all(watcher)
    :sys.get_state(watcher)
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
    :sys.get_state(watcher)

    # New subscriber (self) gets the notification
    assert_receive {:file_changed_on_disk, "/tmp/resub.txt"}, 50

    # Old subscriber does not
    assert Agent.get(agent1, & &1) == []
  end
end
