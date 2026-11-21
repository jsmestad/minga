defmodule Minga.LSP.SyncServerTest do
  # async: false because this test isolates the shared SyncServer singleton and ETS registry.
  use ExUnit.Case, async: false

  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias Minga.Events
  alias Minga.LSP.ServerRegistry
  alias Minga.LSP.SyncServer

  @moduletag :tmp_dir

  setup do
    reset_sync_server()
    :ok
  end

  describe "clients_for_buffer/1" do
  end

  describe "resync_buffers/1" do
  end

  describe "event bus integration" do
    test "opening a file with no configured server does not read its content", %{tmp_dir: dir} do
      path = Path.join(dir, "no-server.txt")
      File.write!(path, "hello")
      buf = start_buffer(file_path: path, filetype: :text)
      assert ServerRegistry.servers_for(BufferProcess.filetype(buf)) == []
      previous = Options.get(:lsp_auto_start)

      :ok = :sys.install(buf, {:open_reads, &observe_buffer_call/3, self()})

      try do
        assert {:ok, true} = Options.set(:lsp_auto_start, true)

        send(
          SyncServer,
          {:minga_event, :buffer_opened, %Events.BufferEvent{buffer: buf, path: path}}
        )

        sync_server()
      after
        Options.set(:lsp_auto_start, previous)
        :sys.remove(buf, :open_reads)
      end

      assert_received {:observed_buffer_call, :filetype}
      assert_received {:observed_buffer_call, :file_path}
      refute_received {:observed_buffer_call, :content_with_version}
    end

    test "buffer_closed removes clients from the registry", %{tmp_dir: dir} do
      path = Path.join(dir, "cleanup.txt")
      buf = start_buffer(content: "hello", file_path: path)
      client = start_client()
      SyncServer.put_clients(buf, [client])
      assert SyncServer.clients_for_buffer(buf) == [client]

      Events.broadcast(:buffer_closed, %Events.BufferClosedEvent{buffer: buf, path: path})
      sync_server()

      assert SyncServer.clients_for_buffer(buf) == []
    end
  end

  describe "buffer_changed event" do
    test "sends ordered incremental deltas and ignores stale bulk events", %{tmp_dir: dir} do
      path = Path.join(dir, "incremental.txt")
      File.write!(path, "hello")
      buf = start_buffer(file_path: path)
      client = start_client(:incremental)
      first = EditDelta.insertion(0, {0, 0}, "x", {0, 1})
      second = EditDelta.insertion(1, {0, 1}, "y", {0, 2})
      SyncServer.put_clients(buf, [client])

      flush_batch(buf, [
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
      tmp_dir: dir
    } do
      path = Path.join(dir, "admission.txt")
      File.write!(path, "hello")
      buf = start_buffer(file_path: path)
      client = start_client(:full)
      SyncServer.put_clients(buf, [client])

      delta = EditDelta.insertion(0, {0, 0}, "x", {0, 1})
      Events.broadcast(:buffer_changed, changed_event(buf, delta, EditSource.user(), 4))

      assert {:ok, ref, context} =
               SyncServer.request_document(
                 buf,
                 client,
                 BufferProcess.version(buf),
                 "textDocument/hover",
                 %{"textDocument" => %{"uri" => SyncServer.path_to_uri(path)}}
               )

      assert_receive {:client_cast, ^client, {:did_change, _uri, "hello", ^buf, 0}}
      assert_receive {:client_document_request, ^client, "textDocument/hover", ^ref}
      assert context.client == client
      assert context.buffer == buf
      assert context.buffer_revision == 0
    end

    test "request through a replaced client still flushes the attached client", %{tmp_dir: dir} do
      path = Path.join(dir, "replaced.txt")
      File.write!(path, "hello")
      buf = start_buffer(file_path: path)
      replaced = start_client(:full)
      attached = start_client(:full)
      SyncServer.put_clients(buf, [attached])

      revision = BufferProcess.version(buf)

      # Seed a pending full sync without a debounce timer that could flush independently.
      :sys.replace_state(SyncServer, fn state ->
        %{state | pending_changes: Map.put(state.pending_changes, buf, {revision, :full_sync})}
      end)

      assert {:error, :client_replaced} =
               SyncServer.request_document(
                 buf,
                 replaced,
                 revision,
                 "textDocument/hover",
                 %{}
               )

      assert_receive {:client_cast, ^attached, {:did_change, _uri, "hello", ^buf, ^revision}}
    end

    test "a bulk event keeps a batch in full sync after a later incremental edit", %{tmp_dir: dir} do
      path = Path.join(dir, "bulk.txt")
      File.write!(path, "hello")
      buf = start_buffer(file_path: path)
      client = start_client(:incremental)
      delta = EditDelta.insertion(0, {0, 0}, "x", {0, 1})
      SyncServer.put_clients(buf, [client])

      flush_batch(buf, [
        changed_event(buf, delta, EditSource.user(), 1),
        changed_event(buf, nil, EditSource.unknown(), 2),
        changed_event(buf, delta, EditSource.user(), 3)
      ])

      assert_receive {:client_cast, ^client, message}, 1_000
      assert message == {:did_change, SyncServer.path_to_uri(path), "hello", buf, 0}
    end

    test "UTF-16 and UTF-32 clients receive exact full content before request admission", %{
      tmp_dir: dir
    } do
      for encoding <- [:utf16, :utf32] do
        path = Path.join(dir, "#{encoding}-non-bmp.txt")
        File.write!(path, "😀a")
        buf = start_buffer(file_path: path)
        client = start_client(:incremental, encoding)
        SyncServer.put_clients(buf, [client])

        :ok = BufferProcess.move_to(buf, {0, 4})
        :ok = BufferProcess.insert_text(buf, "x")
        revision = BufferProcess.version(buf)

        assert {:ok, ref, context} =
                 SyncServer.request_document(
                   buf,
                   client,
                   revision,
                   "textDocument/hover",
                   %{"textDocument" => %{"uri" => SyncServer.path_to_uri(path)}}
                 )

        assert_receive {:client_cast, ^client, {:did_change, _uri, "😀xa", ^buf, ^revision}}

        refute_receive {:client_cast, ^client, {:did_change_incremental, _, _, _, _}}
        assert_receive {:client_document_request, ^client, "textDocument/hover", ^ref}
        assert context.encoding == encoding
        assert context.buffer_revision == revision
      end
    end

    test "mixed clients receive one exact Unicode revision per flush", %{tmp_dir: dir} do
      path = Path.join(dir, "mixed.txt")
      File.write!(path, "😀é!\nz")
      buf = start_buffer(file_path: path)
      full = start_client(:full)
      utf16 = start_client(:incremental, :utf16)
      utf8 = start_client(:incremental, :utf8)
      utf32 = start_client(:incremental, :utf32)
      full_sync_clients = [full, utf16, utf32]
      SyncServer.put_clients(buf, [full, utf16, utf8, utf32])

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
      tmp_dir: dir
    } do
      path = Path.join(dir, "dead-clients.txt")
      File.write!(path, "naïve 😀")
      buf = start_buffer(file_path: path)
      dead_full = start_client(:full)
      dead_incremental = start_client(:incremental)
      incremental = start_client(:incremental)
      utf16 = start_client(:incremental, :utf16)
      Enum.each([dead_full, dead_incremental], &kill_client/1)
      SyncServer.put_clients(buf, [dead_full, dead_incremental, incremental, utf16])

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

    test "a buffer closed before its flush notifies no client", %{tmp_dir: dir} do
      path = Path.join(dir, "closed.txt")
      File.write!(path, "hello")
      buf = start_supervised!({BufferProcess, file_path: path}, id: :closing_buffer)
      full = start_client(:full)
      incremental = start_client(:incremental)
      SyncServer.put_clients(buf, [full, incremental])
      delta = EditDelta.insertion(0, {0, 0}, "x", {0, 1})

      Events.broadcast(:buffer_changed, changed_event(buf, delta, EditSource.user(), 1))
      sync_server()
      :ok = stop_supervised!(:closing_buffer)

      refute_receive {:client_cast, _client, _message}, 400
      refute Map.has_key?(:sys.get_state(SyncServer).pending_changes, buf)
    end
  end

  describe "client monitoring" do
    test "client DOWN removes it while survivors remain", %{tmp_dir: dir} do
      path = Path.join(dir, "monitor.txt")
      File.write!(path, "hello")
      buf = start_buffer(file_path: path)
      doomed = start_client()
      survivor = start_client()
      SyncServer.put_clients(buf, [doomed, survivor])
      monitor_ref = monitor_client_in_sync_server(buf, doomed)

      send(SyncServer, {:DOWN, monitor_ref, :process, doomed, :killed})
      sync_server()

      assert SyncServer.clients_for_buffer(buf) == [survivor]
    end
  end

  defp start_buffer(opts) do
    start_supervised!({BufferProcess, opts}, id: {:buffer, make_ref()})
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

  defp flush_batch(buf, events) do
    :ok = :sys.suspend(SyncServer)

    try do
      Enum.each(events, &send(SyncServer, {:minga_event, :buffer_changed, &1}))
      send(SyncServer, {:flush_did_change, buf})
    after
      :sys.resume(SyncServer)
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

  defp monitor_client_in_sync_server(buf, client) do
    parent = self()

    :sys.replace_state(SyncServer, fn state ->
      ref = Process.monitor(client)
      send(parent, {:sync_server_monitor, ref})
      %{state | client_monitors: Map.put(state.client_monitors, ref, {buf, client})}
    end)

    assert_receive {:sync_server_monitor, ref}
    ref
  end

  defp sync_server do
    :sys.get_state(SyncServer)
    :ok
  end

  defp reset_sync_server do
    SyncServer.clear_registry()

    :sys.replace_state(SyncServer, fn state ->
      Enum.each(Map.values(state.debounce_timers), &Process.cancel_timer/1)

      %{
        state
        | debounce_timers: %{},
          client_monitors: %{},
          pending_changes: %{},
          pending_tool_buffers: %{}
      }
    end)
  end
end
