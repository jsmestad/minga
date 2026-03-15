defmodule Minga.LSP.SyncServerTest do
  use ExUnit.Case, async: false

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Events
  alias Minga.LSP.SyncServer

  describe "clients_for_buffer/1" do
    test "returns empty list for untracked buffer" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      assert SyncServer.clients_for_buffer(buf) == []
    end
  end

  describe "event bus integration" do
    test "buffer_opened for non-file buffer is a no-op" do
      {:ok, buf} = BufferServer.start_link(content: "scratch")

      Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: "/tmp/no_lsp.txt"})

      # Sync call to SyncServer to flush its mailbox.
      :sys.get_state(SyncServer)

      assert SyncServer.clients_for_buffer(buf) == []
    end

    test "buffer_closed cleans up ETS entries" do
      {:ok, buf} = BufferServer.start_link(content: "hello", file_path: "/tmp/cleanup.ex")

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

  describe "notify_change/1" do
    test "no-op for buffer with no clients" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      assert :ok = SyncServer.notify_change(buf)
    end

    test "schedules debounced didChange" do
      {:ok, buf} = BufferServer.start_link(content: "hello", file_path: "/tmp/debounce.ex")

      # Insert a fake client entry.
      :ets.insert(SyncServer.Registry, {buf, [self()]})

      SyncServer.notify_change(buf)

      # The debounce timer should be set in SyncServer state.
      state = :sys.get_state(SyncServer)
      assert Map.has_key?(state.debounce_timers, buf)
    end
  end
end
