defmodule MingaAgent.MCP.ServerConfigTest do
  use ExUnit.Case, async: true

  alias MingaAgent.MCP.ServerConfig

  test "normalizes atom and string keys" do
    assert {:ok, config} =
             ServerConfig.normalize(%{
               "name" => "local-tools",
               command: "node",
               args: ["server.js"],
               env: %{"MODE" => "test", TOKEN: "secret"}
             })

    assert %ServerConfig{} = config
    assert config.name == "local-tools"
    assert config.command == "node"
    assert config.args == ["server.js"]
    assert config.env == %{"TOKEN" => "secret", "MODE" => "test"}
  end

  test "rejects missing command" do
    assert {:error, reason} = ServerConfig.normalize(%{name: "local"})
    assert reason =~ "command is required"
  end

  test "rejects wrong-typed atom keys instead of falling back to string keys" do
    assert {:error, reason} =
             ServerConfig.normalize(%{"name" => "local", name: false, command: "node"})

    assert reason =~ "name must be a string"
  end
end
