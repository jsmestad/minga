defmodule Minga.LSP.SyncServerTest do
  # async: false — reads/mutates the shared SyncServer GenServer process (singleton)
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events
  alias Minga.LSP.SyncServer

  describe "clients_for_buffer/1" do
    test "returns empty list for untracked buffer" do
      buf = start_supervised!({BufferProcess, content: "hello"})
      assert SyncServer.clients_for_buffer(buf) == []
    end
  end

  describe "resync_buffers/1" do
    test "clears stale clients, monitors, timers, and deltas before reopening" do
      buf =
        start_supervised!({BufferProcess, content: "hello", file_path: "/tmp/resync.txt"})

      client = spawn(fn -> receive do: (_ -> :ok) end)
      timer = Process.send_after(self(), :unused_sync_timer, 60_000)
      on_exit(fn -> Process.cancel_timer(timer) end)
      on_exit(fn -> Process.exit(client, :kill) end)

      :ets.insert(SyncServer.Registry, {buf, [client]})

      :sys.replace_state(SyncServer, fn state ->
        ref = Process.monitor(client)

        %{
          state
          | client_monitors: Map.put(state.client_monitors, ref, {buf, client}),
            debounce_timers: Map.put(state.debounce_timers, buf, timer),
            delta_accumulators: Map.put(state.delta_accumulators, buf, :full_sync)
        }
      end)

      SyncServer.resync_buffers([buf])

      state = :sys.get_state(SyncServer)
      assert SyncServer.clients_for_buffer(buf) == []

      refute Enum.any?(state.client_monitors, fn {_ref, {buffer_pid, _client_pid}} ->
               buffer_pid == buf
             end)

      refute Map.has_key?(state.debounce_timers, buf)
      refute Map.has_key?(state.delta_accumulators, buf)
    end
  end

  describe "event bus integration" do
    test "buffer_opened for non-file buffer is a no-op" do
      buf = start_supervised!({BufferProcess, content: "scratch"})

      Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: "/tmp/no_lsp.txt"})

      # Sync call to SyncServer to flush its mailbox.
      :sys.get_state(SyncServer)

      assert SyncServer.clients_for_buffer(buf) == []
    end

    test "buffer_closed cleans up ETS entries" do
      buf =
        start_supervised!({BufferProcess, content: "hello", file_path: "/tmp/cleanup.txt"})

      # Manually insert a fake entry to simulate an open buffer with clients.
      :ets.insert(SyncServer.Registry, {buf, [self()]})
      assert SyncServer.clients_for_buffer(buf) == [self()]

      Events.broadcast(
        :buffer_closed,
        %Events.BufferClosedEvent{buffer: buf, path: "/tmp/cleanup.txt"}
      )

      # Sync call to flush.
      :sys.get_state(SyncServer)

      assert SyncServer.clients_for_buffer(buf) == []
    end
  end

  describe "buffer_changed event" do
    test "no-op for buffer with no clients" do
      buf = start_supervised!({BufferProcess, content: "hello"})

      Events.broadcast(
        :buffer_changed,
        %Events.BufferChangedEvent{buffer: buf, source: Minga.Buffer.EditSource.user()}
      )

      :sys.get_state(SyncServer)
    end

    test "schedules debounced didChange" do
      buf =
        start_supervised!({BufferProcess, content: "hello", file_path: "/tmp/debounce.txt"})

      # Insert a fake client entry.
      :ets.insert(SyncServer.Registry, {buf, [self()]})

      Events.broadcast(
        :buffer_changed,
        %Events.BufferChangedEvent{buffer: buf, source: Minga.Buffer.EditSource.user()}
      )

      # Sync call to flush the event message through SyncServer's mailbox.
      :sys.get_state(SyncServer)

      state = :sys.get_state(SyncServer)
      assert Map.has_key?(state.debounce_timers, buf)
    end

    test "accumulates deltas from events" do
      buf =
        start_supervised!({BufferProcess, content: "hello", file_path: "/tmp/accum.txt"})

      delta = Minga.Buffer.EditDelta.insertion(0, {0, 0}, "x", {0, 1})

      :ets.insert(SyncServer.Registry, {buf, [self()]})

      Events.broadcast(
        :buffer_changed,
        %Events.BufferChangedEvent{
          buffer: buf,
          source: Minga.Buffer.EditSource.user(),
          delta: delta
        }
      )

      :sys.get_state(SyncServer)

      state = :sys.get_state(SyncServer)
      assert Map.has_key?(state.delta_accumulators, buf)
      assert [^delta] = state.delta_accumulators[buf]
    end

    test "ignores changes for remote buffers without LSP clients" do
      path = "/tmp/remote-no-lsp.txt"
      buf = start_supervised!({BufferProcess, file_path: path, storage: {:remote, node(), path}})
      delta = Minga.Buffer.EditDelta.insertion(0, {0, 0}, "x", {0, 1})

      Events.broadcast(
        :buffer_changed,
        %Events.BufferChangedEvent{
          buffer: buf,
          source: Minga.Buffer.EditSource.user(),
          delta: delta
        }
      )

      :sys.get_state(SyncServer)

      state = :sys.get_state(SyncServer)
      refute Map.has_key?(state.delta_accumulators, buf)
    end

    test "nil delta marks accumulator as full_sync" do
      buf =
        start_supervised!({BufferProcess, content: "hello", file_path: "/tmp/fullsync.txt"})

      delta = Minga.Buffer.EditDelta.insertion(0, {0, 0}, "x", {0, 1})
      :ets.insert(SyncServer.Registry, {buf, [self()]})

      # First: accumulate a real delta
      Events.broadcast(
        :buffer_changed,
        %Events.BufferChangedEvent{
          buffer: buf,
          source: Minga.Buffer.EditSource.user(),
          delta: delta
        }
      )

      :sys.get_state(SyncServer)

      # Second: nil delta (bulk op) should mark as full_sync
      Events.broadcast(
        :buffer_changed,
        %Events.BufferChangedEvent{
          buffer: buf,
          source: Minga.Buffer.EditSource.unknown(),
          delta: nil
        }
      )

      :sys.get_state(SyncServer)

      state = :sys.get_state(SyncServer)
      assert state.delta_accumulators[buf] == :full_sync
    end
  end

  describe "client monitoring" do
    test "crashed client is removed from ETS registry" do
      buf =
        start_supervised!({BufferProcess, content: "hello", file_path: "/tmp/monitor.txt"})

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

      assert_clients_for_buffer(buf, [])
    end

    test "crashed client is removed but other clients for same buffer remain" do
      buf =
        start_supervised!({BufferProcess, content: "hello", file_path: "/tmp/multi.txt"})

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

      assert_clients_for_buffer(buf, [survivor])
    end

    test "no stale monitors remain after buffer_closed" do
      buf =
        start_supervised!({BufferProcess, content: "hello", file_path: "/tmp/close_mon.txt"})

      client = spawn(fn -> receive do: (_ -> :ok) end)

      on_exit(fn -> Process.exit(client, :kill) end)

      :ets.insert(SyncServer.Registry, {buf, [client]})

      :sys.replace_state(SyncServer, fn state ->
        ref = Process.monitor(client)
        %{state | client_monitors: Map.put(state.client_monitors, ref, {buf, client})}
      end)

      Events.broadcast(
        :buffer_closed,
        %Events.BufferClosedEvent{buffer: buf, path: "/tmp/close_mon.txt"}
      )

      final_state = :sys.get_state(SyncServer)

      refute Enum.any?(final_state.client_monitors, fn {_ref, {buffer_pid, _client_pid}} ->
               buffer_pid == buf
             end)
    end
  end

  @spec assert_clients_for_buffer(pid(), [pid()], non_neg_integer()) :: :ok
  defp assert_clients_for_buffer(buffer_pid, expected, attempts \\ 50)

  defp assert_clients_for_buffer(buffer_pid, expected, attempts) when attempts > 0 do
    :sys.get_state(SyncServer)

    case SyncServer.clients_for_buffer(buffer_pid) do
      ^expected ->
        :ok

      _other ->
        receive do
        after
          10 -> assert_clients_for_buffer(buffer_pid, expected, attempts - 1)
        end
    end
  end

  defp assert_clients_for_buffer(buffer_pid, expected, 0) do
    assert SyncServer.clients_for_buffer(buffer_pid) == expected
  end
end
