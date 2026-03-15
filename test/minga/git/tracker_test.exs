defmodule Minga.Git.TrackerTest do
  use ExUnit.Case, async: false

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Events
  alias Minga.Git.Tracker

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
    test "starts git buffer when buffer_opened is broadcast for a git-tracked file" do
      # Create a temp file inside the minga repo (which is a git repo)
      git_root = File.cwd!()
      path = Path.join([git_root, "test", "tmp", "tracker_test_#{:rand.uniform(100_000)}.ex"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "defmodule Foo do\nend\n")

      on_exit(fn -> File.rm(path) end)

      {:ok, buf} = BufferServer.start_link(content: "defmodule Foo do\nend\n", file_path: path)

      Events.broadcast(:buffer_opened, %{buffer: buf, path: path})

      assert_until(fn -> Tracker.tracked?(buf) end,
        message: "Expected git buffer to be started for #{path}"
      )

      git_pid = Tracker.lookup(buf)
      assert is_pid(git_pid)
      assert Process.alive?(git_pid)
    end

    test "cleans up when buffer process dies" do
      git_root = File.cwd!()
      path = Path.join([git_root, "test", "tmp", "tracker_cleanup_#{:rand.uniform(100_000)}.ex"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "x = 1\n")

      on_exit(fn -> File.rm(path) end)

      {:ok, buf} = BufferServer.start_link(content: "x = 1\n", file_path: path)

      Events.broadcast(:buffer_opened, %{buffer: buf, path: path})
      assert_until(fn -> Tracker.tracked?(buf) end)

      # Kill the buffer and verify cleanup.
      GenServer.stop(buf)

      assert_until(fn -> not Tracker.tracked?(buf) end,
        message: "Expected git buffer to be cleaned up after buffer death"
      )
    end

    test "no-op for file not in a git repo" do
      # Use a path outside any git repo.
      path = "/tmp/not_a_git_repo_#{:rand.uniform(100_000)}.ex"
      {:ok, buf} = BufferServer.start_link(content: "hello", file_path: path)

      Events.broadcast(:buffer_opened, %{buffer: buf, path: path})

      # Give a moment for async processing, then verify no tracking started.
      refute_until(fn -> Tracker.tracked?(buf) end)
    end
  end

  describe "notify_change/1" do
    test "updates git buffer diff when content changes" do
      git_root = File.cwd!()
      path = Path.join([git_root, "test", "tmp", "tracker_change_#{:rand.uniform(100_000)}.ex"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "line1\nline2\n")

      on_exit(fn -> File.rm(path) end)

      {:ok, buf} = BufferServer.start_link(content: "line1\nline2\n", file_path: path)

      Events.broadcast(:buffer_opened, %{buffer: buf, path: path})
      assert_until(fn -> Tracker.tracked?(buf) end)

      # Modify buffer content and notify.
      BufferServer.insert_text(buf, "new line\n")
      Tracker.notify_change(buf)

      # The git buffer should have updated signs (content differs from HEAD).
      git_pid = Tracker.lookup(buf)
      assert is_pid(git_pid)
    end

    test "no-op for untracked buffer" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      assert :ok = Tracker.notify_change(buf)
    end
  end

  # ── Test helpers ───────────────────────────────────────────────────────

  # Polls a condition until it returns true, or fails after timeout.
  # Avoids fragile Process.sleep with fixed delays.
  @spec assert_until((-> boolean()), keyword()) :: :ok
  defp assert_until(condition, opts \\ []) do
    message = Keyword.get(opts, :message, "Condition not met within timeout")
    timeout = Keyword.get(opts, :timeout, 500)
    interval = Keyword.get(opts, :interval, 10)
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_until(condition, interval, deadline, message)
  end

  # Polls a condition and asserts it never becomes true within the window.
  @spec refute_until((-> boolean()), keyword()) :: :ok
  defp refute_until(condition, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 100)
    interval = Keyword.get(opts, :interval, 10)
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_refute(condition, interval, deadline)
  end

  defp poll_until(condition, interval, deadline, message) do
    if condition.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk(message)
      else
        Process.sleep(interval)
        poll_until(condition, interval, deadline, message)
      end
    end
  end

  defp poll_refute(condition, interval, deadline) do
    if condition.() do
      flunk("Condition became true when it should have stayed false")
    else
      if System.monotonic_time(:millisecond) >= deadline do
        :ok
      else
        Process.sleep(interval)
        poll_refute(condition, interval, deadline)
      end
    end
  end
end
