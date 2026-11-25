defmodule Minga.Buffer.SwapCrashTest do
  @moduledoc "A buffer that crashes keeps its unsaved text in the swap file; a buffer that is closed removes it."

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events
  alias Minga.Events.BufferCrashedEvent
  alias Minga.Session
  alias Minga.Session.ControllableSwapBackend
  alias Minga.Session.Swap
  alias Minga.Session.Swap.Recovery

  @moduletag :tmp_dir
  @moduletag capture_log: true
  @timeout 2_000

  setup %{tmp_dir: tmp_dir} do
    registry = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :duplicate, name: registry})
    :ok = Events.subscribe(:buffer_crashed, registry)

    path = Path.join(tmp_dir, "notes.txt")
    File.write!(path, "saved text")
    %{registry: registry, path: path, swap_dir: Path.join(tmp_dir, "swap")}
  end

  describe "a callback that raises" do
    test "keeps the swap file, and the next start recovers the unsaved text once", ctx do
      buffer = start_buffer(ctx)
      swap_path = Swap.swap_path(ctx.path, swap_dir: ctx.swap_dir)
      path = ctx.path

      # No swap write has run: the edit is younger than the debounce.
      :ok = BufferProcess.replace_content(buffer, "unsaved text")
      refute File.exists?(swap_path)

      crash(buffer)

      assert File.exists?(swap_path)

      assert_receive {:minga_event, :buffer_crashed,
                      %BufferCrashedEvent{buffer: ^buffer, path: ^path, swap_path: ^swap_path}}

      # The swap belongs to this running VM, so a scan from a live editor leaves it alone.
      assert Recovery.scan(swap_dir: ctx.swap_dir, pid_alive?: fn _os_pid -> true end) == []
      assert File.exists?(swap_path)

      # After the VM is gone, the next start finds it and recovers the text.
      next_start = [swap_dir: ctx.swap_dir, pid_alive?: fn _os_pid -> false end]
      assert [%{path: ^path, swap_path: ^swap_path}] = Recovery.scan(next_start)
      assert {:ok, ^path, "unsaved text"} = Session.recover_swap_file(swap_path)

      # Recovery consumes the swap, so it is not offered a second time.
      assert Recovery.scan(next_start) == []
      refute File.exists?(swap_path)
    end

    test "logs the buffer path and the swap path", ctx do
      buffer = start_buffer(ctx)
      swap_path = Swap.swap_path(ctx.path, swap_dir: ctx.swap_dir)
      :ok = BufferProcess.replace_content(buffer, "unsaved text")

      log = capture_log(fn -> crash(buffer) end)

      assert log =~ "Buffer for #{ctx.path} crashed (no function clause matching"
      assert log =~ "Its unsaved text is kept in #{swap_path}"
    end

    test "replaces an older swap with the text at the time of the crash", ctx do
      {buffer, swap_path} = start_controlled_buffer(ctx)

      :ok = BufferProcess.replace_content(buffer, "older text")
      publish_swap(buffer, ctx.path, "older text")
      :ok = BufferProcess.replace_content(buffer, "newest text")

      monitor = raise_in_callback(buffer)
      release_crash_write(buffer, ctx.path, "newest text", :ok)
      assert_receive {:DOWN, ^monitor, :process, ^buffer, _reason}, @timeout

      assert {:ok, _path, "newest text"} = Session.recover_swap_file(swap_path)
    end

    test "keeps the older swap when the write at the crash fails", ctx do
      {buffer, swap_path} = start_controlled_buffer(ctx)
      path = ctx.path

      :ok = BufferProcess.replace_content(buffer, "older text")
      publish_swap(buffer, ctx.path, "older text")
      :ok = BufferProcess.replace_content(buffer, "newest text")

      log =
        capture_log(fn ->
          monitor = raise_in_callback(buffer)
          release_crash_write(buffer, ctx.path, "newest text", {:error, :disk_full})
          assert_receive {:DOWN, ^monitor, :process, ^buffer, _reason}, @timeout
        end)

      assert log =~ "crash_flush_failed"
      assert log =~ "Its unsaved text is kept in #{swap_path}"

      assert_receive {:minga_event, :buffer_crashed,
                      %BufferCrashedEvent{path: ^path, swap_path: ^swap_path}}

      assert {:ok, ^path, "older text"} = Session.recover_swap_file(swap_path)
    end

    test "says the text could not be kept when the write fails and no swap exists", ctx do
      {buffer, swap_path} = start_controlled_buffer(ctx)
      :ok = BufferProcess.replace_content(buffer, "unsaved text")

      log =
        capture_log(fn ->
          monitor = raise_in_callback(buffer)
          release_crash_write(buffer, ctx.path, "unsaved text", {:error, :disk_full})
          assert_receive {:DOWN, ^monitor, :process, ^buffer, _reason}, @timeout
        end)

      assert log =~ "Its unsaved text could not be kept"
      refute File.exists?(swap_path)
      refute_receive {:minga_event, :buffer_crashed, _event}, 0
    end

    test "keeps nothing and announces nothing when the buffer has no unsaved text", ctx do
      buffer = start_buffer(ctx)

      log = capture_log(fn -> crash(buffer) end)

      assert log =~ "Buffer for #{ctx.path} crashed"
      assert log =~ "It had no unsaved text"
      refute File.exists?(Swap.swap_path(ctx.path, swap_dir: ctx.swap_dir))
      refute_receive {:minga_event, :buffer_crashed, _event}, 0
    end

    test "says the text could not be kept when the buffer has no swap directory", ctx do
      buffer =
        start_supervised!(
          {BufferProcess, file_path: ctx.path, events_registry: ctx.registry},
          id: make_ref()
        )

      :ok = BufferProcess.replace_content(buffer, "unsaved text")

      log = capture_log(fn -> crash(buffer) end)

      assert log =~ "Its unsaved text could not be kept"
      refute_receive {:minga_event, :buffer_crashed, _event}, 0
    end
  end

  describe "a deliberate stop" do
    test "removes the swap file for every deliberate reason and announces no crash", ctx do
      for reason <- [:normal, :shutdown, {:shutdown, :closing}] do
        buffer = start_buffer(ctx)
        swap_path = Swap.swap_path(ctx.path, swap_dir: ctx.swap_dir)
        :ok = BufferProcess.replace_content(buffer, "unsaved text")
        :ok = Swap.write(ctx.path, "unsaved text", swap_dir: ctx.swap_dir)
        assert File.exists?(swap_path)

        assert :ok = GenServer.stop(buffer, reason)

        refute File.exists?(swap_path), "#{inspect(reason)} left the swap file"
        refute_receive {:minga_event, :buffer_crashed, _event}, 0
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp start_buffer(ctx) do
    start_supervised!(
      {BufferProcess, file_path: ctx.path, swap_dir: ctx.swap_dir, events_registry: ctx.registry},
      id: make_ref()
    )
  end

  # A buffer whose swap writes wait for this test, so a write can be made to fail.
  defp start_controlled_buffer(ctx) do
    backend_options = [controller: self(), os_pid: 99_999]

    buffer =
      start_supervised!(
        {BufferProcess,
         file_path: ctx.path,
         swap_dir: ctx.swap_dir,
         swap_backend: ControllableSwapBackend,
         swap_backend_options: backend_options,
         events_registry: ctx.registry},
        id: make_ref()
      )

    {buffer, Swap.swap_path(ctx.path, swap_dir: ctx.swap_dir, os_pid: 99_999)}
  end

  defp publish_swap(buffer, path, content) do
    send(buffer, :write_swap)
    assert_receive {:swap_prepare, worker, generation, ^path, ^content}, @timeout
    send(worker, {:swap_prepare_result, generation, :ok})

    assert_receive {:swap_published, ^buffer, ^worker, ^generation, ^path, ^content, :ok},
                   @timeout
  end

  # No callback handles this message, so `handle_info/2` raises a FunctionClauseError.
  defp raise_in_callback(buffer) do
    monitor = Process.monitor(buffer)
    send(buffer, :message_no_callback_handles)
    monitor
  end

  defp crash(buffer) do
    monitor = raise_in_callback(buffer)
    assert_receive {:DOWN, ^monitor, :process, ^buffer, {:function_clause, _stack}}, @timeout
  end

  # The crash write runs in the dying buffer process, so the buffer itself waits at the backend barrier.
  defp release_crash_write(buffer, path, content, result) do
    assert_receive {:swap_prepare, ^buffer, generation, ^path, ^content}, @timeout
    send(buffer, {:swap_prepare_result, generation, result})
  end
end
