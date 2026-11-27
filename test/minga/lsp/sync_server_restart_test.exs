defmodule Minga.LSP.SyncServerRestartTest do
  # async: false because MockLSPServer spawns OS processes that can race under heavy parallel load.
  use ExUnit.Case, async: false

  @moduletag :heavy
  @moduletag :tmp_dir

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias Minga.Diagnostics
  alias Minga.Events
  alias Minga.LSP.Client
  alias Minga.LSP.RootDetector
  alias Minga.LSP.Supervisor, as: LSPSupervisor
  alias Minga.LSP.SyncServer
  alias Minga.Test.MockLSPServer

  @response_timeout 10_000
  @filetype :sync_restart_mock
  @root_marker "sync-restart-root"

  # Each test owns its LSP supervisor, diagnostics store, event bus, options and SyncServer.
  # A restart or a client crash here never touches the application's singletons.
  setup %{tmp_dir: dir} = context do
    id = System.unique_integer([:positive])
    events = :"sync_restart_events_#{id}"
    start_supervised!(Events.child_spec(name: events))
    options = start_supervised!({Options, name: nil, events_registry: events}, id: :options)
    {:ok, true} = Options.set(options, :lsp_auto_start, true)
    diagnostics = start_supervised!({Diagnostics, name: :"sync_restart_diag_#{id}"})
    lsp_supervisor = :"sync_restart_lsp_#{id}"
    start_supervised!({LSPSupervisor, name: lsp_supervisor})

    File.write!(Path.join(dir, @root_marker), "")
    incremental_sync = Map.get(context, :incremental_sync, false)
    server_config = MockLSPServer.server_config(incremental_sync: incremental_sync)
    config = %{server_config | root_markers: [@root_marker]}
    path = Path.join(dir, "document.txt")
    File.write!(path, "hello")
    root = RootDetector.find_root(path, config.root_markers)

    {:ok, client} =
      LSPSupervisor.ensure_client(lsp_supervisor, config, root, diagnostics: diagnostics)

    await_ready(client)

    sync = %{
      name: :"sync_restart_server_#{id}",
      table: :"sync_restart_registry_#{id}",
      events: events,
      options: options,
      lsp_supervisor: lsp_supervisor,
      config: config
    }

    start_sync_server(sync)

    buffer =
      start_supervised!(
        {BufferProcess, events_registry: events, file_path: path, filetype: @filetype},
        id: :buffer
      )

    Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buffer, path: path}, events)
    sync_server(sync)
    assert SyncServer.clients_for_buffer(buffer, sync.table) == [client]

    %{sync: sync, client: client, buffer: buffer, uri: SyncServer.path_to_uri(path)}
  end

  describe "SyncServer restart" do
    test "reattaches every open buffer to the surviving client without reopening documents",
         ctx do
      %{sync: sync, client: client, buffer: buffer, uri: uri, tmp_dir: dir} = ctx
      other_path = Path.join(dir, "other.txt")
      File.write!(other_path, "other")

      other =
        start_supervised!(
          {BufferProcess,
           events_registry: sync.events, file_path: other_path, filetype: @filetype},
          id: :other_buffer
        )

      Events.broadcast(
        :buffer_opened,
        %Events.BufferEvent{buffer: other, path: other_path},
        sync.events
      )

      restart_sync_server(sync)

      assert SyncServer.clients_for_buffer(buffer, sync.table) == [client]
      assert SyncServer.clients_for_buffer(other, sync.table) == [client]

      :ok = BufferProcess.insert_text(buffer, "x")
      :ok = BufferProcess.insert_text(other, "y")
      flush_changes(sync, buffer, client)
      flush_changes(sync, other, client)

      for {doc_buffer, doc_uri} <- [{buffer, uri}, {other, SyncServer.path_to_uri(other_path)}] do
        assert transcript_versions(client, doc_uri) == [
                 {"textDocument/didOpen", 1},
                 {"textDocument/didChange", 2}
               ]

        assert server_text(client, doc_uri) == BufferProcess.content(doc_buffer)
      end
    end

    test "synchronizes edits made while SyncServer was down with an increasing version", ctx do
      %{sync: sync, client: client, buffer: buffer, uri: uri} = ctx

      :ok = stop_supervised!(:sync_server)
      :ok = BufferProcess.insert_text(buffer, "a")
      start_sync_server(sync)
      sync_server(sync)

      assert SyncServer.clients_for_buffer(buffer, sync.table) == [client]

      :ok = BufferProcess.insert_text(buffer, "b")
      flush_changes(sync, buffer, client)

      assert transcript_versions(client, uri) == [
               {"textDocument/didOpen", 1},
               {"textDocument/didChange", 2},
               {"textDocument/didChange", 3}
             ]

      assert server_text(client, uri) == BufferProcess.content(buffer)
    end

    test "the reconstructed attachment monitors the client again", ctx do
      %{sync: sync, client: client, buffer: buffer} = ctx

      restart_sync_server(sync)
      ref = Process.monitor(client)
      :ok = DynamicSupervisor.terminate_child(sync.lsp_supervisor, client)
      assert_receive {:DOWN, ^ref, :process, ^client, _reason}

      assert_clients_eventually(sync, buffer, [])
    end
  end

  describe "client framing-limit failure" do
    @tag :capture_log
    test "the replacement client reopens attached documents with current content", ctx do
      %{sync: sync, client: client, buffer: buffer, uri: uri} = ctx

      :ok = BufferProcess.insert_text(buffer, "x")
      flush_changes(sync, buffer, client)

      ref = Process.monitor(client)
      _request = Client.request(client, "mock/oversized_frame", %{})

      assert_receive {:DOWN, ^ref, :process, ^client,
                      {:framing_error, {:body_too_large, 60_000_000}}},
                     @response_timeout

      replacement = await_replacement(sync, buffer, client)
      await_ready(replacement)

      :ok = BufferProcess.insert_text(buffer, "y")
      flush_changes(sync, buffer, replacement)

      assert transcript_versions(replacement, uri) == [
               {"textDocument/didOpen", 1},
               {"textDocument/didChange", 2}
             ]

      assert server_text(replacement, uri) == BufferProcess.content(buffer)
    end

    @tag :capture_log
    @tag incremental_sync: true
    test "edits queued before the failure are not sent twice to the replacement", ctx do
      %{sync: sync, client: client, buffer: buffer, uri: uri} = ctx

      :ok = BufferProcess.insert_text(buffer, "a")
      hold_queued_change(sync, buffer)

      ref = Process.monitor(client)
      _request = Client.request(client, "mock/oversized_frame", %{})

      assert_receive {:DOWN, ^ref, :process, ^client,
                      {:framing_error, {:body_too_large, 60_000_000}}},
                     @response_timeout

      replacement = await_replacement(sync, buffer, client)
      await_ready(replacement)

      :ok = BufferProcess.insert_text(buffer, "b")
      flush_changes(sync, buffer, replacement)

      events =
        for %{"uri" => ^uri} = event <- transcript(replacement)["events"],
            do: {event["method"], event["version"], event["changeKind"]}

      assert events == [
               {"textDocument/didOpen", 1, nil},
               {"textDocument/didChange", 2, "incremental"}
             ]

      assert server_text(replacement, uri) == BufferProcess.content(buffer)
    end
  end

  # Keeps the buffer's latest change queued in SyncServer by canceling its debounce timer.
  # The queue then outlives the client failure, as it does when the failure beats the debounce.
  defp hold_queued_change(sync, buffer, attempts \\ 200) do
    if Map.has_key?(:sys.get_state(sync.name).pending_changes, buffer) do
      :sys.replace_state(sync.name, &cancel_debounce(&1, buffer))

      assert Map.has_key?(:sys.get_state(sync.name).pending_changes, buffer)
    else
      assert attempts > 0, "the edit never reached SyncServer"

      receive do
      after
        5 -> hold_queued_change(sync, buffer, attempts - 1)
      end
    end
  end

  defp cancel_debounce(state, buffer) do
    {timer, timers} = Map.pop(state.debounce_timers, buffer)
    if timer, do: Process.cancel_timer(timer)
    %{state | debounce_timers: timers}
  end

  defp start_sync_server(sync) do
    config = sync.config

    start_supervised!(
      {SyncServer,
       name: sync.name,
       table: sync.table,
       events_registry: sync.events,
       options_server: sync.options,
       lsp_supervisor: sync.lsp_supervisor,
       servers_for: fn
         @filetype -> [config]
         _filetype -> []
       end},
      id: :sync_server
    )
  end

  defp restart_sync_server(sync) do
    :ok = stop_supervised!(:sync_server)
    start_sync_server(sync)
    sync_server(sync)
  end

  defp sync_server(sync) do
    :sys.get_state(sync.name)
    :ok
  end

  # Flushes the debounced change now, then waits until the client wrote it to the server.
  defp flush_changes(sync, buffer, client) do
    sync_server(sync)
    send(sync.name, {:flush_did_change, buffer})
    sync_server(sync)
    :sys.get_state(client)
    :ok
  end

  defp transcript(client) do
    ref = Client.request(client, "mock/transcript", %{})
    assert_receive {:lsp_response, ^ref, {:ok, transcript}}, @response_timeout
    transcript
  end

  defp transcript_versions(client, uri) do
    for %{"uri" => ^uri} = event <- transcript(client)["events"],
        do: {event["method"], event["version"]}
  end

  defp server_text(client, uri) do
    transcript(client)["documents"][uri]["text"]
  end

  defp await_replacement(sync, buffer, old_client, attempts \\ 200) do
    case SyncServer.clients_for_buffer(buffer, sync.table) do
      [replacement] when replacement != old_client ->
        replacement

      clients when attempts > 0 ->
        _ = clients

        receive do
        after
          10 -> await_replacement(sync, buffer, old_client, attempts - 1)
        end

      clients ->
        flunk("expected a replacement client attachment, got #{inspect(clients)}")
    end
  end

  defp assert_clients_eventually(sync, buffer, expected, attempts \\ 200) do
    case SyncServer.clients_for_buffer(buffer, sync.table) do
      ^expected ->
        :ok

      _clients when attempts > 0 ->
        receive do
        after
          10 -> assert_clients_eventually(sync, buffer, expected, attempts - 1)
        end

      clients ->
        assert clients == expected
    end
  end

  # Polls the client's own status, so a readiness event from an earlier client cannot satisfy the wait.
  defp await_ready(client, attempts \\ 500) do
    case Client.status(client) do
      :ready ->
        :ok

      status when attempts > 0 ->
        _ = status

        receive do
        after
          20 -> await_ready(client, attempts - 1)
        end

      status ->
        flunk("client never became ready, last status #{inspect(status)}")
    end
  end
end
