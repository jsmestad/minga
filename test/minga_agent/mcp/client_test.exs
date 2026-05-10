defmodule MingaAgent.MCP.ClientTest do
  use ExUnit.Case, async: true

  alias MingaAgent.MCP.Client
  alias MingaAgent.MCP.FakeTransport
  alias MingaAgent.MCP.ServerConfig

  defp server_config do
    %ServerConfig{name: "Local Tools", command: "ignored"}
  end

  defp tool_def do
    %{
      "name" => "echo-text",
      "description" => "Echo text",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      }
    }
  end

  test "returns an error instead of raising when server config is missing" do
    assert {:error, reason} = Client.start([])
    assert reason =~ "config is required"
  end

  test "initializes, sends initialized notification, and lists tools with safe names" do
    {:ok, client} =
      Client.start_link(
        server_config: server_config(),
        transport: FakeTransport,
        transport_opts: [tools: [tool_def()], test_pid: self()]
      )

    assert_receive {:mcp_request, %{"method" => "initialize"}}
    assert_receive {:mcp_notification, %{"method" => "notifications/initialized"}}
    assert_receive {:mcp_request, %{"method" => "tools/list"}}

    assert {:ok, [tool]} = Client.list_tools(client)
    assert tool.name == "echo-text"
    assert tool.safe_name == "mcp_local_tools__echo_text"
    assert tool.input_schema == tool_def()["inputSchema"]
  end

  test "ReqLLM tool preserves prefix and schema" do
    {:ok, client} =
      Client.start_link(
        server_config: server_config(),
        transport: FakeTransport,
        transport_opts: [tools: [tool_def()]]
      )

    assert {:ok, [tool]} = Client.reqllm_tools(client)
    assert tool.name == "mcp_local_tools__echo_text"
    assert tool.parameter_schema == tool_def()["inputSchema"]
  end

  test "call_tool returns MCP tool-level errors as errors" do
    {:ok, client} =
      Client.start_link(
        server_config: server_config(),
        transport: FakeTransport,
        transport_opts: [
          tools: [tool_def()],
          call_results: %{
            "echo-text" => %{
              "isError" => true,
              "content" => [%{"type" => "text", "text" => "tool failed"}]
            }
          }
        ]
      )

    assert {:error, %{"isError" => true, "content" => [%{"text" => "tool failed"}]}} =
             Client.call_tool(client, "echo-text", %{"text" => "hi"})
  end

  test "call_tool sends the unprefixed original MCP name" do
    {:ok, client} =
      Client.start_link(
        server_config: server_config(),
        transport: FakeTransport,
        transport_opts: [tools: [tool_def()], test_pid: self()]
      )

    assert {:ok, %{"content" => [%{"text" => "called echo-text"}]}} =
             Client.call_tool(client, "echo-text", %{"text" => "hi"})

    assert_receive {:mcp_tool_call, "echo-text", %{"text" => "hi"}}
  end

  test "rejects malformed tools/list results and stops transport" do
    assert {:error, reason} =
             Client.start(
               server_config: server_config(),
               transport: FakeTransport,
               transport_opts: [tools: "not-a-list", test_pid: self()]
             )

    assert reason =~ "tools list"
    assert_receive {:mcp_transport_started, transport}
    assert_receive {:mcp_transport_stopped, ^transport}
    refute Process.alive?(transport)
  end

  test "stops transport when handshake fails" do
    assert {:error, :list_failed} =
             Client.start(
               server_config: server_config(),
               transport: FakeTransport,
               transport_opts: [
                 tools: [tool_def()],
                 request_errors: %{"tools/list" => :list_failed},
                 test_pid: self()
               ]
             )

    assert_receive {:mcp_transport_started, transport}
    assert_receive {:mcp_transport_stopped, ^transport}
    refute Process.alive?(transport)
  end

  test "request exit error notifies owner and makes future calls fail" do
    {:ok, client} =
      Client.start_link(
        server_config: server_config(),
        transport: FakeTransport,
        transport_opts: [
          tools: [tool_def()],
          request_errors: %{"echo-text" => {:exit_status, 1}}
        ],
        notify_pid: self()
      )

    assert {:error, {:exit_status, 1}} = Client.call_tool(client, "echo-text", %{"text" => "hi"})
    assert_receive {:mcp_client_down, ^client, "Local Tools", {:exit_status, 1}}

    assert {:error, message} = Client.call_tool(client, "echo-text", %{"text" => "hi"})
    assert message =~ "unavailable"
    assert Client.list_tools(client) == {:error, message}
  end

  test "call_tool returns an error when the client process is gone" do
    {:ok, client} =
      Client.start(
        server_config: server_config(),
        transport: FakeTransport,
        transport_opts: [tools: [tool_def()]]
      )

    GenServer.stop(client)

    assert {:error, {:mcp_client_unavailable, _reason}} =
             Client.call_tool(client, "echo-text", %{"text" => "hi"})
  end

  test "transport crash notifies owner and makes future calls fail" do
    {:ok, client} =
      Client.start_link(
        server_config: server_config(),
        transport: FakeTransport,
        transport_opts: [tools: [tool_def()], test_pid: self()],
        notify_pid: self()
      )

    assert_receive {:mcp_transport_started, transport}
    FakeTransport.crash(transport)
    assert_receive {:mcp_client_down, ^client, "Local Tools", :boom}

    assert {:error, message} = Client.call_tool(client, "echo-text", %{"text" => "hi"})
    assert message =~ "unavailable"
  end
end
