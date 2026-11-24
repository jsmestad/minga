defmodule MingaEditor.WatchdogTest do
  # erl_signal_server is VM-global, and the recovery contract sends a real OS signal.
  use ExUnit.Case, async: false

  alias MingaEditor.Watchdog
  alias MingaEditor.Watchdog.SignalHandler

  describe "init" do
    test "registers a supervised SIGUSR2 handler" do
      assert {:ok, pid} = Watchdog.start_link(name: :test_watchdog, editor_name: :fake_editor)
      assert {SignalHandler, pid} in :gen_event.which_handlers(:erl_signal_server)

      GenServer.stop(pid)
      refute {SignalHandler, pid} in :gen_event.which_handlers(:erl_signal_server)
    end
  end

  describe "SIGUSR2 handling" do
    @tag timeout: 5_000
    test "a real SIGUSR2 kills the editor process without terminating the BEAM" do
      editor_name = :"test_editor_for_watchdog_#{System.unique_integer([:positive])}"

      editor =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Process.register(editor, editor_name)

      {:ok, watchdog} =
        Watchdog.start_link(
          name: :"test_watchdog_kill_#{System.unique_integer([:positive])}",
          editor_name: editor_name
        )

      ref = Process.monitor(editor)
      kill = System.find_executable("kill") || raise "kill executable not found"
      assert {_output, 0} = System.cmd(kill, ["-USR2", System.pid()], stderr_to_stdout: true)
      assert_receive {:DOWN, ^ref, :process, ^editor, :killed}, 1000
      assert Process.alive?(watchdog)

      GenServer.stop(watchdog)
    end

    test "handles SIGUSR2 gracefully when editor is not running" do
      {:ok, watchdog} =
        Watchdog.start_link(
          name: :test_watchdog_no_editor,
          editor_name: :nonexistent_editor_process
        )

      :ok = :gen_event.notify(:erl_signal_server, :sigusr2)
      _ = :sys.get_state(watchdog)
      assert Process.alive?(watchdog)

      GenServer.stop(watchdog)
    end

    test "survives multiple SIGUSR2 signals" do
      {:ok, watchdog} =
        Watchdog.start_link(
          name: :test_watchdog_multi,
          editor_name: :nonexistent_editor_multi
        )

      send(watchdog, {:signal, :sigusr2})
      send(watchdog, {:signal, :sigusr2})
      send(watchdog, {:signal, :sigusr2})
      _ = :sys.get_state(watchdog)
      assert Process.alive?(watchdog)

      GenServer.stop(watchdog)
    end
  end

  describe "stall sampler" do
    test "detects editor blocked with messages queued" do
      import ExUnit.CaptureLog

      editor_name = :"stall_blocked_#{System.unique_integer([:positive])}"

      # A stand-in that blocks forever in receive (simulating a stuck Editor).
      blocked =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Process.register(blocked, editor_name)

      # Queue messages so the mailbox is non-empty.
      send(blocked, :msg1)
      send(blocked, :msg2)

      {:ok, watchdog} =
        Watchdog.start_link(
          name: :"stall_wd_blocked_#{System.unique_integer([:positive])}",
          editor_name: editor_name,
          sample_interval_ms: 60_000
        )

      log =
        capture_log(fn ->
          # First sample: establishes baseline (prev_queue_len was 0).
          send(watchdog, :sample)
          _ = :sys.get_state(watchdog)

          # Second sample: prev_queue_len > 0, process is :waiting, triggers warning.
          send(watchdog, :sample)
          _ = :sys.get_state(watchdog)
        end)

      assert log =~ "Editor stall detected"

      GenServer.stop(watchdog)
      Process.exit(blocked, :kill)
    end

    test "healthy burst (draining queue) does not warn" do
      import ExUnit.CaptureLog

      editor_name = :"stall_healthy_#{System.unique_integer([:positive])}"

      # A stand-in that processes messages (drains its mailbox).
      parent = self()

      healthy =
        spawn(fn ->
          send(parent, :ready)

          Stream.repeatedly(fn ->
            receive do
              :drain -> :ok
              :stop -> exit(:normal)
              _other -> :ok
            end
          end)
          |> Stream.run()
        end)

      assert_receive :ready

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Process.register(healthy, editor_name)

      {:ok, watchdog} =
        Watchdog.start_link(
          name: :"stall_wd_healthy_#{System.unique_integer([:positive])}",
          editor_name: editor_name,
          sample_interval_ms: 60_000
        )

      log =
        capture_log(fn ->
          # Queue some messages for the first sample.
          send(healthy, :msg1)
          send(healthy, :msg2)

          send(watchdog, :sample)
          _ = :sys.get_state(watchdog)

          # Drain the queue before the second sample.
          send(healthy, :drain)
          # Give the stand-in time to process its messages.
          Process.sleep(10)

          send(watchdog, :sample)
          _ = :sys.get_state(watchdog)
        end)

      refute log =~ "Editor stall detected"

      GenServer.stop(watchdog)
      send(healthy, :stop)
    end

    test "idle editor does not warn" do
      import ExUnit.CaptureLog

      editor_name = :"stall_idle_#{System.unique_integer([:positive])}"

      idle =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Process.register(idle, editor_name)

      {:ok, watchdog} =
        Watchdog.start_link(
          name: :"stall_wd_idle_#{System.unique_integer([:positive])}",
          editor_name: editor_name,
          sample_interval_ms: 60_000
        )

      log =
        capture_log(fn ->
          send(watchdog, :sample)
          _ = :sys.get_state(watchdog)

          send(watchdog, :sample)
          _ = :sys.get_state(watchdog)
        end)

      refute log =~ "Editor stall detected"

      GenServer.stop(watchdog)
      Process.exit(idle, :kill)
    end

    test "editor exits and restarts without crashing sampler" do
      editor_name = :"stall_restart_#{System.unique_integer([:positive])}"

      first =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Process.register(first, editor_name)

      {:ok, watchdog} =
        Watchdog.start_link(
          name: :"stall_wd_restart_#{System.unique_integer([:positive])}",
          editor_name: editor_name,
          sample_interval_ms: 60_000
        )

      # Sample while editor is alive.
      send(watchdog, :sample)
      _ = :sys.get_state(watchdog)

      # Kill the first editor.
      Process.exit(first, :kill)
      # Allow time for the process to exit and unregister.
      Process.sleep(10)

      # Register a new one.
      second =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Process.register(second, editor_name)

      # Sample again; should not crash.
      send(watchdog, :sample)
      _ = :sys.get_state(watchdog)
      assert Process.alive?(watchdog)

      GenServer.stop(watchdog)
      Process.exit(second, :kill)
    end

    test "stall re-arms after queue drains to zero" do
      import ExUnit.CaptureLog

      editor_name = :"stall_rearm_#{System.unique_integer([:positive])}"

      # Phase 1: a blocked process that accumulates messages.
      blocked =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Process.register(blocked, editor_name)
      send(blocked, :msg1)
      send(blocked, :msg2)

      {:ok, watchdog} =
        Watchdog.start_link(
          name: :"stall_wd_rearm_#{System.unique_integer([:positive])}",
          editor_name: editor_name,
          sample_interval_ms: 60_000
        )

      # Trigger the stall warning.
      first_log =
        capture_log(fn ->
          send(watchdog, :sample)
          _ = :sys.get_state(watchdog)

          send(watchdog, :sample)
          _ = :sys.get_state(watchdog)
        end)

      assert first_log =~ "Editor stall detected"

      # Kill the blocked stand-in and replace with a fresh idle one (empty queue).
      Process.exit(blocked, :kill)
      Process.sleep(10)

      idle =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Process.register(idle, editor_name)

      # Sample at zero to reset stall_reported.
      send(watchdog, :sample)
      state = :sys.get_state(watchdog)
      refute state.stall_reported

      # Trigger another stall on the new stand-in.
      send(idle, :msg3)
      send(idle, :msg4)

      second_log =
        capture_log(fn ->
          send(watchdog, :sample)
          _ = :sys.get_state(watchdog)

          send(watchdog, :sample)
          _ = :sys.get_state(watchdog)
        end)

      assert second_log =~ "Editor stall detected"

      GenServer.stop(watchdog)
      Process.exit(idle, :kill)
    end

    test "only one warning per stall event" do
      import ExUnit.CaptureLog

      editor_name = :"stall_once_#{System.unique_integer([:positive])}"

      blocked =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Process.register(blocked, editor_name)

      send(blocked, :msg1)
      send(blocked, :msg2)

      {:ok, watchdog} =
        Watchdog.start_link(
          name: :"stall_wd_once_#{System.unique_integer([:positive])}",
          editor_name: editor_name,
          sample_interval_ms: 60_000
        )

      # First two samples: triggers stall warning.
      capture_log(fn ->
        send(watchdog, :sample)
        _ = :sys.get_state(watchdog)

        send(watchdog, :sample)
        _ = :sys.get_state(watchdog)
      end)

      # Third, fourth, fifth samples: should NOT warn again.
      log =
        capture_log(fn ->
          send(watchdog, :sample)
          _ = :sys.get_state(watchdog)

          send(watchdog, :sample)
          _ = :sys.get_state(watchdog)

          send(watchdog, :sample)
          _ = :sys.get_state(watchdog)
        end)

      refute log =~ "Editor stall detected"

      GenServer.stop(watchdog)
      Process.exit(blocked, :kill)
    end
  end

  describe "ignores unknown messages" do
    test "does not crash on unexpected messages" do
      {:ok, watchdog} =
        Watchdog.start_link(name: :test_watchdog_unknown, editor_name: :fake_editor_unknown)

      send(watchdog, :random_message)
      send(watchdog, {:signal, :sigusr1})
      send(watchdog, {:some, :tuple})
      _ = :sys.get_state(watchdog)
      assert Process.alive?(watchdog)

      GenServer.stop(watchdog)
    end
  end
end
