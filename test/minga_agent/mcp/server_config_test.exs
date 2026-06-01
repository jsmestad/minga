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
    assert config.enabled == true
  end

  test "normalizes enabled false" do
    assert {:ok, config} =
             ServerConfig.normalize(%{
               name: "local-tools",
               command: "node",
               enabled: false
             })

    assert config.enabled == false
  end

  test "env errors explain atom keys are allowed but values must be strings" do
    assert {:error, reason} =
             ServerConfig.normalize(%{
               name: "local-tools",
               command: "node",
               env: %{TOKEN: :not_a_string}
             })

    assert reason =~ "string or atom keys"
    assert reason =~ "string values"
  end

  test "env validation errors redact secret values" do
    assert {:error, reason} =
             ServerConfig.normalize(%{
               name: "local-tools",
               command: "node",
               env: %{"GITHUB_TOKEN" => "ghp_supersecret123", "BAD" => 1}
             })

    refute reason =~ "ghp_supersecret123"
    assert reason =~ "GITHUB_TOKEN"
    assert reason =~ "[REDACTED]"
  end

  test "env validation errors redact malformed keyword-list secrets" do
    assert {:error, reason} =
             ServerConfig.normalize(%{
               name: "local-tools",
               command: "node",
               env: [API_TOKEN: "plain-secret"]
             })

    refute reason =~ "plain-secret"
    assert reason =~ "API_TOKEN"
    assert reason =~ "[REDACTED]"
  end

  test "env validation errors handle malformed non-stringable keys" do
    assert {:error, reason} =
             ServerConfig.normalize(%{
               name: "local-tools",
               command: "node",
               env: %{{:bad, :key} => "plain-secret"}
             })

    refute reason =~ "plain-secret"
    assert reason =~ "[REDACTED]"
  end

  test "env validation errors redact secret-key tuples of any arity" do
    assert {:error, reason} =
             ServerConfig.normalize(%{
               name: "local-tools",
               command: "node",
               env: {:API_TOKEN, "plain-secret", :metadata}
             })

    refute reason =~ "plain-secret"
    assert reason =~ "API_TOKEN"
    assert reason =~ "[REDACTED]"
  end

  test "inspect redacts env values" do
    config = %ServerConfig{
      name: "local-tools",
      command: "node",
      env: %{"GITHUB_TOKEN" => "ghp_supersecret123", "MODE" => "test"}
    }

    inspected = inspect(config)
    refute inspected =~ "ghp_supersecret123"
    refute inspected =~ "test"
    assert inspected =~ "GITHUB_TOKEN"
    assert inspected =~ "[REDACTED]"
  end

  test "inspect redacts credential-like args" do
    config = %ServerConfig{
      name: "local-tools",
      command: "node",
      args: [
        "--api-key",
        "plain-secret",
        "--client-secret",
        "compound-secret",
        "--token=inline-secret",
        "--refresh-token=refresh-secret",
        "API_TOKEN=env-secret"
      ]
    }

    inspected = inspect(config)
    refute inspected =~ "plain-secret"
    refute inspected =~ "compound-secret"
    refute inspected =~ "inline-secret"
    refute inspected =~ "refresh-secret"
    refute inspected =~ "env-secret"
    assert inspected =~ "[REDACTED]"
  end

  test "rejects missing command" do
    assert {:error, reason} = ServerConfig.normalize(%{name: "local"})
    assert reason =~ "command is required"
  end

  test "validates struct values" do
    assert {:error, reason} = ServerConfig.normalize(%ServerConfig{name: "local", command: 123})
    assert reason =~ "command must be a string"
  end

  test "rejects wrong-typed atom keys instead of falling back to string keys" do
    assert {:error, reason} =
             ServerConfig.normalize(%{"name" => "local", name: false, command: "node"})

    assert reason =~ "name must be a string"
  end

  test "normalize_list filters disabled configs before validating required launch fields" do
    assert {:ok, configs} =
             ServerConfig.normalize_list([
               %{name: "disabled", enabled: false},
               %{name: "enabled", command: "node"}
             ])

    assert Enum.map(configs, & &1.name) == ["enabled"]
  end

  test "normalize_list accepts nil, one map, and a list" do
    assert {:ok, []} = ServerConfig.normalize_list(nil)

    assert {:ok, [%ServerConfig{name: "one"}]} =
             ServerConfig.normalize_list(%{name: "one", command: "node"})

    assert {:ok, [%ServerConfig{name: "one"}, %ServerConfig{name: "two"}]} =
             ServerConfig.normalize_list([
               %{name: "one", command: "node"},
               %{name: "two", command: "node"}
             ])
  end

  test "normalize_list rejects nil entries" do
    assert {:error, reason} =
             ServerConfig.normalize_list([
               nil,
               %{name: "tools", command: "node"}
             ])

    assert reason =~ "cannot contain nil"
  end

  test "normalize_list rejects duplicate enabled server names" do
    assert {:error, reason} =
             ServerConfig.normalize_list([
               %{name: "tools", command: "node"},
               %{name: "tools", command: "python"}
             ])

    assert reason =~ "unique"
    assert reason =~ "tools"
  end

  test "normalize_list ignores disabled duplicate names" do
    assert {:ok, [%ServerConfig{name: "tools"}]} =
             ServerConfig.normalize_list([
               %{name: "tools", enabled: false},
               %{name: "tools", command: "node"}
             ])
  end
end
