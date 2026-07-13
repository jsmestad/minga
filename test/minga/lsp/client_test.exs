defmodule Minga.LSP.ClientTest do
  # async: false because MockLSPServer spawns OS processes that can race under heavy parallel load.
  use ExUnit.Case, async: false

  @moduletag :heavy

  alias Minga.Diagnostics
  alias Minga.LSP.Client
  alias Minga.Test.MockLSPServer

  @ready_timeout 10_000
  @event_timeout 5_000
  @uri "file:///tmp/test.ex"

  setup context do
    diag_server = start_supervised!({Diagnostics, name: :"diag_#{System.unique_integer()}"})
    server_settings = Map.get(context, :server_settings, %{})

    server_config =
      MockLSPServer.server_config(
        request_configuration: Map.get(context, :request_configuration, false),
        request_unknown: Map.get(context, :request_unknown, false),
        show_message: Map.get(context, :show_message, false),
        show_message_request: Map.get(context, :show_message_request, false),
        report_cancellations: Map.get(context, :report_cancellations, false),
        position_encoding: Map.get(context, :position_encoding, "utf-8"),
        settings: server_settings
      )

    if Map.get(context, :request_configuration, false) or
         Map.get(context, :request_unknown, false) or
         Map.get(context, :show_message_request, false) or
         Map.get(context, :report_cancellations, false) do
      Minga.Events.subscribe(:diagnostics_updated)
    end

    if Map.get(context, :show_message, false) do
      Minga.Events.subscribe(:log_message)
    end

    Minga.Events.subscribe(:lsp_status_changed)

    client =
      start_supervised!(
        {Client,
         server_config: server_config, root_path: System.tmp_dir!(), diagnostics: diag_server}
      )

    wait_until_ready(client)

    %{client: client, diag_server: diag_server}
  end

  describe "initialize handshake" do
    test "client exposes negotiated server metadata", %{client: client} do
      caps = Client.capabilities(client)

      assert Client.status(client) == :ready
      assert is_map(caps)
      assert caps["textDocumentSync"]["openClose"] == true
      assert Client.encoding(client) == :utf8
      assert Client.server_name(client) == :mock_lsp
    end

    test "server stderr output does not break stdio protocol", %{diag_server: diag_server} do
      root_path = Path.join(System.tmp_dir!(), "stderr_lsp_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root_path)
      Minga.Events.subscribe(:lsp_status_changed)

      client =
        start_supervised!(
          Supervisor.child_spec(
            {Client,
             server_config: MockLSPServer.server_config(stderr_banner: true),
             root_path: root_path,
             diagnostics: diag_server},
            id: :stderr_lsp_client
          )
        )

      wait_until_ready(client)

      assert Client.status(client) == :ready
      assert Client.server_name(client) == :mock_lsp
    end
  end

  describe "document sync" do
    test "didOpen sends notification and stores diagnostics", %{
      client: client,
      diag_server: diag_server
    } do
      Minga.Events.subscribe(:diagnostics_updated)

      Client.did_open(client, @uri, "elixir", "defmodule Test do\nend\n")

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: @uri}},
                     @event_timeout

      assert [diag] = Diagnostics.for_uri(diag_server, @uri)
      assert diag.severity == :warning
      assert diag.message == "mock warning on line 1"
      assert diag.source == "mock_lsp"
      assert diag.code == "W001"
      assert diag.range.start_line == 0
      assert diag.range.start_col == 0
    end

    @tag position_encoding: "utf-16"
    test "didOpen stores diagnostics with the negotiated UTF-16 encoding", %{
      client: client,
      diag_server: diag_server
    } do
      Minga.Events.subscribe(:diagnostics_updated)

      Client.did_open(client, @uri, "elixir", "\"héllo wörld\" <> undefined_var\n")

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: @uri}},
                     @event_timeout

      assert Client.encoding(client) == :utf16
      assert [diag] = Diagnostics.for_uri(diag_server, @uri)
      assert diag.encoding == :utf16
      assert diag.range.start_col == 0
      assert diag.range.end_col == 5
    end

    test "didOpen during startup is sent once the client becomes ready", %{
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

      wait_until_ready(client)

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: ^uri}},
                     @event_timeout

      assert [_diag] = Diagnostics.for_uri(diag_server, uri)
    end

    test "didChange, didSave, and unknown-uri didChange are safe no-ops", %{client: client} do
      Client.did_open(client, @uri, "elixir", "original")
      assert Client.status(client) == :ready

      Client.did_change(client, @uri, "modified")
      assert Client.status(client) == :ready

      Client.did_save(client, @uri)
      assert Client.status(client) == :ready

      Client.did_change(client, "file:///unknown", "text")
      assert Client.status(client) == :ready
    end

    test "didClose clears diagnostics", %{client: client, diag_server: diag_server} do
      Minga.Events.subscribe(:diagnostics_updated)

      Client.did_open(client, @uri, "elixir", "content")

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: @uri}},
                     @event_timeout

      assert Diagnostics.for_uri(diag_server, @uri) != []

      Client.did_close(client, @uri)

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: @uri}},
                     @event_timeout

      assert Diagnostics.for_uri(diag_server, @uri) == []
    end
  end

  describe "workspace/configuration" do
    @tag request_configuration: true,
         server_settings: %{"mock_lsp" => %{"nested" => %{"enabled" => true}, "value" => 1}}
    test "responds to server configuration requests with section results", %{
      diag_server: diag_server
    } do
      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{
                        uri: "file:///tmp/configuration-test.ex"
                      }},
                     @event_timeout

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
                     @event_timeout

      [diag] = Diagnostics.for_uri(diag_server, "file:///tmp/unknown-request-test.ex")

      assert diag.code == "UNKNOWN"
      assert diag.message == "-32601:Method not found: mock/unknown"
    end
  end

  describe "window/showMessage" do
    @tag show_message: true
    test "routes the message to the :log_message pipeline with severity prefix" do
      assert_receive {:minga_event, :log_message,
                      %Minga.Events.LogMessageEvent{text: text, level: :error}},
                     @event_timeout

      assert text == "[LSP/error] mock_lsp: mock show message"
    end
  end

  describe "window/showMessageRequest" do
    @tag show_message_request: true
    test "responds with null so the server does not hang", %{diag_server: diag_server} do
      # The mock server echoes the client's response back as a diagnostic.
      # If the client did not respond, the mock never emits this and the
      # assert_receive times out.
      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{
                        uri: "file:///tmp/show-message-request-test.ex"
                      }},
                     @event_timeout

      [diag] = Diagnostics.for_uri(diag_server, "file:///tmp/show-message-request-test.ex")

      assert diag.code == "SHOWMSG"
      assert diag.message == "nil"
    end
  end

  describe "status events" do
    test "client broadcasts stopped without a spurious crash event on shutdown", %{client: client} do
      Minga.Events.subscribe(:lsp_status_changed)

      Client.shutdown(client)

      assert_receive {:minga_event, :lsp_status_changed,
                      %Minga.Events.LspStatusEvent{name: :mock_lsp, status: :stopped}},
                     @event_timeout

      refute_receive {:minga_event, :lsp_status_changed,
                      %Minga.Events.LspStatusEvent{status: :crashed}},
                     200
    end
  end

  describe "async request/response" do
    test "request/3 returns unique references while the client stays ready", %{client: client} do
      ref1 =
        Client.request(client, "textDocument/completion", %{
          "textDocument" => %{"uri" => @uri},
          "position" => %{"line" => 0, "character" => 0}
        })

      ref2 = Client.request(client, "textDocument/hover", %{})

      assert is_reference(ref1)
      assert is_reference(ref2)
      assert ref1 != ref2
      assert Client.status(client) == :ready
    end

    @tag report_cancellations: true
    test "cancel_request/2 maps the opaque ref to a wire cancellation and suppresses delivery", %{
      client: client,
      diag_server: diag_server
    } do
      ref = Client.request(client, "mock/stall", %{})

      assert Client.cancel_request(client, ref) == :ok
      assert Client.cancel_request(client, ref) == {:error, :not_found}
      assert_cancel_diagnostic(diag_server)
      refute_receive {:lsp_response, ^ref, _result}, 100
    end

    @tag report_cancellations: true
    test "an async caller exit cancels its outstanding wire request", %{
      client: client,
      diag_server: diag_server
    } do
      parent = self()

      caller =
        spawn(fn ->
          ref = Client.request(client, "mock/stall", %{})
          send(parent, {:request_ref, ref})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:request_ref, ref}
      monitor = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
      assert_cancel_diagnostic(diag_server)
      refute_receive {:lsp_response, ^ref, _result}, 100
    end
  end

  defp assert_cancel_diagnostic(diag_server) do
    assert_receive {:minga_event, :diagnostics_updated,
                    %Minga.Events.DiagnosticsUpdatedEvent{
                      uri: "file:///tmp/cancel-request-test.ex"
                    }},
                   @event_timeout

    assert [%{code: "CANCEL"}] =
             Diagnostics.for_uri(diag_server, "file:///tmp/cancel-request-test.ex")
  end

  defp wait_until_ready(client) do
    case Client.status(client) do
      :ready ->
        :ok

      _ ->
        assert_receive {:minga_event, :lsp_status_changed,
                        %Minga.Events.LspStatusEvent{name: :mock_lsp, status: :ready}},
                       @ready_timeout
    end
  end
end
