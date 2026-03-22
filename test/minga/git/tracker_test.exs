defmodule Minga.Git.TrackerTest do
  use ExUnit.Case, async: false

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Events
  alias Minga.Git.Repo
  alias Minga.Git.Stub, as: GitStub
  alias Minga.Git.Tracker

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    GitStub.set_root(dir, dir)
    on_exit(fn -> GitStub.clear(dir) end)
    %{root: dir}
  end

  describe "lookup/1" do
    test "returns nil for untracked buffer" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      assert Tracker.lookup(buf) == nil
    end
  end

  describe "tracked?/1" do
    test "returns false for untracked buffer" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      refute Tracker.tracked?(buf)
    end
  end

  describe "event bus integration" do
    test "starts git buffer when buffer_opened is broadcast for a tracked file", %{root: dir} do
      path = Path.join(dir, "tracker_test_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "defmodule Foo do\nend\n")
      GitStub.set_head(dir, Path.relative_to(path, dir), "defmodule Foo do\nend\n")

      {:ok, buf} = BufferServer.start_link(content: "defmodule Foo do\nend\n", file_path: path)
      Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: path})

      assert_until(fn -> Tracker.tracked?(buf) end,
        message: "Expected git buffer to be started for #{path}"
      )

      git_pid = Tracker.lookup(buf)
      assert is_pid(git_pid)
      assert Process.alive?(git_pid)
    end

    test "cleans up when buffer process dies", %{root: dir} do
      path = Path.join(dir, "tracker_cleanup_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "x = 1\n")
      GitStub.set_head(dir, Path.relative_to(path, dir), "x = 1\n")

      {:ok, buf} = BufferServer.start_link(content: "x = 1\n", file_path: path)
      Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: path})
      assert_until(fn -> Tracker.tracked?(buf) end)

      GenServer.stop(buf)

      assert_until(fn -> not Tracker.tracked?(buf) end,
        message: "Expected git buffer to be cleaned up after buffer death"
      )
    end

    test "stops Git.Repo when last buffer for a git root closes", %{root: dir} do
      path = Path.join(dir, "repo_lifecycle_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "x = 1\n")
      GitStub.set_head(dir, Path.relative_to(path, dir), "x = 1\n")

      {:ok, buf} = BufferServer.start_link(content: "x = 1\n", file_path: path)
      Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: path})
      assert_until(fn -> Tracker.tracked?(buf) end)

      # Verify Git.Repo was started
      repo_pid = Repo.lookup(dir)
      assert is_pid(repo_pid)
      ref = Process.monitor(repo_pid)

      # Close the buffer (last one for this git root)
      GenServer.stop(buf)

      # Git.Repo should be terminated when the last buffer closes
      assert_receive {:DOWN, ^ref, :process, ^repo_pid, _}, 1000
    end

    test "no-op for file not in a git repo" do
      path = "/tmp/not_a_git_repo_#{:rand.uniform(100_000)}.ex"
      {:ok, buf} = BufferServer.start_link(content: "hello", file_path: path)
      Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: path})
      refute_until(fn -> Tracker.tracked?(buf) end)
    end
  end

  describe "buffer_changed event" do
    test "updates git buffer diff when content changes", %{root: dir} do
      path = Path.join(dir, "tracker_change_#{:rand.uniform(100_000)}.ex")
      File.write!(path, "line1\nline2\n")
      GitStub.set_head(dir, Path.relative_to(path, dir), "line1\nline2\n")

      {:ok, buf} = BufferServer.start_link(content: "line1\nline2\n", file_path: path)
      Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: path})
      assert_until(fn -> Tracker.tracked?(buf) end)

      BufferServer.insert_text(buf, "new line\n")
      Events.notify_buffer_changed(buf)

      # Sync to flush the event through Tracker's mailbox.
      :sys.get_state(Tracker)

      git_pid = Tracker.lookup(buf)
      assert is_pid(git_pid)
    end

    test "no-op for untracked buffer" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      Events.notify_buffer_changed(buf)
      :sys.get_state(Tracker)
    end
  end

  defp assert_until(condition, opts \\ []) do
    message = Keyword.get(opts, :message, "Condition not met within timeout")
    timeout = Keyword.get(opts, :timeout, 500)
    interval = Keyword.get(opts, :interval, 10)
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_until(condition, interval, deadline, message)
  end

  defp refute_until(condition, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 100)
    interval = Keyword.get(opts, :interval, 10)
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_refute(condition, interval, deadline)
  end

  defp poll_until(condition, interval, deadline, message) do
    if condition.(),
      do: :ok,
      else:
        if(System.monotonic_time(:millisecond) >= deadline,
          do: flunk(message),
          else:
            (
              Process.sleep(interval)
              poll_until(condition, interval, deadline, message)
            )
        )
  end

  defp poll_refute(condition, interval, deadline) do
    if condition.(),
      do: flunk("Condition became true when it should have stayed false"),
      else:
        if(System.monotonic_time(:millisecond) >= deadline,
          do: :ok,
          else:
            (
              Process.sleep(interval)
              poll_refute(condition, interval, deadline)
            )
        )
  end
end
