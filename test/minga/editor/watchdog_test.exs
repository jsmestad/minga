defmodule Minga.Editor.WatchdogTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Watchdog

  describe "init" do
    test "starts and registers for SIGUSR1" do
      assert {:ok, pid} = Watchdog.start_link(name: :test_watchdog, editor_name: :fake_editor)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "SIGUSR1 handling" do
    test "kills the editor process on SIGUSR1" do
      editor =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      Process.register(editor, :test_editor_for_watchdog)

      {:ok, watchdog} =
        Watchdog.start_link(name: :test_watchdog_kill, editor_name: :test_editor_for_watchdog)

      ref = Process.monitor(editor)

      send(watchdog, {:signal, :sigusr1})

      assert_receive {:DOWN, ^ref, :process, ^editor, :killed}, 1000

      GenServer.stop(watchdog)
    end

    test "handles SIGUSR1 gracefully when editor is not running" do
      {:ok, watchdog} =
        Watchdog.start_link(
          name: :test_watchdog_no_editor,
          editor_name: :nonexistent_editor_process
        )

      send(watchdog, {:signal, :sigusr1})
      _ = :sys.get_state(watchdog)
      assert Process.alive?(watchdog)

      GenServer.stop(watchdog)
    end

    test "survives multiple SIGUSR1 signals" do
      {:ok, watchdog} =
        Watchdog.start_link(
          name: :test_watchdog_multi,
          editor_name: :nonexistent_editor_multi
        )

      send(watchdog, {:signal, :sigusr1})
      send(watchdog, {:signal, :sigusr1})
      send(watchdog, {:signal, :sigusr1})
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
      send(watchdog, {:signal, :sigusr2})
      send(watchdog, {:some, :tuple})
      _ = :sys.get_state(watchdog)
      assert Process.alive?(watchdog)

      GenServer.stop(watchdog)
    end
  end
end
