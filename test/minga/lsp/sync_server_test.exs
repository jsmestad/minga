defmodule Minga.LSP.SyncServerTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias Minga.Events
  alias Minga.LSP.ServerRegistry
  alias Minga.LSP.SyncServer

  @moduletag :tmp_dir

  # Each test runs its own SyncServer with a private ETS table, event bus, buffer registry and
  # options, so restarting it never touches the application's singleton or another test.
  setup do
    id = System.unique_integer([:positive])
    events = :"sync_server_test_events_#{id}"
    buffers = :"sync_server_test_buffers_#{id}"
    start_supervised!(Events.child_spec(name: events))
    start_supervised!({Registry, keys: :unique, name: buffers}, id: :buffer_registry)
    options = start_supervised!({Options, name: nil, events_registry: events}, id: :options)
    lsp_supervisor = :"sync_server_test_lsp_#{id}"
    start_supervised!({Minga.LSP.Supervisor, name: lsp_supervisor})

    sync = %{
      name: :"sync_server_test_#{id}",
      table: :"sync_server_test_registry_#{id}",
      events: events,
      buffers: buffers,
      options: options,
      lsp_supervisor: lsp_supervisor
    }

    start_sync_server(sync)
    %{sync: sync}
  end

  describe "event bus integration" do
    test "opening a file with no configured server does not read its content", %{
      tmp_dir: dir,
      sync: sync
    } do
      path = Path.join(dir, "no-server.txt")
      File.write!(path, "hello")
      buf = start_buffer(sync, file_path: path, filetype: :text)
      assert ServerRegistry.servers_for(BufferProcess.filetype(buf)) == []
      :ok = :sys.install(buf, {:open_reads, &observe_buffer_call/3, self()})
      assert {:ok, true} = Options.set(sync.options, :lsp_auto_start, true)

      send(
        sync.name,
        {:minga_event, :buffer_opened, %Events.BufferEvent{buffer: buf, path: path}}
      )

      sync_server(sync)
      :sys.remove(buf, :open_reads)

      assert_received {:observed_buffer_call, :filetype}
      assert_received {:observed_buffer_call, :file_path}
      refute_received {:observed_buffer_call, :content_with_version}
    end

    test "buffer_closed removes clients from the registry", %{tmp_dir: dir, sync: sync} do
      path = Path.join(dir, "cleanup.txt")
      buf = start_buffer(sync, content: "hello", file_path: path)
      client = start_client()
      SyncServer.put_clients(buf, [client], sync.table)
      assert SyncServer.clients_for_buffer(buf, sync.table) == [client]

      Events.broadcast(
        :buffer_closed,
        %Events.BufferClosedEvent{buffer: buf, path: path},
        sync.events
      )

      sync_server(sync)

      assert SyncServer.clients_for_buffer(buf, sync.table) == []
    end
  end

  describe "buffer_changed event" do
    test "sends ordered incremental deltas and ignores stale bulk events", %{
      tmp_dir: dir,
      sync: sync
    } do
      path = Path.join(dir, "incremental.txt")
      File.write!(path, "hello")
      buf = start_buffer(sync, file_path: path)
      client = start_client(:incremental)
      first = EditDelta.insertion(0, {0, 0}, "x", {0, 1})
      second = EditDelta.insertion(1, {0, 1}, "y", {0, 2})
      SyncServer.put_clients(buf, [client], sync.table)

      flush_batch(sync, buf, [
        changed_event(buf, first, EditSource.user(), 2),
        changed_event(buf, nil, EditSource.unknown(), 2),
        changed_event(buf, nil, EditSource.unknown(), 1),
        changed_event(buf, second, EditSource.user(), 3)
      ])

      assert_receive {:client_cast, ^client, {:did_change_incremental, uri, changes, ^buf, 3}},
                     1_000

      assert uri == SyncServer.path_to_uri(path)
      assert changes == [{0, 0, 0, 0, "x"}, {0, 1, 0, 1, "y"}]
    end

    test "request admission flushes the latest revision before registering the request", %{
      tmp_dir: dir,
      sync: sync
    } do
      path = Path.join(dir, "admission.txt")
      File.write!(path, "hello")
      buf = start_buffer(sync, file_path: path)
      client = start_client(:full)
      SyncServer.put_clients(buf, [client], sync.table)

      delta = EditDelta.insertion(0, {0, 0}, "x", {0, 1})

      Events.broadcast(
        :buffer_changed,
        changed_event(buf, delta, EditSource.user(), 4),
        sync.events
      )

      assert {:ok, ref, context} =
               SyncServer.request_document(
                 buf,
                 client,
                 BufferProcess.version(buf),
                 "textDocument/hover",
                 %{"textDocument" => %{"uri" => SyncServer.path_to_uri(path)}},
                 sync.name
               )

      assert_receive {:client_cast, ^client, {:did_change, _uri, "hello", ^buf, 0}}
      assert_receive {:client_document_request, ^client, "textDocument/hover", ^ref}
      assert context.client == client
      assert context.buffer == buf
      assert context.buffer_revision == 0
    end

    test "request through a replaced client still flushes the attached client", %{
      tmp_dir: dir,
      sync: sync
    } do
      path = Path.join(dir, "replaced.txt")
      File.write!(path, "hello")
      buf = start_buffer(sync, file_path: path)
      replaced = start_client(:full)
      attached = start_client(:full)
      SyncServer.put_clients(buf, [attached], sync.table)

      revision = BufferProcess.version(buf)

      # Seed a pending full sync without a debounce timer that could flush independently.
      :sys.replace_state(sync.name, fn state ->
        %{state | pending_changes: Map.put(state.pending_changes, buf, {revision, :full_sync})}
      end)

      assert {:error, :client_replaced} =
               SyncServer.request_document(
                 buf,
                 replaced,
                 revision,
                 "textDocument/hover",
                 %{},
                 sync.name
               )

      assert_receive {:client_cast, ^attached, {:did_change, _uri, "hello", ^buf, ^revision}}
    end

    test "a bulk event keeps a batch in full sync after a later incremental edit", %{
      tmp_dir: dir,
      sync: sync
    } do
      path = Path.join(dir, "bulk.txt")
      File.write!(path, "hello")
      buf = start_buffer(sync, file_path: path)
      client = start_client(:incremental)
      delta = EditDelta.insertion(0, {0, 0}, "x", {0, 1})
      SyncServer.put_clients(buf, [client], sync.table)

      flush_batch(sync, buf, [
        changed_event(buf, delta, EditSource.user(), 1),
        changed_event(buf, nil, EditSource.unknown(), 2),
        changed_event(buf, delta, EditSource.user(), 3)
      ])

      assert_receive {:client_cast, ^client, message}, 1_000
      assert message == {:did_change, SyncServer.path_to_uri(path), "hello", buf, 0}
    end

    test "UTF-16 and UTF-32 clients receive exact full content before request admission", %{
      tmp_dir: dir,
      sync: sync
    } do
      for encoding <- [:utf16, :utf32] do
        path = Path.join(dir, "#{encoding}-non-bmp.txt")
        File.write!(path, "😀a")
        buf = start_buffer(sync, file_path: path)
        client = start_client(:incremental, encoding)
        SyncServer.put_clients(buf, [client], sync.table)

        :ok = BufferProcess.move_to(buf, {0, 4})
        :ok = BufferProcess.insert_text(buf, "x")
        revision = BufferProcess.version(buf)

        assert {:ok, ref, context} =
                 SyncServer.request_document(
                   buf,
                   client,
                   revision,
                   "textDocument/hover",
                   %{"textDocument" => %{"uri" => SyncServer.path_to_uri(path)}},
                   sync.name
                 )

        assert_receive {:client_cast, ^client, {:did_change, _uri, "😀xa", ^buf, ^revision}}

        refute_receive {:client_cast, ^client, {:did_change_incremental, _, _, _, _}}
        assert_receive {:client_document_request, ^client, "textDocument/hover", ^ref}
        assert context.encoding == encoding
        assert context.buffer_revision == revision
      end
    end

    test "mixed clients receive one exact Unicode revision per flush", %{tmp_dir: dir, sync: sync} do
      path = Path.join(dir, "mixed.txt")
      File.write!(path, "😀é!\nz")
      buf = start_buffer(sync, file_path: path)
      full = start_client(:full)
      utf16 = start_client(:incremental, :utf16)
      utf8 = start_client(:incremental, :utf8)
      utf32 = start_client(:incremental, :utf32)
      full_sync_clients = [full, utf16, utf32]
      SyncServer.put_clients(buf, [full, utf16, utf8, utf32], sync.table)

      :ok = BufferProcess.move_to(buf, {0, 6})
      :ok = BufferProcess.insert_text(buf, "ß")
      first_revision = BufferProcess.version(buf)
      assert BufferProcess.content(buf) == "😀éß!\nz"

      assert_receive {:client_cast, ^utf8,
                      {:did_change_incremental, uri, [{0, 6, 0, 6, "ß"}], ^buf, ^first_revision}},
                     1_000

      assert uri == SyncServer.path_to_uri(path)

      for client <- full_sync_clients do
        assert_receive {:client_cast, ^client,
                        {:did_change, ^uri, "😀éß!\nz", ^buf, ^first_revision}},
                       1_000
      end

      refute_receive {:client_cast, _client, _message}, 50

      :ok = BufferProcess.move_to(buf, {1, 0})
      :ok = BufferProcess.insert_text(buf, "日本")
      second_revision = BufferProcess.version(buf)
      assert second_revision > first_revision

      assert_receive {:client_cast, ^utf8,
                      {:did_change_incremental, ^uri, [{1, 0, 1, 0, "日本"}], ^buf,
                       ^second_revision}},
                     1_000

      for client <- full_sync_clients do
        assert_receive {:client_cast, ^client,
                        {:did_change, ^uri, "😀éß!\n日本z", ^buf, ^second_revision}},
                       1_000
      end

      refute_receive {:client_cast, _client, _message}, 50
    end

    test "dead clients do not prevent live mixed clients from receiving changes", %{
      tmp_dir: dir,
      sync: sync
    } do
      path = Path.join(dir, "dead-clients.txt")
      File.write!(path, "naïve 😀")
      buf = start_buffer(sync, file_path: path)
      dead_full = start_client(:full)
      dead_incremental = start_client(:incremental)
      incremental = start_client(:incremental)
      utf16 = start_client(:incremental, :utf16)
      Enum.each([dead_full, dead_incremental], &kill_client/1)
      SyncServer.put_clients(buf, [dead_full, dead_incremental, incremental, utf16], sync.table)

      :ok = BufferProcess.insert_text(buf, "¡")
      edit_revision = BufferProcess.version(buf)

      assert_receive {:client_cast, ^incremental,
                      {:did_change_incremental, _uri, [{0, 0, 0, 0, "¡"}], ^buf, ^edit_revision}},
                     1_000

      assert_receive {:client_cast, ^utf16,
                      {:did_change, _uri, "¡naïve 😀", ^buf, ^edit_revision}},
                     1_000

      :ok = BufferProcess.replace_content(buf, "fin ✓")
      replace_revision = BufferProcess.version(buf)

      for client <- [incremental, utf16] do
        assert_receive {:client_cast, ^client,
                        {:did_change, _uri, "fin ✓", ^buf, ^replace_revision}},
                       1_000
      end

      refute_receive {:client_cast, _client, {:did_change_incremental, _, _, _, _}}, 50
    end

    test "a buffer closed before its flush notifies no client", %{tmp_dir: dir, sync: sync} do
      path = Path.join(dir, "closed.txt")
      File.write!(path, "hello")
      buf = start_supervised!({BufferProcess, file_path: path}, id: :closing_buffer)
      full = start_client(:full)
      incremental = start_client(:incremental)
      SyncServer.put_clients(buf, [full, incremental], sync.table)
      delta = EditDelta.insertion(0, {0, 0}, "x", {0, 1})

      Events.broadcast(
        :buffer_changed,
        changed_event(buf, delta, EditSource.user(), 1),
        sync.events
      )

      sync_server(sync)
      :ok = stop_supervised!(:closing_buffer)

      refute_receive {:client_cast, _client, _message}, 400
      refute Map.has_key?(:sys.get_state(sync.name).pending_changes, buf)
    end
  end

  describe "restart reconstruction" do
    test "stale ETS entries do not survive SyncServer restart", %{tmp_dir: dir, sync: sync} do
      path = Path.join(dir, "stale.txt")
      buf = start_buffer(sync, content: "hello", file_path: path)
      stale_client = start_client()
      SyncServer.put_clients(buf, [stale_client], sync.table)
      assert SyncServer.clients_for_buffer(buf, sync.table) == [stale_client]

      restart_sync_server(sync)

      assert SyncServer.clients_for_buffer(buf, sync.table) == []
    end

    test "stale pending_changes and monitors do not survive restart", %{tmp_dir: dir, sync: sync} do
      path = Path.join(dir, "pending.txt")
      buf = start_buffer(sync, content: "hello", file_path: path)
      client = start_client()
      SyncServer.put_clients(buf, [client], sync.table)
      _ref = monitor_client_in_sync_server(sync, buf, client)

      :sys.replace_state(sync.name, fn state ->
        %{state | pending_changes: Map.put(state.pending_changes, buf, {1, :full_sync})}
      end)

      restart_sync_server(sync)

      state = :sys.get_state(sync.name)
      assert state.pending_changes == %{}
      assert state.client_monitors == %{}
      assert state.debounce_timers == %{}
    end

    test "edit synchronization works after restart with reattached clients", %{
      tmp_dir: dir,
      sync: sync
    } do
      path = Path.join(dir, "sync-after-restart.txt")
      File.write!(path, "hello")
      buf = start_buffer(sync, file_path: path)
      client = start_client(:incremental)

      restart_sync_server(sync)

      # Reattach the client (simulates what reconstruction does when servers are available)
      SyncServer.put_clients(buf, [client], sync.table)

      delta = EditDelta.insertion(0, {0, 0}, "x", {0, 1})

      flush_batch(sync, buf, [
        changed_event(buf, delta, EditSource.user(), 1)
      ])

      assert_receive {:client_cast, ^client,
                      {:did_change_incremental, _uri, [{0, 0, 0, 0, "x"}], ^buf, 1}},
                     1_000
    end

    test "request_document rejects stale client identity after restart", %{
      tmp_dir: dir,
      sync: sync
    } do
      path = Path.join(dir, "stale-request.txt")
      File.write!(path, "hello")
      buf = start_buffer(sync, file_path: path)
      stale_client = start_client(:full)
      SyncServer.put_clients(buf, [stale_client], sync.table)

      restart_sync_server(sync)

      # The stale client is no longer in the reconstructed ETS
      revision = BufferProcess.version(buf)

      assert {:error, :client_replaced} =
               SyncServer.request_document(
                 buf,
                 stale_client,
                 revision,
                 "textDocument/hover",
                 %{},
                 sync.name
               )
    end
  end

  describe "client monitoring" do
    test "client DOWN removes it while survivors remain", %{tmp_dir: dir, sync: sync} do
      path = Path.join(dir, "monitor.txt")
      File.write!(path, "hello")
      buf = start_buffer(sync, file_path: path)
      doomed = start_client()
      survivor = start_client()
      SyncServer.put_clients(buf, [doomed, survivor], sync.table)
      monitor_ref = monitor_client_in_sync_server(sync, buf, doomed)

      send(sync.name, {:DOWN, monitor_ref, :process, doomed, :killed})
      sync_server(sync)

      assert SyncServer.clients_for_buffer(buf, sync.table) == [survivor]
    end
  end

  defp start_buffer(sync, opts) do
    start_supervised!({BufferProcess, [events_registry: sync.events] ++ opts},
      id: {:buffer, make_ref()}
    )
  end

  defp changed_event(buf, delta, source, version) do
    %Events.BufferChangedEvent{
      sequence: version,
      buffer: buf,
      source: source,
      delta: delta,
      version: version
    }
  end

  defp flush_batch(sync, buf, events) do
    :ok = :sys.suspend(sync.name)

    try do
      Enum.each(events, &send(sync.name, {:minga_event, :buffer_changed, &1}))
      send(sync.name, {:flush_did_change, buf})
    after
      :sys.resume(sync.name)
    end
  end

  defp observe_buffer_call(parent, {:in, {:"$gen_call", _from, request}}, _state) do
    send(parent, {:observed_buffer_call, request})
    parent
  end

  defp observe_buffer_call(parent, _event, _state), do: parent

  defp start_client(sync_kind \\ :full, encoding \\ :utf8) do
    parent = self()
    pid = spawn(fn -> client_loop(parent, sync_kind, encoding) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp kill_client(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp client_loop(parent, sync_kind, encoding) do
    receive do
      {:"$gen_call", from, :sync_kind} ->
        GenServer.reply(from, sync_kind)
        client_loop(parent, sync_kind, encoding)

      {:"$gen_call", from, :encoding} ->
        GenServer.reply(from, encoding)
        client_loop(parent, sync_kind, encoding)

      {:"$gen_call", from,
       {:request_document, uri, buffer, revision, method, _params, _content, _caller, ref}} ->
        context = %Minga.LSP.DocumentContext{
          client: self(),
          buffer: buffer,
          uri: uri,
          buffer_revision: revision,
          lsp_version: 2,
          encoding: encoding
        }

        send(parent, {:client_document_request, self(), method, ref})
        GenServer.reply(from, {:ok, ref, context})
        client_loop(parent, sync_kind, encoding)

      {:"$gen_cast", message} ->
        send(parent, {:client_cast, self(), message})
        client_loop(parent, sync_kind, encoding)

      _message ->
        client_loop(parent, sync_kind, encoding)
    end
  end

  defp monitor_client_in_sync_server(sync, buf, client) do
    parent = self()

    :sys.replace_state(sync.name, fn state ->
      ref = Process.monitor(client)
      send(parent, {:sync_server_monitor, ref})
      entry = {buf, client, {:test_server, "/test-root"}}
      %{state | client_monitors: Map.put(state.client_monitors, ref, entry)}
    end)

    assert_receive {:sync_server_monitor, ref}
    ref
  end

  defp start_sync_server(sync) do
    start_supervised!(
      {SyncServer,
       name: sync.name,
       table: sync.table,
       events_registry: sync.events,
       buffer_registry: sync.buffers,
       options_server: sync.options,
       lsp_supervisor: sync.lsp_supervisor},
      id: :sync_server
    )
  end

  defp sync_server(sync) do
    :sys.get_state(sync.name)
    :ok
  end

  # Stops this test's SyncServer, which deletes its ETS table, and starts a fresh one that
  # reconstructs its attachments in init/1.
  defp restart_sync_server(sync) do
    :ok = stop_supervised!(:sync_server)
    start_sync_server(sync)
    sync_server(sync)
  end
end
