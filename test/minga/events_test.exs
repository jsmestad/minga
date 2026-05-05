defmodule Minga.EventsTest do
  # async: false — uses application-level EventBus registry
  use ExUnit.Case, async: false

  alias Minga.Events

  setup do
    # The EventBus Registry is started by the application supervision tree.
    # Tests should use the application's instance rather than starting their own,
    # because killing a test-started instance with the same name poisons the
    # rest_for_one supervisor and cascades failures to every downstream process.
    :ok
  end

  # Spawns a long-lived process to use as a fake buffer pid. Event bus
  # subscribers like Git.Tracker guard on `is_pid(buf)`, so passing atoms
  # would either be silently ignored (best case) or crash downstream
  # GenServers and cascade through the rest_for_one supervisor (worst case).
  defp fake_buffer do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)

    on_exit(fn ->
      if Process.alive?(pid), do: send(pid, :stop)
    end)

    pid
  end

  describe "subscribe/1 and broadcast/2" do
    test "subscriber receives broadcast payload" do
      buf = fake_buffer()
      Events.subscribe(:buffer_saved)
      Events.broadcast(:buffer_saved, %Events.BufferEvent{buffer: buf, path: "/tmp/test.ex"})

      assert_receive {:minga_event, :buffer_saved,
                      %Events.BufferEvent{buffer: ^buf, path: "/tmp/test.ex"}}
    end

    test "multiple subscribers all receive the broadcast" do
      buf = fake_buffer()
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

      Events.broadcast(:buffer_saved, %Events.BufferEvent{buffer: buf, path: "/test"})

      for i <- 1..3 do
        assert_receive {:received, ^i, %{buffer: ^buf, path: "/test"}}, 500
      end

      # Clean up spawned processes.
      for pid <- pids, Process.alive?(pid), do: Process.exit(pid, :kill)
    end

    test "broadcast with no subscribers is a no-op" do
      buf = fake_buffer()

      assert :ok =
               Events.broadcast(:buffer_saved, %Events.BufferEvent{buffer: buf, path: "/test"})

      refute_receive {:minga_event, _, _}, 50
    end

    test "subscribing to the same topic twice delivers only one event per broadcast" do
      buf = fake_buffer()
      Events.subscribe(:buffer_saved)
      Events.subscribe(:buffer_saved)

      Events.broadcast(:buffer_saved, %Events.BufferEvent{buffer: buf, path: "/tmp/test.ex"})

      assert_receive {:minga_event, :buffer_saved, _}
      refute_receive {:minga_event, :buffer_saved, _}, 50
    end

    test "subscribing to different topics only receives matching events" do
      buf = fake_buffer()
      Events.subscribe(:buffer_opened)

      Events.broadcast(:buffer_saved, %Events.BufferEvent{buffer: buf, path: "/test"})
      Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: "/test"})

      refute_receive {:minga_event, :buffer_saved, _}, 50

      assert_receive {:minga_event, :buffer_opened,
                      %Events.BufferEvent{buffer: ^buf, path: "/test"}}
    end
  end

  describe "buffer_closed event" do
    test "subscriber receives buffer_closed with buffer and path" do
      buf = fake_buffer()
      Events.subscribe(:buffer_closed)

      Events.broadcast(
        :buffer_closed,
        %Events.BufferClosedEvent{buffer: buf, path: "/closed.ex"}
      )

      assert_receive {:minga_event, :buffer_closed,
                      %Events.BufferClosedEvent{buffer: ^buf, path: "/closed.ex"}}
    end

    test "buffer_closed with scratch buffer (unnamed)" do
      buf = fake_buffer()
      Events.subscribe(:buffer_closed)

      Events.broadcast(
        :buffer_closed,
        %Events.BufferClosedEvent{buffer: buf, path: :scratch}
      )

      assert_receive {:minga_event, :buffer_closed,
                      %Events.BufferClosedEvent{buffer: ^buf, path: :scratch}}
    end
  end

  describe "buffer_changed event" do
    test "subscriber receives buffer_changed with buffer pid and source" do
      buf = fake_buffer()
      Events.subscribe(:buffer_changed)

      Events.broadcast(
        :buffer_changed,
        %Events.BufferChangedEvent{buffer: buf, source: Minga.Buffer.EditSource.user()}
      )

      assert_receive {:minga_event, :buffer_changed,
                      %Events.BufferChangedEvent{buffer: ^buf, source: :user}}
    end
  end

  describe "subscribe/2 with metadata" do
    test "subscribe with metadata value" do
      Events.subscribe(:mode_changed, :my_component)
      Events.broadcast(:mode_changed, %Events.ModeEvent{old: :normal, new: :insert})

      assert_receive {:minga_event, :mode_changed, %Events.ModeEvent{old: :normal, new: :insert}}
    end

    test "subscribing with same topic and value twice delivers only one event" do
      Events.subscribe(:mode_changed, :my_component)
      Events.subscribe(:mode_changed, :my_component)

      Events.broadcast(:mode_changed, %Events.ModeEvent{old: :normal, new: :insert})

      assert_receive {:minga_event, :mode_changed, _}
      refute_receive {:minga_event, :mode_changed, _}, 50
    end
  end

  describe "unsubscribe/1" do
    test "unsubscribed process no longer receives broadcasts" do
      buf = fake_buffer()
      Events.subscribe(:buffer_saved)
      Events.unsubscribe(:buffer_saved)

      Events.broadcast(:buffer_saved, %Events.BufferEvent{buffer: buf, path: "/test"})

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
end
