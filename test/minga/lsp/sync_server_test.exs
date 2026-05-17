defmodule Minga.LSP.SyncServerTest do
  # async: false because this test isolates the shared SyncServer singleton and ETS registry.
  use ExUnit.Case, async: false

  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events
  alias Minga.LSP.SyncServer

  @moduletag :tmp_dir

  setup do
    reset_sync_server()
    :ok
  end

  describe "clients_for_buffer/1" do
    test "returns empty list for untracked buffer" do
      buf = start_buffer(content: "hello")

      assert SyncServer.clients_for_buffer(buf) == []
    end
  end

  describe "resync_buffers/1" do
    test "clears stale clients before reopening", %{tmp_dir: dir} do
      path = Path.join(dir, "resync.txt")
      buf = start_buffer(content: "hello", file_path: path)
      client = start_client()
      :ets.insert(SyncServer.Registry, {buf, [client]})

      SyncServer.resync_buffers([buf])
      sync_server()

      assert SyncServer.clients_for_buffer(buf) == []
    end
  end

  describe "event bus integration" do
    test "buffer_opened for non-file buffer is a no-op" do
      buf = start_buffer(content: "scratch")

      Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: "/tmp/no_lsp.txt"})
      sync_server()

      assert SyncServer.clients_for_buffer(buf) == []
    end

    test "buffer_closed removes clients from the registry", %{tmp_dir: dir} do
      path = Path.join(dir, "cleanup.txt")
      buf = start_buffer(content: "hello", file_path: path)
      client = start_client()
      :ets.insert(SyncServer.Registry, {buf, [client]})
      assert SyncServer.clients_for_buffer(buf) == [client]

      Events.broadcast(:buffer_closed, %Events.BufferClosedEvent{buffer: buf, path: path})
      sync_server()

      assert SyncServer.clients_for_buffer(buf) == []
    end
  end

  describe "buffer_changed event" do
    test "sends a debounced full didChange to attached clients", %{tmp_dir: dir} do
      path = Path.join(dir, "full.txt")
      File.write!(path, "hello")
      buf = start_buffer(file_path: path)
      client = start_client(:full)
      :ets.insert(SyncServer.Registry, {buf, [client]})

      Events.broadcast(:buffer_changed, changed_event(buf, nil))

      assert_receive {:client_cast, ^client, {:did_change, uri, "hello"}}, 1_000
      assert uri == SyncServer.path_to_uri(path)
    end

    test "sends accumulated deltas incrementally in document order", %{tmp_dir: dir} do
      path = Path.join(dir, "incremental.txt")
      File.write!(path, "hello")
      buf = start_buffer(file_path: path)
      client = start_client(:incremental)
      first = EditDelta.insertion(0, {0, 0}, "x", {0, 1})
      second = EditDelta.insertion(1, {0, 1}, "y", {0, 2})
      :ets.insert(SyncServer.Registry, {buf, [client]})

      Events.broadcast(:buffer_changed, changed_event(buf, first))
      Events.broadcast(:buffer_changed, changed_event(buf, second))

      assert_receive {:client_cast, ^client, {:did_change_incremental, uri, changes}}, 1_000
      assert uri == SyncServer.path_to_uri(path)
      assert changes == [{0, 0, 0, 0, "x"}, {0, 1, 0, 1, "y"}]
    end

    test "nil delta falls back to full sync even for incremental clients", %{tmp_dir: dir} do
      path = Path.join(dir, "bulk.txt")
      File.write!(path, "hello")
      buf = start_buffer(file_path: path)
      client = start_client(:incremental)
      delta = EditDelta.insertion(0, {0, 0}, "x", {0, 1})
      :ets.insert(SyncServer.Registry, {buf, [client]})

      Events.broadcast(:buffer_changed, changed_event(buf, delta))
      Events.broadcast(:buffer_changed, changed_event(buf, nil, EditSource.unknown()))

      assert_receive {:client_cast, ^client, {:did_change, uri, "hello"}}, 1_000
      assert uri == SyncServer.path_to_uri(path)
      refute_receive {:client_cast, ^client, {:did_change_incremental, _, _}}, 50
    end

    test "changes for buffers without clients are ignored" do
      buf = start_buffer(content: "hello")

      Events.broadcast(:buffer_changed, changed_event(buf, nil))

      refute_receive {:client_cast, _client, _message}, 250
    end
  end

  describe "client monitoring" do
    test "crashed client is removed while survivors remain", %{tmp_dir: dir} do
      path = Path.join(dir, "monitor.txt")
      File.write!(path, "hello")
      buf = start_buffer(file_path: path)
      doomed = start_client()
      survivor = start_client()
      :ets.insert(SyncServer.Registry, {buf, [doomed, survivor]})
      monitor_client_in_sync_server(buf, doomed)

      ref = Process.monitor(doomed)
      Process.exit(doomed, :kill)
      assert_receive {:DOWN, ^ref, :process, ^doomed, :killed}
      sync_server()

      assert SyncServer.clients_for_buffer(buf) == [survivor]
    end
  end

  defp start_buffer(opts) do
    start_supervised!({BufferProcess, opts}, id: {:buffer, make_ref()})
  end

  defp changed_event(buf, delta, source \\ EditSource.user()) do
    %Events.BufferChangedEvent{buffer: buf, source: source, delta: delta}
  end

  defp start_client(sync_kind \\ :full) do
    parent = self()
    pid = spawn(fn -> client_loop(parent, sync_kind) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp client_loop(parent, sync_kind) do
    receive do
      {:"$gen_call", from, :sync_kind} ->
        GenServer.reply(from, sync_kind)
        client_loop(parent, sync_kind)

      {:"$gen_cast", message} ->
        send(parent, {:client_cast, self(), message})
        client_loop(parent, sync_kind)

      _message ->
        client_loop(parent, sync_kind)
    end
  end

  defp monitor_client_in_sync_server(buf, client) do
    :sys.replace_state(SyncServer, fn state ->
      ref = Process.monitor(client)
      %{state | client_monitors: Map.put(state.client_monitors, ref, {buf, client})}
    end)
  end

  defp sync_server do
    :sys.get_state(SyncServer)
    :ok
  end

  defp reset_sync_server do
    :ets.delete_all_objects(SyncServer.Registry)

    :sys.replace_state(SyncServer, fn state ->
      Enum.each(Map.values(state.debounce_timers), &Process.cancel_timer/1)

      %{
        state
        | debounce_timers: %{},
          client_monitors: %{},
          delta_accumulators: %{},
          pending_tool_buffers: %{}
      }
    end)
  end
end
