defmodule Minga.Buffer.AutoSaveTest do
  @moduledoc """
  Observable auto-save behavior for file-backed buffers.

  These tests intentionally avoid asserting on debounce tokens or timer refs. The public contract is whether the buffer writes, stays dirty, and reports user-visible events.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events
  alias Minga.Events.LogMessageEvent

  @moduletag :tmp_dir
  @delay_ms 25
  @event_timeout 5_000
  @no_event_timeout 150

  test "dirty file-backed buffer auto-saves after the debounce", %{tmp_dir: dir} do
    path = Path.join(dir, "auto-save.txt")
    File.write!(path, "hello")
    pid = start_buffer(file_path: path)
    assert {:ok, @delay_ms} = BufferProcess.set_option(pid, :auto_save_delay_ms, @delay_ms)

    Events.subscribe(:log_message)
    Events.subscribe(:buffer_saved)

    try do
      assert :ok = BufferProcess.insert_text(pid, "!")

      assert_buffer_saved(path)
      assert_log_contains("Auto-saved: #{Path.relative_to_cwd(path)}")
      assert File.read!(path) == "!hello"
      refute BufferProcess.dirty?(pid)
    after
      Events.unsubscribe(:buffer_saved)
      Events.unsubscribe(:log_message)
    end
  end

  test "auto-save writes the latest content after multiple edits", %{tmp_dir: dir} do
    path = Path.join(dir, "latest-content.txt")
    File.write!(path, "base")
    pid = start_buffer(file_path: path)
    assert {:ok, @delay_ms} = BufferProcess.set_option(pid, :auto_save_delay_ms, @delay_ms)

    Events.subscribe(:buffer_saved)

    try do
      assert :ok = BufferProcess.insert_text(pid, "A")
      assert :ok = BufferProcess.insert_text(pid, "B")

      assert_buffer_saved(path)
      assert File.read!(path) == "ABbase"
      refute BufferProcess.dirty?(pid)
    after
      Events.unsubscribe(:buffer_saved)
    end
  end

  test "non-file buffers do not auto-save", %{tmp_dir: dir} do
    Events.subscribe(:buffer_saved)

    try do
      for buffer_type <- [:nofile, :nowrite, :prompt, :terminal] do
        path = Path.join(dir, "#{buffer_type}.txt")
        File.write!(path, "original")
        pid = start_buffer(file_path: path, buffer_type: buffer_type, read_only: false)
        assert {:ok, @delay_ms} = BufferProcess.set_option(pid, :auto_save_delay_ms, @delay_ms)

        assert :ok = BufferProcess.insert_text(pid, "!")
        refute_buffer_saved(path)
        assert File.read!(path) == "original"
        assert BufferProcess.dirty?(pid)
      end
    after
      Events.unsubscribe(:buffer_saved)
    end
  end

  test "auto-save delay of 0 disables auto-save", %{tmp_dir: dir} do
    path = Path.join(dir, "disabled.txt")
    File.write!(path, "hello")
    pid = start_buffer(file_path: path)
    assert {:ok, 0} = BufferProcess.set_option(pid, :auto_save_delay_ms, 0)

    Events.subscribe(:buffer_saved)

    try do
      assert :ok = BufferProcess.insert_text(pid, "!")

      refute_buffer_saved(path)
      assert File.read!(path) == "hello"
      assert BufferProcess.dirty?(pid)
    after
      Events.unsubscribe(:buffer_saved)
    end
  end

  test "undo to a dirty version is auto-saved", %{tmp_dir: dir} do
    path = Path.join(dir, "undo-dirty.txt")
    File.write!(path, "hello")
    pid = start_buffer(file_path: path)
    assert {:ok, @delay_ms} = BufferProcess.set_option(pid, :auto_save_delay_ms, @delay_ms)
    assert :ok = BufferProcess.insert_text(pid, "!")
    assert :ok = BufferProcess.save(pid)
    refute BufferProcess.dirty?(pid)

    Events.subscribe(:buffer_saved)

    try do
      assert :ok = BufferProcess.undo(pid)

      assert_buffer_saved(path)
      assert File.read!(path) == "hello"
      refute BufferProcess.dirty?(pid)
    after
      Events.unsubscribe(:buffer_saved)
    end
  end

  test "auto-save skips when a missing file appears on disk before the debounce fires", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "externally-created.txt")
    pid = start_buffer(file_path: path)
    assert {:ok, @delay_ms} = BufferProcess.set_option(pid, :auto_save_delay_ms, @delay_ms)

    Events.subscribe(:log_message)

    try do
      assert :ok = BufferProcess.insert_text(pid, "buffer")
      File.write!(path, "external")

      assert_log_contains(
        "Auto-save skipped for #{Path.relative_to_cwd(path)}: file changed on disk"
      )

      assert File.read!(path) == "external"
      assert BufferProcess.dirty?(pid)
    after
      Events.unsubscribe(:log_message)
    end
  end

  test "auto-save skips when an existing file changes before the debounce fires", %{tmp_dir: dir} do
    path = Path.join(dir, "externally-modified.txt")
    File.write!(path, "hello")
    pid = start_buffer(file_path: path)
    assert {:ok, @delay_ms} = BufferProcess.set_option(pid, :auto_save_delay_ms, @delay_ms)

    Events.subscribe(:log_message)

    try do
      assert :ok = BufferProcess.insert_text(pid, "!")
      File.write!(path, "HELLO")

      assert_log_contains(
        "Auto-save skipped for #{Path.relative_to_cwd(path)}: file changed on disk"
      )

      assert File.read!(path) == "HELLO"
      assert BufferProcess.dirty?(pid)
    after
      Events.unsubscribe(:log_message)
    end
  end

  test "auto-save skips when an existing file is deleted before the debounce fires", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "externally-deleted.txt")
    File.write!(path, "hello")
    pid = start_buffer(file_path: path)
    assert {:ok, @delay_ms} = BufferProcess.set_option(pid, :auto_save_delay_ms, @delay_ms)

    Events.subscribe(:log_message)

    try do
      assert :ok = BufferProcess.insert_text(pid, "!")
      File.rm!(path)

      assert_log_contains(
        "Auto-save skipped for #{Path.relative_to_cwd(path)}: file was deleted on disk"
      )

      refute File.exists?(path)
      assert BufferProcess.dirty?(pid)
    after
      Events.unsubscribe(:log_message)
    end
  end

  defp start_buffer(opts) do
    start_supervised!({BufferProcess, opts}, id: {:buffer, make_ref()})
  end

  defp assert_log_contains(text) do
    receive do
      {:minga_event, :log_message, %LogMessageEvent{text: message}} ->
        if String.contains?(message, text) do
          :ok
        else
          assert_log_contains(text)
        end
    after
      @event_timeout -> flunk("expected log message containing #{inspect(text)}")
    end
  end

  defp assert_buffer_saved(path) do
    receive do
      {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: buffer, path: ^path}}
      when is_pid(buffer) ->
        :ok
    after
      @event_timeout -> flunk("expected buffer_saved event for #{inspect(path)}")
    end
  end

  defp refute_buffer_saved(path) do
    refute_receive {:minga_event, :buffer_saved, %Events.BufferEvent{path: ^path}},
                   @no_event_timeout
  end
end
