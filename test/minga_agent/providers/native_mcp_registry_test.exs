defmodule MingaAgent.Providers.NativeMCPRegistryTest do
  # async: false because these tests mutate the global MCP server contribution registry.
  use ExUnit.Case, async: false

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.MCP.ServerRegistry
  alias MingaAgent.Providers.Native

  @source {:extension, :native_mcp_registry_test}
  @moduletag :tmp_dir

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

  test "active native providers remove stale MCP contributions when their source unloads", %{
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

    assert :ok = ServerRegistry.unregister_source(@source)
    :sys.get_state(provider)

    assert {:ok, %{mcp_status: []}} = Native.get_state(provider)
    refute Enum.any?(Native.tools(provider), &(&1.name == "list_mcp_tools"))
  end

  defp ensure_registry_started do
    if Process.whereis(ServerRegistry) == nil do
      start_supervised!(ServerRegistry)
    end
  end
end
