defmodule Minga.Extension.JsonLoaderTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.JsonLoader

  @moduletag :tmp_dir

  _ = :session_start

  @valid_manifest Jason.encode!(%{
                    "name" => "hello-world",
                    "description" => "A simple greeting plugin",
                    "version" => "0.1.0",
                    "hooks" => [
                      %{
                        "event" => "session_start",
                        "command" => "${MINGA_PLUGIN_ROOT}/hooks/hello.sh"
                      }
                    ],
                    "skills" => ["${MINGA_PLUGIN_ROOT}/skills/greet"],
                    "mcp_servers" => [
                      %{
                        "name" => "my_mcp",
                        "command" => "${MINGA_PLUGIN_ROOT}/servers/my-mcp",
                        "args" => ["--port", "3000"]
                      }
                    ],
                    "slash_commands" => [
                      %{
                        "name" => "greet",
                        "description" => "Say hello",
                        "command" => "${MINGA_PLUGIN_ROOT}/commands/greet.sh"
                      }
                    ]
                  })

  setup %{tmp_dir: dir}, do: %{dir: dir}

  test "loads a complete manifest into a working extension", %{dir: dir} do
    write_manifest(dir, @valid_manifest)

    assert {:ok, module} = JsonLoader.load(dir)
    assert module == Minga.Extension.Plugin.HelloWorld
    assert module.name() == module
    assert module.description() == "A simple greeting plugin"
    assert module.version() == "0.1.0"
    assert module.init([]) == {:ok, %{}}
    assert [{:session_start, hook_opts}] = module.__hook_schema__()
    assert hook_opts[:command] == Path.join(dir, "hooks/hello.sh")
    assert module.__skill_schema__() == [Path.join(dir, "skills/greet")]
    assert [{"my_mcp", mcp_opts}] = module.__mcp_server_schema__()
    assert mcp_opts[:command] == Path.join(dir, "servers/my-mcp")
    assert mcp_opts[:args] == ["--port", "3000"]
    assert [{"greet", "Say hello", command_opts}] = module.__slash_command_schema__()
    assert command_opts[:command] == Path.join(dir, "commands/greet.sh")

    manifest = Minga.Extension.Manifest.from_module(module, :path)

    assert {length(manifest.hooks), length(manifest.skills), length(manifest.mcp_servers),
            length(manifest.slash_commands)} == {1, 1, 1, 1}
  end

  test "uses the trusted registry name when provided", %{dir: dir} do
    write_manifest(dir, @valid_manifest)
    assert {:ok, module} = JsonLoader.load(dir, :trusted_plugin)
    assert module.name() == :trusted_plugin
  end

  test "reports invalid manifest input without generating a module", %{dir: dir} do
    assert {:error, missing} = JsonLoader.load(dir)
    assert missing =~ "failed to read"

    File.write!(Path.join(dir, "plugin.json"), "{not valid json!!!")
    assert {:error, malformed} = JsonLoader.load(dir)
    assert malformed =~ "malformed JSON"

    File.write!(Path.join(dir, "plugin.json"), "[1, 2, 3]")
    assert {:error, shape} = JsonLoader.load(dir)
    assert shape =~ "must be a JSON object"
  end

  test "fills defaults and empty schemas for a minimal manifest", %{dir: dir} do
    write_manifest(dir, Jason.encode!(%{"name" => "minimal"}))

    assert {:ok, module} = JsonLoader.load(dir)
    assert module.description() =~ "Plugin from"
    assert module.version() == "0.1.0"
    assert module.__hook_schema__() == []
    assert module.__skill_schema__() == []
    assert module.__mcp_server_schema__() == []
    assert module.__slash_command_schema__() == []
    assert module.__option_schema__() == []
  end

  defp write_manifest(dir, json), do: File.write!(Path.join(dir, "plugin.json"), json)
end
