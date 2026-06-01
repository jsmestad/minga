defmodule MingaAgent.MCP.ServerRegistryTest do
  # async: false because these tests mutate the global MCP server contribution registry.
  use ExUnit.Case, async: false

  alias MingaAgent.MCP.ServerRegistry

  @source_a {:extension, :mcp_registry_a}
  @source_b {:extension, :mcp_registry_b}

  setup do
    ensure_registry_started()
    ServerRegistry.unregister_source(@source_a)
    ServerRegistry.unregister_source(@source_b)

    on_exit(fn ->
      ServerRegistry.unregister_source(@source_a)
      ServerRegistry.unregister_source(@source_b)
    end)

    :ok
  end

  test "same source replaces its MCP server batch" do
    assert :ok = ServerRegistry.register_many(@source_a, [{:alpha, command: "alpha"}])
    assert [%{config: %{name: "alpha", source: @source_a}}] = ServerRegistry.entries()

    assert :ok = ServerRegistry.register_many(@source_a, [{"beta", command: "beta"}])
    assert [%{config: %{name: "beta", source: @source_a}}] = ServerRegistry.entries()
  end

  test "cross-source duplicate names keep the existing owner" do
    assert :ok = ServerRegistry.register_many(@source_a, [{:shared, command: "a"}])

    assert :ok =
             ServerRegistry.register_many(@source_b, [
               {:shared, command: "b"},
               {:unique, command: "b"}
             ])

    entries = ServerRegistry.entries()
    assert Enum.map(entries, & &1.config.name) == ["shared", "unique"]
    assert Enum.find(entries, &(&1.config.name == "shared")).source == @source_a
    assert Enum.find(entries, &(&1.config.name == "unique")).source == @source_b
  end

  test "unregister_source removes only that source and broadcasts a change" do
    Minga.Events.subscribe(:agent_mcp_servers_changed)

    assert :ok = ServerRegistry.register_many(@source_a, [{:alpha, command: "alpha"}])
    assert_receive {:minga_event, :agent_mcp_servers_changed, %{source: @source_a}}

    assert :ok = ServerRegistry.register_many(@source_b, [{:beta, command: "beta"}])
    assert_receive {:minga_event, :agent_mcp_servers_changed, %{source: @source_b}}

    assert :ok = ServerRegistry.unregister_source(@source_a)
    assert_receive {:minga_event, :agent_mcp_servers_changed, %{source: @source_a}}

    assert [%{config: %{name: "beta"}}] = ServerRegistry.entries()
  end

  defp ensure_registry_started do
    if Process.whereis(ServerRegistry) == nil do
      start_supervised!(ServerRegistry)
    end
  end
end
