defmodule Minga.Buffer.AutoSaveTest do
  @moduledoc """
  Tests for debounced auto-save on file-backed buffers.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server
  alias Minga.Events
  alias Minga.Events.LogMessageEvent

  @moduletag :tmp_dir
  @delay_ms 40

  test "dirty file-backed buffer auto-saves after the configured delay", %{tmp_dir: dir} do
    path = Path.join(dir, "auto-save.txt")
    File.write!(path, "hello")
    {:ok, pid} = Server.start_link(file_path: path)
    assert {:ok, 1} = Server.set_option(pid, :auto_save_delay_ms, 1)

    Events.subscribe(:log_message)
    Events.subscribe(:buffer_saved)

    try do
      :ok = Server.insert_text(pid, "!")

      assert_buffer_saved(path)
      assert_log_contains("Auto-saved: #{Path.relative_to_cwd(path)}")
      assert File.read!(path) == "!hello"
      refute Server.dirty?(pid)
    after
      Events.unsubscribe(:buffer_saved)
      Events.unsubscribe(:log_message)
    end
  end

  test "rapid edits reset the debounce timer", %{tmp_dir: dir} do
    path = Path.join(dir, "debounce.txt")
    File.write!(path, "base")
    {:ok, pid} = Server.start_link(file_path: path)
    assert {:ok, @delay_ms} = Server.set_option(pid, :auto_save_delay_ms, @delay_ms)

    :ok = Server.insert_text(pid, "A")
    first_token = :sys.get_state(pid).auto_save_token
    assert is_reference(first_token)

    :ok = Server.insert_text(pid, "B")
    second_token = :sys.get_state(pid).auto_save_token
    assert is_reference(second_token)
    refute first_token == second_token

    send(pid, {:auto_save, first_token})
    :sys.get_state(pid)
    assert File.read!(path) == "base"

    send(pid, {:auto_save, second_token})
    :sys.get_state(pid)
    assert File.read!(path) == "ABbase"
    refute Server.dirty?(pid)
  end

  test "explicit save cancels a pending auto-save timer", %{tmp_dir: dir} do
    path = Path.join(dir, "explicit-save.txt")
    File.write!(path, "hello")
    {:ok, pid} = Server.start_link(file_path: path)
    assert {:ok, @delay_ms} = Server.set_option(pid, :auto_save_delay_ms, @delay_ms)

    :ok = Server.insert_text(pid, "!")
    state = :sys.get_state(pid)
    assert is_reference(state.auto_save_timer)
    assert is_reference(state.auto_save_token)

    assert :ok = Server.save(pid)
    refute :sys.get_state(pid).auto_save_timer

    send(pid, {:auto_save, state.auto_save_token})
    :sys.get_state(pid)
    assert File.read!(path) == "!hello"
  end

  test "non-file buffers are excluded from auto-save", %{tmp_dir: dir} do
    for buffer_type <- [:nofile, :nowrite, :prompt, :terminal] do
      path = Path.join(dir, "#{buffer_type}.txt")
      File.write!(path, "original")
      {:ok, pid} = Server.start_link(file_path: path, buffer_type: buffer_type, read_only: false)
      assert {:ok, @delay_ms} = Server.set_option(pid, :auto_save_delay_ms, @delay_ms)

      :ok = Server.insert_text(pid, "!")
      refute :sys.get_state(pid).auto_save_timer

      send(pid, {:auto_save, make_ref()})
      :sys.get_state(pid)
      assert File.read!(path) == "original"
      assert Server.dirty?(pid)
      GenServer.stop(pid)
    end
  end

  test "auto-save delay of 0 disables auto-save", %{tmp_dir: dir} do
    path = Path.join(dir, "disabled.txt")
    File.write!(path, "hello")
    {:ok, pid} = Server.start_link(file_path: path)
    assert {:ok, 0} = Server.set_option(pid, :auto_save_delay_ms, 0)

    :ok = Server.insert_text(pid, "!")
    refute :sys.get_state(pid).auto_save_timer

    send(pid, {:auto_save, make_ref()})
    :sys.get_state(pid)
    assert File.read!(path) == "hello"
    assert Server.dirty?(pid)
  end

  test "disabling auto-save cancels an already pending timer", %{tmp_dir: dir} do
    path = Path.join(dir, "disable-pending.txt")
    File.write!(path, "hello")
    {:ok, pid} = Server.start_link(file_path: path)
    assert {:ok, @delay_ms} = Server.set_option(pid, :auto_save_delay_ms, @delay_ms)

    :ok = Server.insert_text(pid, "!")
    token = :sys.get_state(pid).auto_save_token
    assert is_reference(token)

    assert {:ok, 0} = Server.set_option(pid, :auto_save_delay_ms, 0)
    refute :sys.get_state(pid).auto_save_timer

    send(pid, {:auto_save, token})
    :sys.get_state(pid)
    assert File.read!(path) == "hello"
    assert Server.dirty?(pid)
  end

  test "undo to a dirty version schedules auto-save", %{tmp_dir: dir} do
    path = Path.join(dir, "undo-dirty.txt")
    File.write!(path, "hello")
    {:ok, pid} = Server.start_link(file_path: path)
    assert {:ok, @delay_ms} = Server.set_option(pid, :auto_save_delay_ms, @delay_ms)

    :ok = Server.insert_text(pid, "!")
    token = :sys.get_state(pid).auto_save_token
    send(pid, {:auto_save, token})
    :sys.get_state(pid)
    refute Server.dirty?(pid)

    :ok = Server.undo(pid)
    state = :sys.get_state(pid)
    assert Server.dirty?(pid)
    assert is_reference(state.auto_save_timer)
    assert is_reference(state.auto_save_token)

    send(pid, {:auto_save, state.auto_save_token})
    :sys.get_state(pid)
    assert File.read!(path) == "hello"
    refute Server.dirty?(pid)
  end

  test "auto-save skips when a missing file appears on disk before the timer fires", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "externally-created.txt")
    {:ok, pid} = Server.start_link(file_path: path)
    assert {:ok, @delay_ms} = Server.set_option(pid, :auto_save_delay_ms, @delay_ms)

    Events.subscribe(:log_message)

    try do
      :ok = Server.insert_text(pid, "buffer")
      token = :sys.get_state(pid).auto_save_token
      File.write!(path, "external")

      send(pid, {:auto_save, token})
      :sys.get_state(pid)

      assert_log_contains(
        "Auto-save skipped for #{Path.relative_to_cwd(path)}: file changed on disk"
      )

      assert File.read!(path) == "external"
      assert Server.dirty?(pid)
    after
      Events.unsubscribe(:log_message)
    end
  end

  test "auto-save skips when an existing file changes before the timer fires", %{tmp_dir: dir} do
    path = Path.join(dir, "externally-modified.txt")
    File.write!(path, "hello")
    {:ok, pid} = Server.start_link(file_path: path)
    assert {:ok, @delay_ms} = Server.set_option(pid, :auto_save_delay_ms, @delay_ms)

    original_mtime = :sys.get_state(pid).mtime
    :ok = Server.insert_text(pid, "!")
    token = :sys.get_state(pid).auto_save_token
    File.write!(path, "HELLO")
    File.touch!(path, original_mtime)

    Events.subscribe(:log_message)

    try do
      send(pid, {:auto_save, token})
      :sys.get_state(pid)

      assert_log_contains(
        "Auto-save skipped for #{Path.relative_to_cwd(path)}: file changed on disk"
      )

      assert File.read!(path) == "HELLO"
      assert Server.dirty?(pid)
    after
      Events.unsubscribe(:log_message)
    end
  end

  test "auto-save skips when an existing file is deleted before the timer fires", %{tmp_dir: dir} do
    path = Path.join(dir, "externally-deleted.txt")
    File.write!(path, "hello")
    {:ok, pid} = Server.start_link(file_path: path)
    assert {:ok, @delay_ms} = Server.set_option(pid, :auto_save_delay_ms, @delay_ms)

    :ok = Server.insert_text(pid, "!")
    token = :sys.get_state(pid).auto_save_token
    File.rm!(path)

    Events.subscribe(:log_message)

    try do
      send(pid, {:auto_save, token})
      :sys.get_state(pid)

      assert_log_contains(
        "Auto-save skipped for #{Path.relative_to_cwd(path)}: file was deleted on disk"
      )

      refute File.exists?(path)
      assert Server.dirty?(pid)
    after
      Events.unsubscribe(:log_message)
    end
  end

  test "stopping a buffer cancels the pending auto-save timer", %{tmp_dir: dir} do
    path = Path.join(dir, "stopped.txt")
    File.write!(path, "hello")
    {:ok, pid} = Server.start_link(file_path: path)
    assert {:ok, @delay_ms} = Server.set_option(pid, :auto_save_delay_ms, @delay_ms)

    :ok = Server.insert_text(pid, "!")
    assert is_reference(:sys.get_state(pid).auto_save_timer)

    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500

    send(pid, {:auto_save, make_ref()})
    assert File.read!(path) == "hello"
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
      500 -> flunk("expected log message containing #{inspect(text)}")
    end
  end

  defp assert_buffer_saved(path) do
    receive do
      {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: buffer, path: ^path}}
      when is_pid(buffer) ->
        :ok
    after
      500 -> flunk("expected buffer_saved event for #{inspect(path)}")
    end
  end
end
