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
  end

  describe "resync_buffers/1" do
  end

  describe "event bus integration" do
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
    test "sends accumulated deltas incrementally in document order", %{tmp_dir: dir} do
      path = Path.join(dir, "incremental.txt")
      File.write!(path, "hello")
      buf = start_buffer(file_path: path)
      client = start_client(:incremental)
      first = EditDelta.insertion(0, {0, 0}, "x", {0, 1})
      second = EditDelta.insertion(1, {0, 1}, "y", {0, 2})
      SyncServer.put_clients(buf, [client])

      Events.broadcast(:buffer_changed, changed_event(buf, first, EditSource.user(), 1))
      Events.broadcast(:buffer_changed, changed_event(buf, second, EditSource.user(), 2))

      assert_receive {:client_cast, ^client, {:did_change_incremental, uri, changes, ^buf, 2}},
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

    test "nil delta falls back to full sync even for incremental clients", %{tmp_dir: dir} do
      path = Path.join(dir, "bulk.txt")
      File.write!(path, "hello")
      buf = start_buffer(file_path: path)
      client = start_client(:incremental)
      delta = EditDelta.insertion(0, {0, 0}, "x", {0, 1})
      SyncServer.put_clients(buf, [client])

      Events.broadcast(:buffer_changed, changed_event(buf, delta, EditSource.user(), 1))
      Events.broadcast(:buffer_changed, changed_event(buf, nil, EditSource.unknown(), 2))

      assert_receive {:client_cast, ^client, {:did_change, uri, "hello", ^buf, 0}}, 1_000
      assert uri == SyncServer.path_to_uri(path)
      refute_receive {:client_cast, ^client, {:did_change_incremental, _, _}}, 50
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

  defp start_client(sync_kind \\ :full, encoding \\ :utf8) do
    parent = self()
    pid = spawn(fn -> client_loop(parent, sync_kind, encoding) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
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
          delta_accumulators: %{},
          pending_revisions: %{},
          pending_tool_buffers: %{}
      }
    end)
  end
end
