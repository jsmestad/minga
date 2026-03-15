defmodule Minga.EventsTest do
  use ExUnit.Case, async: false

  alias Minga.Config.Hooks
  alias Minga.Events

  setup do
    # Start the EventBus Registry if not already running.
    case Registry.start_link(keys: :duplicate, name: Minga.EventBus) do
      {:ok, pid} ->
        on_exit(fn -> Process.exit(pid, :shutdown) end)

      {:error, {:already_started, _}} ->
        :ok
    end

    :ok
  end

  describe "subscribe/1 and broadcast/2" do
    test "subscriber receives broadcast payload" do
      Events.subscribe(:buffer_saved)
      Events.broadcast(:buffer_saved, %{buffer: :fake_buf, path: "/tmp/test.ex"})

      assert_receive {:minga_event, :buffer_saved, %{buffer: :fake_buf, path: "/tmp/test.ex"}}
    end

    test "multiple subscribers all receive the broadcast" do
      parent = self()

      pids =
        for i <- 1..3 do
          spawn(fn ->
            Events.subscribe(:buffer_saved)
            send(parent, {:subscribed, i})

            receive do
              {:minga_event, :buffer_saved, payload} ->
                send(parent, {:received, i, payload})
            end
          end)
        end

      # Wait for all to subscribe before broadcasting.
      for i <- 1..3, do: assert_receive({:subscribed, ^i}, 500)

      Events.broadcast(:buffer_saved, %{buffer: :buf, path: "/test"})

      for i <- 1..3 do
        assert_receive {:received, ^i, %{buffer: :buf, path: "/test"}}, 500
      end

      # Clean up spawned processes.
      for pid <- pids, Process.alive?(pid), do: Process.exit(pid, :kill)
    end

    test "broadcast with no subscribers is a no-op" do
      assert :ok = Events.broadcast(:buffer_saved, %{buffer: :buf, path: "/test"})
      refute_receive {:minga_event, _, _}, 50
    end

    test "subscribing to different topics only receives matching events" do
      Events.subscribe(:buffer_opened)

      Events.broadcast(:buffer_saved, %{buffer: :buf, path: "/test"})
      Events.broadcast(:buffer_opened, %{buffer: :buf, path: "/test"})

      refute_receive {:minga_event, :buffer_saved, _}, 50
      assert_receive {:minga_event, :buffer_opened, %{buffer: :buf, path: "/test"}}
    end
  end

  describe "subscribe/2 with metadata" do
    test "subscribe with metadata value" do
      Events.subscribe(:mode_changed, :my_component)
      Events.broadcast(:mode_changed, %{old: :normal, new: :insert})

      assert_receive {:minga_event, :mode_changed, %{old: :normal, new: :insert}}
    end
  end

  describe "unsubscribe/1" do
    test "unsubscribed process no longer receives broadcasts" do
      Events.subscribe(:buffer_saved)
      Events.unsubscribe(:buffer_saved)

      Events.broadcast(:buffer_saved, %{buffer: :buf, path: "/test"})

      refute_receive {:minga_event, :buffer_saved, _}, 50
    end
  end

  describe "subscribers/1" do
    test "returns pids subscribed to a topic" do
      Events.subscribe(:buffer_saved)
      assert self() in Events.subscribers(:buffer_saved)
    end

    test "process not subscribed is not in the subscribers list" do
      refute self() in Events.subscribers(:buffer_opened)
    end
  end

  describe "integration with Config.Hooks" do
    setup do
      # Hooks and TaskSupervisor are started by the application.
      # Reset hooks between tests to avoid cross-test bleed.
      Hooks.reset()
      on_exit(fn -> Hooks.reset() end)

      :ok
    end

    test "hooks fire when event is broadcast through the bus" do
      test_pid = self()

      Hooks.register(:after_save, fn buf, path ->
        send(test_pid, {:hook_via_bus, buf, path})
      end)

      Events.broadcast(:buffer_saved, %{buffer: :my_buf, path: "/via/bus.ex"})

      assert_receive {:hook_via_bus, :my_buf, "/via/bus.ex"}, 500
    end

    test "mode_changed event triggers on_mode_change hooks" do
      test_pid = self()

      Hooks.register(:on_mode_change, fn old, new ->
        send(test_pid, {:mode_hook, old, new})
      end)

      Events.broadcast(:mode_changed, %{old: :normal, new: :visual})

      assert_receive {:mode_hook, :normal, :visual}, 500
    end

    test "buffer_opened event triggers after_open hooks" do
      test_pid = self()

      Hooks.register(:after_open, fn buf, path ->
        send(test_pid, {:open_hook, buf, path})
      end)

      Events.broadcast(:buffer_opened, %{buffer: :buf, path: "/opened.ex"})

      assert_receive {:open_hook, :buf, "/opened.ex"}, 500
    end
  end
end
