defmodule MingaAgent.MCP.ServerRegistryTest do
  # async: false because these tests mutate the global MCP server contribution registry.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MingaAgent.MCP.ServerConfig
  alias MingaAgent.MCP.ServerRegistry

  @source_a {:extension, :mcp_registry_a}
  @source_b {:extension, :mcp_registry_b}
  @bundle_source {:bundle, :mcp_registry_test}

  setup do
    ensure_registry_started()
    ServerRegistry.unregister_source(:config)
    ServerRegistry.unregister_source(@source_a)
    ServerRegistry.unregister_source(@source_b)
    ServerRegistry.unregister_source(@bundle_source)

    on_exit(fn ->
      ServerRegistry.unregister_source(:config)
      ServerRegistry.unregister_source(@source_a)
      ServerRegistry.unregister_source(@source_b)
      ServerRegistry.unregister_source(@bundle_source)
    end)

    :ok
  end

  @tag :tmp_dir
  test "an extension's own relative program is a file in its folder, and it cannot choose a directory",
       %{
         tmp_dir: dir
       } do
    if Process.whereis(Minga.Extension.Registry) == nil,
      do: start_supervised!({Minga.Extension.Registry, name: Minga.Extension.Registry})

    :ok = Minga.Extension.Registry.register(:mcp_registry_a, dir, [])
    on_exit(fn -> Minga.Extension.Registry.unregister(:mcp_registry_a) end)

    assert :ok =
             ServerRegistry.register_many(@source_a, [
               {:own, command: "bin/serve", cwd: "/tmp"},
               {:on_path, command: "node"},
               {:absolute, command: "/usr/bin/env"}
             ])

    assert [own, on_path, absolute] = Enum.map(ServerRegistry.entries(), & &1.config)
    # Wherever the server is started, the program is the file in the extension's folder.
    assert own.command == Path.join(Path.expand(dir), "bin/serve")
    assert on_path.command == "node"
    assert absolute.command == "/usr/bin/env"
    assert Enum.map([own, on_path, absolute], & &1.cwd) == [nil, nil, nil]
  end

  test "an extension without a folder keeps its program as declared" do
    assert :ok =
             ServerRegistry.register_many(@source_b, [{:loose, command: "bin/serve", cwd: "/tmp"}])

    assert [%{config: %{command: "bin/serve", cwd: nil}}] = ServerRegistry.entries()
  end

  test "same source replaces its MCP server batch" do
    assert :ok = ServerRegistry.register_many(@source_a, [{:alpha, command: "alpha"}])
    assert [%{config: %{name: "alpha", source: @source_a}}] = ServerRegistry.entries()

    assert :ok = ServerRegistry.register_many(@source_a, [{"beta", command: "beta"}])
    assert [%{config: %{name: "beta", source: @source_a}}] = ServerRegistry.entries()
  end

  test "bundle sources participate in deterministic server-name collisions" do
    assert :ok = ServerRegistry.register_many(:config, [{:shared, command: "config"}])

    assert :ok =
             ServerRegistry.register_many(@bundle_source, [
               {:shared, command: "bundle"},
               {:bundled_unique, command: "bundle"}
             ])

    assert :ok =
             ServerRegistry.register_many(@source_a, [
               {:shared, command: "extension"},
               {:extension_unique, command: "extension"}
             ])

    resolved =
      ServerRegistry.resolve_configs([
        %ServerConfig{name: "shared", command: "config", source: :config},
        %ServerConfig{name: "config_unique", command: "config", source: :config}
      ])

    assert Enum.map(resolved, & &1.name) == [
             "shared",
             "config_unique",
             "bundled_unique",
             "extension_unique"
           ]

    assert Enum.find(resolved, &(&1.name == "shared")).source == :config
    assert Enum.find(resolved, &(&1.name == "config_unique")).source == :config
    assert Enum.find(resolved, &(&1.name == "bundled_unique")).source == @bundle_source
    assert Enum.find(resolved, &(&1.name == "extension_unique")).source == @source_a
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

  test "bad declarations redact env secrets from logs" do
    log =
      capture_log(fn ->
        assert :ok =
                 ServerRegistry.register_many(@source_a, [
                   {:secret_tools,
                    command: "node", env: %{"GITHUB_TOKEN" => "ghp_supersecret123", "BAD" => 1}}
                 ])
      end)

    refute log =~ "ghp_supersecret123"
    assert ServerRegistry.entries() == []
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
