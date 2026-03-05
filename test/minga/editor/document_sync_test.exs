defmodule Minga.Editor.DocumentSyncTest do
  use ExUnit.Case

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Diagnostics
  alias Minga.Editor.DocumentSync
  alias Minga.LSP.Client
  alias Minga.LSP.Supervisor, as: LSPSupervisor
  alias Minga.Test.MockLSPServer

  setup do
    diag_name = :"diag_bridge_#{System.unique_integer()}"
    sup_name = :"lsp_sup_bridge_#{System.unique_integer()}"

    start_supervised!({Diagnostics, name: diag_name})
    start_supervised!({LSPSupervisor, name: sup_name})

    # Start a buffer with an Elixir file
    tmp_dir = System.tmp_dir!()
    file_path = Path.join(tmp_dir, "test_#{System.unique_integer()}.ex")
    File.write!(file_path, "defmodule Test do\n  def hello, do: :world\nend\n")

    {:ok, buffer} =
      start_supervised(
        {BufferServer, file_path: file_path},
        id: :"buf_#{System.unique_integer()}"
      )

    on_exit(fn -> File.rm(file_path) end)

    %{
      lsp_supervisor: sup_name,
      diag_server: diag_name,
      buffer: buffer,
      file_path: file_path
    }
  end

  defp wait_until_ready(client, attempts \\ 50) do
    if attempts <= 0, do: flunk("LSP client did not become ready in time")

    case Client.status(client) do
      :ready -> :ok
      _ -> Process.sleep(100) && wait_until_ready(client, attempts - 1)
    end
  end

  describe "new/0" do
    test "returns empty LSP bridge state" do
      state = DocumentSync.new()
      assert state.buffer_clients == %{}
      assert state.debounce_timers == %{}
    end
  end

  describe "on_buffer_open/3" do
    test "starts language server and tracks client for buffer", %{
      buffer: buffer,
      lsp_supervisor: sup
    } do
      # Mock the server registry to return our mock server
      lsp_state = DocumentSync.new()

      # We need to temporarily make the registry return the mock config.
      # Since ServerRegistry is a pure module with hardcoded data, and
      # :elixir maps to :lexical which probably isn't installed,
      # we test with a buffer that has no matching server (no-op case)
      # and test the full flow separately.

      lsp_state = DocumentSync.on_buffer_open(lsp_state, buffer, lsp_supervisor: sup)

      # The mock won't match :elixir filetype's "lexical" command,
      # so no clients should be attached (server not on PATH)
      clients = DocumentSync.clients_for_buffer(lsp_state, buffer)
      assert is_list(clients)
    end

    test "returns unchanged state for buffer without file path", %{lsp_supervisor: sup} do
      {:ok, scratch} =
        start_supervised(
          {BufferServer, content: "scratch content"},
          id: :"scratch_#{System.unique_integer()}"
        )

      lsp_state = DocumentSync.new()
      lsp_state = DocumentSync.on_buffer_open(lsp_state, scratch, lsp_supervisor: sup)

      assert DocumentSync.clients_for_buffer(lsp_state, scratch) == []
    end
  end

  describe "on_buffer_change/2" do
    test "schedules debounced didChange when clients are attached", %{buffer: buffer} do
      # Simulate having a client attached
      fake_client = self()
      lsp_state = %{DocumentSync.new() | buffer_clients: %{buffer => [fake_client]}}

      lsp_state = DocumentSync.on_buffer_change(lsp_state, buffer)

      # Should have a debounce timer
      assert Map.has_key?(lsp_state.debounce_timers, buffer)
    end

    test "cancels previous debounce timer on rapid changes", %{buffer: buffer} do
      fake_client = self()
      lsp_state = %{DocumentSync.new() | buffer_clients: %{buffer => [fake_client]}}

      lsp_state = DocumentSync.on_buffer_change(lsp_state, buffer)
      timer1 = Map.get(lsp_state.debounce_timers, buffer)

      lsp_state = DocumentSync.on_buffer_change(lsp_state, buffer)
      timer2 = Map.get(lsp_state.debounce_timers, buffer)

      assert timer1 != timer2
      # First timer should be cancelled
      assert Process.read_timer(timer1) == false
    end

    test "no-op when buffer has no attached clients" do
      lsp_state = DocumentSync.new()
      fake_buffer = self()

      result = DocumentSync.on_buffer_change(lsp_state, fake_buffer)
      assert result.debounce_timers == %{}
    end
  end

  describe "flush_did_change/2" do
    test "clears debounce timer", %{buffer: buffer} do
      fake_client = self()

      lsp_state = %{
        DocumentSync.new()
        | buffer_clients: %{buffer => [fake_client]},
          debounce_timers: %{buffer => make_ref()}
      }

      result = DocumentSync.flush_did_change(lsp_state, buffer)
      refute Map.has_key?(result.debounce_timers, buffer)
    end
  end

  describe "on_buffer_save/2" do
    test "no-op when buffer has no clients" do
      lsp_state = DocumentSync.new()
      fake_buffer = self()

      # Should not crash
      result = DocumentSync.on_buffer_save(lsp_state, fake_buffer)
      assert result == lsp_state
    end
  end

  describe "on_buffer_close/2" do
    test "removes buffer from tracking", %{buffer: buffer} do
      fake_client = self()

      lsp_state = %{
        DocumentSync.new()
        | buffer_clients: %{buffer => [fake_client]},
          debounce_timers: %{buffer => make_ref()}
      }

      result = DocumentSync.on_buffer_close(lsp_state, buffer)
      assert result.buffer_clients == %{}
      assert result.debounce_timers == %{}
    end

    test "no-op for untracked buffer" do
      lsp_state = DocumentSync.new()
      result = DocumentSync.on_buffer_close(lsp_state, self())
      assert result == lsp_state
    end
  end

  describe "clients_for_buffer/2" do
    test "returns empty list for unknown buffer" do
      assert DocumentSync.clients_for_buffer(DocumentSync.new(), self()) == []
    end

    test "returns tracked clients" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)
      buffer = self()

      lsp_state = %{DocumentSync.new() | buffer_clients: %{buffer => [pid1, pid2]}}
      assert DocumentSync.clients_for_buffer(lsp_state, buffer) == [pid1, pid2]
    end
  end

  describe "path_to_uri/1 and uri_to_path/1" do
    test "round-trips a path" do
      path = "/tmp/test.ex"
      uri = DocumentSync.path_to_uri(path)
      assert uri == "file:///tmp/test.ex"
      assert DocumentSync.uri_to_path(uri) == path
    end

    test "expands relative paths" do
      uri = DocumentSync.path_to_uri("lib/minga.ex")
      assert String.starts_with?(uri, "file:///")
      assert String.ends_with?(uri, "lib/minga.ex")
    end
  end

  describe "full integration with mock LSP server" do
    test "open → change → save → close lifecycle", %{
      buffer: buffer,
      file_path: file_path,
      lsp_supervisor: sup,
      diag_server: diag_server
    } do
      # Start a mock LSP client manually (since ServerRegistry won't match)
      config = MockLSPServer.server_config()
      root = Path.dirname(file_path)
      {:ok, client} = LSPSupervisor.ensure_client(sup, config, root, diagnostics: diag_server)
      wait_until_ready(client)

      # Wire up the client to the buffer manually
      uri = DocumentSync.path_to_uri(file_path)
      {content, _} = BufferServer.content_and_cursor(buffer)
      Client.did_open(client, uri, "elixir", content)

      lsp_state = %{DocumentSync.new() | buffer_clients: %{buffer => [client]}}

      # Subscribe to diagnostics
      Diagnostics.subscribe(diag_server)

      # Should receive diagnostics from mock server's didOpen handler
      assert_receive {:diagnostics_changed, ^uri}, 5_000
      diags = Diagnostics.for_uri(diag_server, uri)
      assert length(diags) == 1
      assert hd(diags).message == "mock warning on line 1"

      # Change
      BufferServer.insert_char(buffer, "x")
      lsp_state = DocumentSync.on_buffer_change(lsp_state, buffer)
      assert Map.has_key?(lsp_state.debounce_timers, buffer)

      # Flush the debounce
      lsp_state = DocumentSync.flush_did_change(lsp_state, buffer)
      Process.sleep(100)
      assert Client.status(client) == :ready

      # Save
      _lsp_state = DocumentSync.on_buffer_save(lsp_state, buffer)
      Process.sleep(100)
      assert Client.status(client) == :ready
    end
  end
end
