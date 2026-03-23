defmodule Minga.LSP.SyncServerTest do
  # async: false — reads/mutates the shared SyncServer GenServer process (singleton)
  use ExUnit.Case, async: false

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Events
  alias Minga.LSP.SyncServer

  describe "clients_for_buffer/1" do
    test "returns empty list for untracked buffer" do
      buf = start_supervised!({BufferServer, content: "hello"})
      assert SyncServer.clients_for_buffer(buf) == []
    end
  end

  describe "event bus integration" do
    test "buffer_opened for non-file buffer is a no-op" do
      buf = start_supervised!({BufferServer, content: "scratch"})

      Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: "/tmp/no_lsp.txt"})

      # Sync call to SyncServer to flush its mailbox.
      :sys.get_state(SyncServer)

      assert SyncServer.clients_for_buffer(buf) == []
    end

    test "buffer_closed cleans up ETS entries" do
      buf =
        start_supervised!({BufferServer, content: "hello", file_path: "/tmp/cleanup.ex"})

      # Manually insert a fake entry to simulate an open buffer with clients.
      :ets.insert(SyncServer.Registry, {buf, [self()]})
      assert SyncServer.clients_for_buffer(buf) == [self()]

      Events.broadcast(
        :buffer_closed,
        %Events.BufferClosedEvent{buffer: buf, path: "/tmp/cleanup.ex"}
      )

      # Sync call to flush.
      :sys.get_state(SyncServer)

      assert SyncServer.clients_for_buffer(buf) == []
    end
  end

  describe "buffer_changed event" do
    test "no-op for buffer with no clients" do
      buf = start_supervised!({BufferServer, content: "hello"})

      Events.broadcast(
        :buffer_changed,
        %Events.BufferChangedEvent{buffer: buf, source: :user}
      )

      :sys.get_state(SyncServer)
    end

    test "schedules debounced didChange" do
      buf =
        start_supervised!({BufferServer, content: "hello", file_path: "/tmp/debounce.ex"})

      # Insert a fake client entry.
      :ets.insert(SyncServer.Registry, {buf, [self()]})

      Events.broadcast(
        :buffer_changed,
        %Events.BufferChangedEvent{buffer: buf, source: :user}
      )

      # Sync call to flush the event message through SyncServer's mailbox.
      :sys.get_state(SyncServer)

      state = :sys.get_state(SyncServer)
      assert Map.has_key?(state.debounce_timers, buf)
    end

    test "accumulates deltas from events" do
      buf =
        start_supervised!({BufferServer, content: "hello", file_path: "/tmp/accum.ex"})

      delta = Minga.Buffer.EditDelta.insertion(0, {0, 0}, "x", {0, 1})

      :ets.insert(SyncServer.Registry, {buf, [self()]})

      Events.broadcast(
        :buffer_changed,
        %Events.BufferChangedEvent{buffer: buf, source: :user, delta: delta}
      )

      :sys.get_state(SyncServer)

      state = :sys.get_state(SyncServer)
      assert Map.has_key?(state.delta_accumulators, buf)
      assert [^delta] = state.delta_accumulators[buf]
    end

    test "nil delta marks accumulator as full_sync" do
      buf =
        start_supervised!({BufferServer, content: "hello", file_path: "/tmp/fullsync.ex"})

      delta = Minga.Buffer.EditDelta.insertion(0, {0, 0}, "x", {0, 1})
      :ets.insert(SyncServer.Registry, {buf, [self()]})

      # First: accumulate a real delta
      Events.broadcast(
        :buffer_changed,
        %Events.BufferChangedEvent{buffer: buf, source: :user, delta: delta}
      )

      :sys.get_state(SyncServer)

      # Second: nil delta (bulk op) should mark as full_sync
      Events.broadcast(
        :buffer_changed,
        %Events.BufferChangedEvent{buffer: buf, source: :unknown, delta: nil}
      )

      :sys.get_state(SyncServer)

      state = :sys.get_state(SyncServer)
      assert state.delta_accumulators[buf] == :full_sync
    end
  end

  describe "client monitoring" do
    test "crashed client is removed from ETS registry" do
      buf =
        start_supervised!({BufferServer, content: "hello", file_path: "/tmp/monitor.ex"})

      client = spawn(fn -> receive do: (_ -> :ok) end)
      :ets.insert(SyncServer.Registry, {buf, [client]})

      # Create the monitor inside SyncServer's process so the :DOWN
      # message is delivered to SyncServer, not the test process.
      :sys.replace_state(SyncServer, fn state ->
        ref = Process.monitor(client)
        %{state | client_monitors: Map.put(state.client_monitors, ref, {buf, client})}
      end)

      # Monitor from test process to confirm the process is dead before
      # using :sys.get_state as a flush barrier on SyncServer.
      test_ref = Process.monitor(client)
      Process.exit(client, :kill)
      assert_receive {:DOWN, ^test_ref, :process, ^client, :killed}

      # Now the :DOWN to SyncServer is guaranteed to be in its mailbox.
      :sys.get_state(SyncServer)

      assert SyncServer.clients_for_buffer(buf) == []
    end

    test "crashed client is removed but other clients for same buffer remain" do
      buf =
        start_supervised!({BufferServer, content: "hello", file_path: "/tmp/multi.ex"})

      doomed = spawn(fn -> receive do: (_ -> :ok) end)
      survivor = spawn(fn -> receive do: (_ -> :ok) end)

      on_exit(fn -> Process.exit(survivor, :kill) end)

      :ets.insert(SyncServer.Registry, {buf, [doomed, survivor]})

      :sys.replace_state(SyncServer, fn state ->
        ref = Process.monitor(doomed)
        %{state | client_monitors: Map.put(state.client_monitors, ref, {buf, doomed})}
      end)

      test_ref = Process.monitor(doomed)
      Process.exit(doomed, :kill)
      assert_receive {:DOWN, ^test_ref, :process, ^doomed, :killed}

      :sys.get_state(SyncServer)

      assert SyncServer.clients_for_buffer(buf) == [survivor]
    end

    test "no stale monitors remain after buffer_closed" do
      buf =
        start_supervised!({BufferServer, content: "hello", file_path: "/tmp/close_mon.ex"})

      client = spawn(fn -> receive do: (_ -> :ok) end)

      on_exit(fn -> Process.exit(client, :kill) end)

      :ets.insert(SyncServer.Registry, {buf, [client]})

      :sys.replace_state(SyncServer, fn state ->
        ref = Process.monitor(client)
        %{state | client_monitors: Map.put(state.client_monitors, ref, {buf, client})}
      end)

      Events.broadcast(
        :buffer_closed,
        %Events.BufferClosedEvent{buffer: buf, path: "/tmp/close_mon.ex"}
      )

      final_state = :sys.get_state(SyncServer)
      assert final_state.client_monitors == %{}
    end
  end
end
