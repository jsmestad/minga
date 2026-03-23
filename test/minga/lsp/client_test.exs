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

  setup do
    diag_server = start_supervised!({Diagnostics, name: :"diag_#{System.unique_integer()}"})

    client =
      start_supervised!(
        {Client,
         server_config: MockLSPServer.server_config(),
         root_path: System.tmp_dir!(),
         diagnostics: diag_server}
      )

    # Subscribe to LSP status events and wait for the client to be ready.
    Minga.Events.subscribe(:lsp_status_changed)

    case Client.status(client) do
      :ready ->
        :ok

      _ ->
        assert_receive {:minga_event, :lsp_status_changed,
                        %Minga.Events.LspStatusEvent{name: :mock_lsp, status: :ready}},
                       5_000
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

      # The mock server doesn't handle completion, so we'll get a timeout.
      # The key thing is the request was sent without crashing.
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
