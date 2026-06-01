defmodule MingaAgent.Providers.NativeMCPRegistryTest do
  # async: false because these tests mutate the global MCP server contribution registry.
  use ExUnit.Case, async: false

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Event
  alias MingaAgent.MCP.FakeTransport
  alias MingaAgent.MCP.ServerRegistry
  alias MingaAgent.Providers.Native

  @source {:extension, :native_mcp_registry_test}
  @moduletag :tmp_dir
  @receive_timeout 5_000

  setup do
    ensure_registry_started()
    ServerRegistry.unregister_source(@source)

    on_exit(fn ->
      ServerRegistry.unregister_source(@source)
    end)

    :ok
  end

  test "MCP registry changes respect provider mcp_enabled override", %{tmp_dir: dir} do
    {:ok, provider} =
      Native.start_link(
        subscriber: self(),
        model: "anthropic:claude-sonnet-4-20250514",
        project_root: dir,
        tools: [],
        config: %AgentConfig{mcp_servers: [], tool_approval: :none},
        mcp_enabled?: false,
        skip_api_key_env: true
      )

    assert :ok = ServerRegistry.register_many(@source, [{:ext_tools, command: "ignored"}])
    :sys.get_state(provider)

    assert {:ok, %{mcp_status: []}} = Native.get_state(provider)
    refute Enum.any?(Native.tools(provider), &(&1.name == "list_mcp_tools"))
  end

  test "MCP registry refresh preserves per-provider mcp_servers overrides", %{tmp_dir: dir} do
    {:ok, provider} =
      Native.start_link(
        subscriber: self(),
        model: "anthropic:claude-sonnet-4-20250514",
        project_root: dir,
        tools: [],
        config: %AgentConfig{mcp_servers: [], tool_approval: :none},
        mcp_servers: [%MingaAgent.MCP.ServerConfig{name: "override_tools", command: "ignored"}],
        mcp_enabled?: true,
        skip_api_key_env: true
      )

    assert {:ok, %{mcp_status: [%{"name" => "override_tools"}]}} = Native.get_state(provider)

    assert :ok = ServerRegistry.register_many(@source, [{:ext_tools, command: "ignored"}])
    :sys.get_state(provider)

    assert {:ok, %{mcp_status: statuses}} = Native.get_state(provider)
    assert Enum.any?(statuses, &(&1["name"] == "override_tools"))
    assert Enum.any?(statuses, &(&1["name"] == "ext_tools"))
  end

  test "MCP registry refresh preserves the provider tool allowlist", %{tmp_dir: dir} do
    assert :ok = ServerRegistry.register_many(@source, [{:ext_tools, command: "ignored"}])

    {:ok, provider} =
      Native.start_link(
        subscriber: self(),
        model: "anthropic:claude-sonnet-4-20250514",
        project_root: dir,
        tools: [],
        config: %AgentConfig{mcp_servers: [], tool_approval: :none},
        mcp_enabled?: true,
        tool_allowlist: [],
        skip_api_key_env: true
      )

    assert Native.tools(provider) == []

    assert :ok = ServerRegistry.unregister_source(@source)
    :sys.get_state(provider)

    assert Native.tools(provider) == []
  end

  test "active native providers stop clients and notify when their MCP source unloads", %{
    tmp_dir: dir
  } do
    assert :ok = ServerRegistry.register_many(@source, [{:ext_tools, command: "ignored"}])

    {:ok, provider} =
      Native.start_link(
        subscriber: self(),
        model: "anthropic:claude-sonnet-4-20250514",
        project_root: dir,
        tools: [],
        config: %AgentConfig{mcp_servers: [], tool_approval: :none},
        mcp_enabled?: true,
        mcp_transport: FakeTransport,
        mcp_transport_opts: [tools: [mcp_tool_def()], test_pid: self()],
        skip_api_key_env: true
      )

    assert {:ok,
            %{
              mcp_status: [
                %{"name" => "ext_tools", "source" => "extension:native_mcp_registry_test"}
              ]
            }} =
             Native.get_state(provider)

    assert Enum.any?(Native.tools(provider), &(&1.name == "list_mcp_tools"))
    assert {:ok, [_tool]} = GenServer.call(provider, :list_mcp_tools, :infinity)
    assert_receive {:mcp_transport_started, "ext_tools", transport}, @receive_timeout

    assert :ok = ServerRegistry.unregister_source(@source)
    :sys.get_state(provider)

    assert_receive {:mcp_transport_stopped, "ext_tools", ^transport}, @receive_timeout
    assert_receive {:agent_provider_event, %Event.SystemMessage{message: message, level: :info}}
    assert message =~ "MCP source extension:native_mcp_registry_test unloaded"

    assert {:ok, %{mcp_status: []}} = Native.get_state(provider)
    refute Enum.any?(Native.tools(provider), &(&1.name == "list_mcp_tools"))
  end

  defp mcp_tool_def do
    %{
      "name" => "echo-text",
      "description" => "MCP tool echo-text",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  end

  defp ensure_registry_started do
    if Process.whereis(ServerRegistry) == nil do
      start_supervised!(ServerRegistry)
    end
  end
end
