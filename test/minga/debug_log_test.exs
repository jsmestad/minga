defmodule Minga.DebugLogTest do
  # Not async: DebugLog subscribes to the global Events registry and these tests assert on flat log files.
  use ExUnit.Case, async: false

  alias Minga.DebugLog
  alias Minga.Events
  alias Minga.Events.LogMessageEvent
  require Logger

  setup do
    ensure_events_registry()

    dir =
      Path.join(System.tmp_dir!(), "minga_debug_log_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir}
  end

  test "start_link creates a file with a session header", %{dir: dir} do
    path = Path.join(dir, "debug.log")
    pid = start_debug_log(path)

    assert File.exists?(path)
    assert File.read!(path) =~ "Minga #{Minga.version()} | Elixir #{System.version()} | OTP"

    stop_debug_log(pid)
  end

  test "starting an existing named writer reuses the same path and rejects a different path", %{
    dir: dir
  } do
    path = Path.join(dir, "debug.log")
    other_path = Path.join(dir, "other.log")
    pid = start_named_debug_log(path)

    assert {:ok, ^pid} = DebugLog.start(path)
    assert {:error, {:debug_log_already_started, ^path, ^other_path}} = DebugLog.start(other_path)

    stop_debug_log(pid)
  end

  test "DebugLog.flush/0 writes buffered entries for the named writer", %{dir: dir} do
    path = Path.join(dir, "debug.log")
    pid = start_named_debug_log(path)
    text = unique_text("debug-log-named-flush")

    Events.broadcast(:log_message, %LogMessageEvent{text: text, level: :info})
    assert :ok = DebugLog.flush()

    assert File.read!(path) =~ text

    stop_debug_log(pid)
  end

  test "DebugLog.flush/0 reports when a configured path has no running writer", %{dir: dir} do
    path = Path.join(dir, "debug-log-missing.log")
    Application.put_env(:minga, :debug_log_path, path)

    assert {:error, {:debug_log_not_running, ^path}} = DebugLog.flush()
  after
    Application.delete_env(:minga, :debug_log_path)
  end

  test "DebugLog.stop/0 reports when a configured path has no running writer", %{dir: dir} do
    path = Path.join(dir, "debug-log-stop-missing.log")
    Application.put_env(:minga, :debug_log_path, path)

    assert {:error, {:debug_log_not_running, ^path}} = DebugLog.stop()
  after
    Application.delete_env(:minga, :debug_log_path)
  end

  test "DebugLog.flush/1 writes buffered entries to disk", %{dir: dir} do
    path = Path.join(dir, "debug.log")
    pid = start_debug_log(path)
    text = unique_text("debug-log-info")

    Events.broadcast(:log_message, %LogMessageEvent{text: text, level: :info})
    assert :ok = DebugLog.flush(pid)

    assert File.read!(path) =~ text

    stop_debug_log(pid)
  end

  test "DebugLog.stop/0 flushes buffered entries and is benign when already stopped", %{dir: dir} do
    path = Path.join(dir, "debug.log")
    _pid = start_named_debug_log(path, flush_after: 60_000)
    text = unique_text("debug-log-stop-flush")

    Events.broadcast(:log_message, %LogMessageEvent{text: text, level: :info})

    assert :ok = DebugLog.stop()
    assert File.read!(path) =~ text
    assert Process.whereis(Minga.DebugLog) == nil
    assert :ok = DebugLog.stop()
  end

  test "warning events are prefixed", %{dir: dir} do
    path = Path.join(dir, "debug.log")
    pid = start_debug_log(path)
    text = unique_text("debug-log-warning")
    second = unique_text("debug-log-warning-second")

    Events.broadcast(:log_message, %LogMessageEvent{text: "#{text}\n#{second}", level: :warning})
    flush(pid)

    content = File.read!(path)
    assert content =~ "[WARNING] #{text}"
    assert content =~ "[WARNING] #{second}"

    stop_debug_log(pid)
  end

  test "error events preserve error severity", %{dir: dir} do
    path = Path.join(dir, "debug.log")
    pid = start_debug_log(path)
    text = unique_text("debug-log-error")

    Events.broadcast(:log_message, %LogMessageEvent{text: text, level: :error})
    flush(pid)

    assert File.read!(path) =~ "[ERROR] #{text}"

    stop_debug_log(pid)
  end

  test "logger error events preserve error severity", %{dir: dir} do
    path = Path.join(dir, "debug.log")
    pid = start_debug_log(path)
    text = unique_text("debug-log-logger-error")

    Logger.error(text)
    Logger.flush()
    flush(pid)

    content = File.read!(path)
    assert content =~ "[ERROR]"
    assert content =~ text

    stop_debug_log(pid)
  end

  test "unwritable path returns an error", %{dir: dir} do
    path = Path.join([dir, "missing", "debug.log"])
    trap_exit? = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:debug_log_unwritable, ^path, :enoent}} =
               DebugLog.start_link(path: path, name: nil)
    after
      Process.flag(:trap_exit, trap_exit?)
    end
  end

  test "existing files are appended, not truncated", %{dir: dir} do
    path = Path.join(dir, "debug.log")
    File.write!(path, "existing debug context\n")

    pid = start_debug_log(path)
    content = File.read!(path)

    assert content =~ "existing debug context"
    assert content =~ "--- Minga debug log session ---"

    stop_debug_log(pid)
  end

  test "rapid messages are buffered until one flush", %{dir: dir} do
    path = Path.join(dir, "debug.log")
    pid = start_debug_log(path, flush_after: 60_000)
    first = unique_text("debug-log-batch-a")
    second = unique_text("debug-log-batch-b")

    Events.broadcast(:log_message, %LogMessageEvent{text: first, level: :info})
    Events.broadcast(:log_message, %LogMessageEvent{text: second, level: :info})

    %{buffer: buffer} = :sys.get_state(pid)
    buffered = IO.iodata_to_binary(buffer)

    assert buffered =~ first
    assert buffered =~ second
    refute File.read!(path) =~ first

    flush(pid)

    content = File.read!(path)
    assert content =~ first
    assert content =~ second

    stop_debug_log(pid)
  end

  test "short flush_after writes buffered entries on the real debounce timer", %{dir: dir} do
    path = Path.join(dir, "debug.log")
    pid = start_debug_log(path, flush_after: 5)
    text = unique_text("debug-log-timer-flush")

    Events.broadcast(:log_message, %LogMessageEvent{text: text, level: :info})

    assert eventually_file_contains?(path, text)

    stop_debug_log(pid)
  end

  test "re-subscribes when the events registry restarts", %{dir: dir} do
    registry = unique_registry_name()
    path = Path.join(dir, "debug-retry.log")
    trap_exit? = Process.flag(:trap_exit, true)

    try do
      {:ok, registry_pid} = Registry.start_link(keys: :duplicate, name: registry)

      {:ok, pid} =
        DebugLog.start_link(path: path, name: nil, registry: registry, registry_retry_after: 5)

      first = unique_text("debug-log-registry-before-restart")
      Events.broadcast(:log_message, %LogMessageEvent{text: first, level: :info}, registry)
      assert eventually_file_contains?(path, first)

      Process.exit(registry_pid, :kill)
      assert_receive {:EXIT, ^registry_pid, :killed}
      :sys.get_state(pid)

      assert eventually_file_contains?(path, "[debug-log] events registry down")
      assert eventually_file_contains?(path, "[debug-log] events registry retry failed")

      {:ok, _replacement_pid} = restart_registry(registry)
      assert eventually_subscribed?(registry, pid)
      assert eventually_file_contains?(path, "[debug-log] events registry re-subscribed")

      second = unique_text("debug-log-registry-after-restart")
      Events.broadcast(:log_message, %LogMessageEvent{text: second, level: :info}, registry)
      assert eventually_file_contains?(path, second)

      stop_debug_log(pid)
    after
      Process.flag(:trap_exit, trap_exit?)
    end
  end

  defp ensure_events_registry do
    if Process.whereis(Minga.EventBus) == nil do
      start_supervised!(Minga.Events.child_spec(name: Minga.EventBus))
    end

    :ok
  end

  defp start_debug_log(path, opts \\ []) do
    {:ok, pid} = DebugLog.start_link(Keyword.merge([path: path, name: nil], opts))
    pid
  end

  defp start_named_debug_log(path, opts \\ []) do
    {:ok, pid} = DebugLog.start(Keyword.merge([path: path], opts))
    pid
  end

  defp stop_debug_log(pid) do
    assert :ok = DebugLog.stop(pid)
  end

  defp flush(pid) do
    assert :ok = DebugLog.flush(pid)
  end

  defp eventually_file_contains?(path, text, retries \\ 50)

  defp eventually_file_contains?(_path, _text, 0), do: false

  defp eventually_file_contains?(path, text, retries) when retries > 0 do
    case File.read(path) do
      {:ok, content} ->
        if String.contains?(content, text) do
          true
        else
          receive do
          after
            10 -> eventually_file_contains?(path, text, retries - 1)
          end
        end

      _ ->
        receive do
        after
          10 -> eventually_file_contains?(path, text, retries - 1)
        end
    end
  end

  defp eventually_subscribed?(registry, pid, retries \\ 50)

  defp eventually_subscribed?(_registry, _pid, 0), do: false

  defp eventually_subscribed?(registry, pid, retries) when retries > 0 do
    if Enum.any?(Events.subscribers(:log_message, registry), &(&1 == pid)) do
      true
    else
      receive do
      after
        10 -> eventually_subscribed?(registry, pid, retries - 1)
      end
    end
  end

  defp restart_registry(registry, retries \\ 50)

  defp restart_registry(registry, 0), do: flunk("registry #{inspect(registry)} did not restart")

  defp restart_registry(registry, retries) when retries > 0 do
    case Registry.start_link(keys: :duplicate, name: registry) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        receive do
        after
          10 -> restart_registry(registry, retries - 1)
        end

      {:error, {:shutdown, {:failed_to_start_child, _child, {:already_started, _pid}}}} ->
        receive do
        after
          10 -> restart_registry(registry, retries - 1)
        end

      {:error, reason} ->
        flunk("registry #{inspect(registry)} failed to restart: #{inspect(reason)}")
    end
  end

  defp unique_registry_name do
    String.to_atom("debug_log_registry_#{System.unique_integer([:positive])}")
  end

  defp unique_text(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
