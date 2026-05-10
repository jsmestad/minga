defmodule MingaAgent.MCP.RegistryTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Event
  alias MingaAgent.MCP.FakeTransport
  alias MingaAgent.MCP.Registry
  alias MingaAgent.MCP.ServerConfig
  alias ReqLLM.Tool

  defp config(name), do: %ServerConfig{name: name, command: "ignored"}

  defp tool(name) do
    %{
      "name" => name,
      "description" => "Tool #{name}",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  end

  test "starts multiple healthy servers and builds a combined tool index" do
    {registry, tools, failures} =
      Registry.start_all([config("Alpha"), config("Beta")], self(),
        transport: FakeTransport,
        transport_opts: [
          tools_by_server: %{
            "Alpha" => [tool("echo-text")],
            "Beta" => [tool("search-code")]
          },
          test_pid: self()
        ],
        notify_pid: self()
      )

    assert failures == []
    tool_names = Enum.map(tools, & &1.name)
    assert "mcp_alpha__echo_text" in tool_names
    assert "mcp_beta__search_code" in tool_names

    alpha_tool = Enum.find(tools, &(&1.name == "mcp_alpha__echo_text"))
    beta_tool = Enum.find(tools, &(&1.name == "mcp_beta__search_code"))

    assert {:ok, _result} = Tool.execute(alpha_tool, %{})
    assert_receive {:mcp_tool_call, "Alpha", "echo-text", %{}}

    assert {:ok, _result} = Tool.execute(beta_tool, %{})
    assert_receive {:mcp_tool_call, "Beta", "search-code", %{}}

    Registry.stop_all(registry)
  end

  test "renames cross-server tool collisions and keeps callbacks routed to the owning server" do
    {registry, tools, failures} =
      Registry.start_all([config("Alpha Tools"), config("Alpha_Tools")], self(),
        transport: FakeTransport,
        transport_opts: [
          tools_by_server: %{
            "Alpha Tools" => [tool("echo-text")],
            "Alpha_Tools" => [tool("echo-text")]
          },
          test_pid: self()
        ],
        notify_pid: self()
      )

    assert failures == []
    tool_names = Enum.map(tools, & &1.name)
    assert tool_names == ["mcp_alpha_tools__echo_text", "mcp_alpha_tools__echo_text_2"]

    first_tool = Enum.find(tools, &(&1.name == "mcp_alpha_tools__echo_text"))
    second_tool = Enum.find(tools, &(&1.name == "mcp_alpha_tools__echo_text_2"))

    assert {:ok, _result} = Tool.execute(first_tool, %{})
    assert_receive {:mcp_tool_call, "Alpha Tools", "echo-text", %{}}

    assert {:ok, _result} = Tool.execute(second_tool, %{})
    assert_receive {:mcp_tool_call, "Alpha_Tools", "echo-text", %{}}

    Registry.stop_all(registry)
  end

  test "renames MCP tools that collide with reserved built-in tool names" do
    {registry, tools, failures} =
      Registry.start_all([config("Local Tools")], self(),
        transport: FakeTransport,
        transport_opts: [tools: [tool("echo-text")], test_pid: self()],
        notify_pid: self(),
        reserved_tool_names: ["mcp_local_tools__echo_text"]
      )

    assert failures == []
    assert Enum.map(tools, & &1.name) == ["mcp_local_tools__echo_text_2"]

    [renamed_tool] = tools
    assert {:ok, _result} = Tool.execute(renamed_tool, %{})
    assert_receive {:mcp_tool_call, "Local Tools", "echo-text", %{}}

    Registry.stop_all(registry)
  end

  test "startup failure is isolated to one server" do
    {registry, tools, failures} =
      Registry.start_all([config("Broken"), config("Healthy")], self(),
        transport: FakeTransport,
        transport_opts: [
          tools_by_server: %{"Healthy" => [tool("echo-text")]},
          request_errors_by_server: %{"Broken" => %{"tools/list" => :boom}},
          test_pid: self()
        ],
        notify_pid: self()
      )

    assert [failure] = failures
    assert failure =~ "MCP server Broken failed to start"
    assert_receive {:agent_provider_event, %Event.Error{message: message}}
    assert message =~ "Broken"

    assert Enum.map(tools, & &1.name) == ["mcp_healthy__echo_text"]

    [healthy_tool] = tools
    assert {:ok, _result} = Tool.execute(healthy_tool, %{})
    assert_receive {:mcp_tool_call, "Healthy", "echo-text", %{}}

    Registry.stop_all(registry)
  end

  test "removing a crashed server removes only its tools" do
    {registry, tools, []} =
      Registry.start_all([config("Alpha"), config("Beta")], self(),
        transport: FakeTransport,
        transport_opts: [
          tools_by_server: %{
            "Alpha" => [tool("echo-text")],
            "Beta" => [tool("search-code")]
          },
          test_pid: self()
        ],
        notify_pid: self()
      )

    assert_receive {:mcp_transport_started, "Alpha", alpha_transport}
    FakeTransport.crash(alpha_transport)
    assert_receive {:mcp_client_down, alpha_client, "Alpha", :boom}
    assert Registry.server_for_pid(registry, alpha_client) == "Alpha"

    {registry, removed_tool_names} = Registry.remove_server(registry, "Alpha")
    assert removed_tool_names == ["mcp_alpha__echo_text"]

    beta_tool = Enum.find(tools, &(&1.name == "mcp_beta__search_code"))
    assert {:ok, _result} = Tool.execute(beta_tool, %{})
    assert_receive {:mcp_tool_call, "Beta", "search-code", %{}}

    Registry.stop_all(registry)
  end
end
