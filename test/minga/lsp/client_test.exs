defmodule Minga.LSP.ClientTest do
  # async: false because mock LSP server spawns OS processes that may not
  # start in time under heavy parallel test load
  use ExUnit.Case, async: false

  # OS process startup (MockLSPServer) makes these inherently slow (~250ms each).
  # Excluded from test.llm; runs in test.heavy and full suite.
  @moduletag :heavy

  alias Minga.Diagnostics
  alias Minga.LSP.Client
  alias Minga.Test.MockLSPServer

  @ready_timeout 10_000

  setup context do
    diag_server = start_supervised!({Diagnostics, name: :"diag_#{System.unique_integer()}"})
    server_settings = Map.get(context, :server_settings, %{})

    server_config =
      MockLSPServer.server_config(
        request_configuration: Map.get(context, :request_configuration, false),
        request_unknown: Map.get(context, :request_unknown, false),
        settings: server_settings
      )

    if Map.get(context, :request_configuration, false) or
         Map.get(context, :request_unknown, false) do
      Minga.Events.subscribe(:diagnostics_updated)
    end

    # Subscribe to LSP status events and wait for the client to be ready.
    Minga.Events.subscribe(:lsp_status_changed)

    client =
      start_supervised!(
        {Client,
         server_config: server_config, root_path: System.tmp_dir!(), diagnostics: diag_server}
      )

    case Client.status(client) do
      :ready ->
        :ok

      _ ->
        assert_receive {:minga_event, :lsp_status_changed,
                        %Minga.Events.LspStatusEvent{name: :mock_lsp, status: :ready}},
                       @ready_timeout
    end

    %{client: client, diag_server: diag_server}
  end

  describe "initialize handshake" do
    test "client reaches ready status", %{client: client} do
      assert Client.status(client) == :ready
    end

    test "parses server capabilities", %{client: client} do
      caps = Client.capabilities(client)
      assert is_map(caps)
      assert caps["textDocumentSync"]["openClose"] == true
    end

    test "negotiates position encoding", %{client: client} do
      # Mock server advertises utf-8
      assert Client.encoding(client) == :utf8
    end

    test "reports server name", %{client: client} do
      assert Client.server_name(client) == :mock_lsp
    end
  end

  describe "document sync" do
    @uri "file:///tmp/test.ex"

    test "didOpen sends notification and receives diagnostics", %{
      client: client,
      diag_server: diag_server
    } do
      Minga.Events.subscribe(:diagnostics_updated)
      Client.did_open(client, @uri, "elixir", "defmodule Test do\nend\n")

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: @uri}},
                     5_000

      diags = Diagnostics.for_uri(diag_server, @uri)
      assert length(diags) == 1

      [diag] = diags
      assert diag.severity == :warning
      assert diag.message == "mock warning on line 1"
      assert diag.source == "mock_lsp"
      assert diag.code == "W001"
      assert diag.range.start_line == 0
      assert diag.range.start_col == 0
    end

    test "didOpen before initialization is sent once the client becomes ready", %{
      diag_server: diag_server
    } do
      uri = "file:///tmp/queued_open.ex"

      root_path =
        Path.join(System.tmp_dir!(), "queued_open_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root_path)
      Minga.Events.subscribe(:lsp_status_changed)
      Minga.Events.subscribe(:diagnostics_updated)

      client =
        start_supervised!(
          Supervisor.child_spec(
            {Client,
             server_config: MockLSPServer.server_config(),
             root_path: root_path,
             diagnostics: diag_server},
            id: :queued_open_lsp_client
          )
        )

      Client.did_open(client, uri, "elixir", "defmodule QueuedOpen do\nend\n")

      assert_receive {:minga_event, :lsp_status_changed,
                      %Minga.Events.LspStatusEvent{name: :mock_lsp, status: :ready}},
                     5_000

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: ^uri}},
                     5_000

      state = :sys.get_state(client)
      assert Map.has_key?(state.open_documents, uri)
      assert state.pending_document_opens == %{}
    end

    test "didChange does not crash", %{client: client} do
      Client.did_open(client, @uri, "elixir", "original")
      :sys.get_state(client)

      Client.did_change(client, @uri, "modified")
      :sys.get_state(client)

      # Still alive and ready
      assert Client.status(client) == :ready
    end

    test "didSave does not crash", %{client: client} do
      Client.did_open(client, @uri, "elixir", "content")
      :sys.get_state(client)

      Client.did_save(client, @uri)
      :sys.get_state(client)

      assert Client.status(client) == :ready
    end

    test "didClose clears diagnostics", %{client: client, diag_server: diag_server} do
      Minga.Events.subscribe(:diagnostics_updated)

      Client.did_open(client, @uri, "elixir", "content")

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: @uri}},
                     5_000

      assert Diagnostics.for_uri(diag_server, @uri) != []

      Client.did_close(client, @uri)

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: @uri}},
                     5_000

      assert Diagnostics.for_uri(diag_server, @uri) == []
    end

    test "didChange on unknown URI is a no-op", %{client: client} do
      Client.did_change(client, "file:///unknown", "text")
      :sys.get_state(client)
      assert Client.status(client) == :ready
    end
  end

  describe "workspace/configuration" do
    @tag request_configuration: true,
         server_settings: %{
           "mock_lsp" => %{
             "nested" => %{"enabled" => true},
             "value" => 1
           }
         }
    test "responds to server configuration requests with section results", %{
      diag_server: diag_server
    } do
      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{
                        uri: "file:///tmp/configuration-test.ex"
                      }},
                     5_000

      [diag] = Diagnostics.for_uri(diag_server, "file:///tmp/configuration-test.ex")

      assert JSON.decode!(diag.message) == [
               %{"enabled" => true},
               %{},
               %{"mock_lsp" => %{"nested" => %{"enabled" => true}, "value" => 1}}
             ]
    end
  end

  describe "server requests" do
    @tag request_unknown: true
    test "unhandled requests receive a method-not-found error", %{diag_server: diag_server} do
      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{
                        uri: "file:///tmp/unknown-request-test.ex"
                      }},
                     5_000

      [diag] = Diagnostics.for_uri(diag_server, "file:///tmp/unknown-request-test.ex")

      assert diag.code == "UNKNOWN"
      assert diag.message == "-32601:Method not found: mock/unknown"
    end
  end

  describe "status events" do
    test "client broadcasts :lsp_status_changed with :stopped on shutdown", %{client: client} do
      # Setup already proved :ready fires (via assert_receive). Test :stopped.
      Minga.Events.subscribe(:lsp_status_changed)
      Client.shutdown(client)

      assert_receive {:minga_event, :lsp_status_changed,
                      %Minga.Events.LspStatusEvent{name: :mock_lsp, status: :stopped}},
                     5_000

      # Clean shutdown must not produce a spurious :crashed event.
      refute_receive {:minga_event, :lsp_status_changed,
                      %Minga.Events.LspStatusEvent{status: :crashed}},
                     200
    end
  end

  describe "async request/response" do
    test "request/3 returns a reference", %{client: client} do
      ref =
        Client.request(client, "textDocument/completion", %{
          "textDocument" => %{"uri" => "file:///tmp/test.ex"},
          "position" => %{"line" => 0, "character" => 0}
        })

      assert is_reference(ref)

      # This test only verifies the async request can be sent without crashing.
      assert Client.status(client) == :ready
    end

    test "multiple requests return unique references", %{client: client} do
      ref1 = Client.request(client, "textDocument/hover", %{})
      ref2 = Client.request(client, "textDocument/hover", %{})

      assert is_reference(ref1)
      assert is_reference(ref2)
      assert ref1 != ref2
    end
  end
end
