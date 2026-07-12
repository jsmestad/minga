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
