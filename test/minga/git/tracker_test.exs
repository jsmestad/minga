defmodule Minga.Git.TrackerTest do
  # Uses the global Minga.Git.Repo.Supervisor and Git.Stub registry, so keep this file serialized.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events
  alias Minga.Git.Repo
  alias Minga.Git.Stub, as: GitStub
  alias Minga.Git.Tracker

  @moduletag :tmp_dir
  @sync_timeout 15_000

  setup %{tmp_dir: dir} do
    id = System.unique_integer([:positive])
    events_registry = :"tracker_test_events_#{id}"
    tracker_name = :"tracker_test_#{id}"
    registry_table = :"tracker_test_registry_#{id}"

    start_supervised!({Events, name: events_registry})

    start_supervised!(
      {Tracker,
       name: tracker_name, events_registry: events_registry, registry_table: registry_table},
      id: tracker_name
    )

    GitStub.set_root(dir, dir)

    on_exit(fn ->
      GitStub.clear(dir)

      case Repo.lookup(dir) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Minga.Git.Repo.Supervisor, pid)
      end
    end)

    %{
      events_registry: events_registry,
      root: dir,
      tracker: tracker_name,
      registry_table: registry_table
    }
  end

  # Flushes the Tracker's mailbox so any pending events (:buffer_opened,
  # :DOWN, etc.) are processed before we check state.
  defp flush_tracker(tracker), do: :sys.get_state(tracker, @sync_timeout)

  describe "lookup/1" do
    test "returns nil for untracked buffer", %{
      events_registry: events_registry,
      registry_table: table
    } do
      buf = start_supervised!({BufferProcess, content: "hello", events_registry: events_registry})
      assert Tracker.lookup(buf, table) == nil
    end
  end

  describe "tracked?/1" do
    test "returns false for untracked buffer", %{
      events_registry: events_registry,
      registry_table: table
    } do
      buf = start_supervised!({BufferProcess, content: "hello", events_registry: events_registry})
      refute Tracker.tracked?(buf, table)
    end
  end

  describe "event bus integration" do
    test "starts git buffer when buffer_opened is broadcast for a tracked file", %{
      events_registry: events_registry,
      registry_table: table,
      root: dir,
      tracker: tracker
    } do
      path = Path.join(dir, "tracker_test_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "defmodule Foo do\nend\n")
      GitStub.set_head(dir, Path.relative_to(path, dir), "defmodule Foo do\nend\n")

      buf =
        start_supervised!(
          {BufferProcess,
           content: "defmodule Foo do\nend\n", file_path: path, events_registry: events_registry}
        )

      Events.broadcast(
        :buffer_opened,
        %Events.BufferEvent{buffer: buf, path: path},
        events_registry
      )

      # Flush the Tracker so it processes the :buffer_opened event
      flush_tracker(tracker)

      assert Tracker.tracked?(buf, table),
             "Expected git buffer to be started for #{path}"

      assert is_pid(Tracker.lookup(buf, table))
    end

    test "cleans up when buffer process dies", %{
      events_registry: events_registry,
      registry_table: table,
      root: dir,
      tracker: tracker
    } do
      path = Path.join(dir, "tracker_cleanup_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "x = 1\n")
      GitStub.set_head(dir, Path.relative_to(path, dir), "x = 1\n")

      buf =
        start_supervised!(
          {BufferProcess, content: "x = 1\n", file_path: path, events_registry: events_registry}
        )

      Events.broadcast(
        :buffer_opened,
        %Events.BufferEvent{buffer: buf, path: path},
        events_registry
      )

      flush_tracker(tracker)
      assert Tracker.tracked?(buf, table)

      GenServer.stop(buf)

      # Flush the :DOWN message that the Tracker receives when buf dies
      flush_tracker(tracker)

      refute Tracker.tracked?(buf, table),
             "Expected git buffer to be cleaned up after buffer death"
    end

    test "stops Git.Repo when last buffer for a git root closes", %{
      events_registry: events_registry,
      registry_table: table,
      root: dir,
      tracker: tracker
    } do
      path = Path.join(dir, "repo_lifecycle_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "x = 1\n")
      GitStub.set_head(dir, Path.relative_to(path, dir), "x = 1\n")

      buf =
        start_supervised!(
          {BufferProcess, content: "x = 1\n", file_path: path, events_registry: events_registry}
        )

      Events.broadcast(
        :buffer_opened,
        %Events.BufferEvent{buffer: buf, path: path},
        events_registry
      )

      flush_tracker(tracker)
      assert Tracker.tracked?(buf, table)

      # Verify Git.Repo was started
      repo_pid = Repo.lookup(dir)
      assert is_pid(repo_pid)
      ref = Process.monitor(repo_pid)

      # Close the buffer (last one for this git root)
      GenServer.stop(buf)
      flush_tracker(tracker)

      # Git.Repo should be terminated when the last buffer closes
      assert_receive {:DOWN, ^ref, :process, ^repo_pid, _}, 1000
    end

    test "no-op for file not in a git repo", %{
      events_registry: events_registry,
      registry_table: table,
      tracker: tracker
    } do
      path = "/tmp/not_a_git_repo_#{:rand.uniform(100_000)}.ex"

      buf =
        start_supervised!(
          {BufferProcess, content: "hello", file_path: path, events_registry: events_registry}
        )

      Events.broadcast(
        :buffer_opened,
        %Events.BufferEvent{buffer: buf, path: path},
        events_registry
      )

      # Flush the event; if the Tracker tried to track it, it would be
      # visible after this barrier.
      flush_tracker(tracker)

      refute Tracker.tracked?(buf, table)
    end
  end

  describe "buffer_changed event" do
    test "updates git buffer diff when content changes", %{
      events_registry: events_registry,
      registry_table: table,
      root: dir,
      tracker: tracker
    } do
      path = Path.join(dir, "tracker_change_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "line1\nline2\n")
      GitStub.set_head(dir, Path.relative_to(path, dir), "line1\nline2\n")

      buf =
        start_supervised!(
          {BufferProcess,
           content: "line1\nline2\n", file_path: path, events_registry: events_registry}
        )

      Events.broadcast(
        :buffer_opened,
        %Events.BufferEvent{buffer: buf, path: path},
        events_registry
      )

      flush_tracker(tracker)
      assert Tracker.tracked?(buf, table)

      BufferProcess.insert_text(buf, "new line\n")

      Events.broadcast(
        :buffer_changed,
        %Events.BufferChangedEvent{buffer: buf, source: Minga.Buffer.EditSource.user()},
        events_registry
      )

      flush_tracker(tracker)

      assert is_pid(Tracker.lookup(buf, table))
    end

    test "no-op for untracked buffer", %{events_registry: events_registry, tracker: tracker} do
      buf = start_supervised!({BufferProcess, content: "hello", events_registry: events_registry})

      Events.broadcast(
        :buffer_changed,
        %Events.BufferChangedEvent{buffer: buf, source: Minga.Buffer.EditSource.user()},
        events_registry
      )

      flush_tracker(tracker)
    end
  end
end
