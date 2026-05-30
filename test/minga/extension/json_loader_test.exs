defmodule Minga.Extension.JsonLoaderTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.JsonLoader

  # Ensure the hook event atoms exist before tests run, since the loader
  # uses String.to_existing_atom/1 for event names.
  _ = :session_start
  _ = :pre_tool_use

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
                    "skills" => [
                      "${MINGA_PLUGIN_ROOT}/skills/greet"
                    ],
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

  setup do
    dir = Path.join(System.tmp_dir!(), "json_loader_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  describe "load/1 with valid manifest" do
    test "creates a working extension module", %{dir: dir} do
      write_manifest(dir, @valid_manifest)

      assert {:ok, module} = JsonLoader.load(dir)
      assert module == Minga.Extension.Plugin.HelloWorld

      assert module.name() == :"hello-world"
      assert module.description() == "A simple greeting plugin"
      assert module.version() == "0.1.0"
      assert module.init([]) == {:ok, %{}}
    end

    test "generates correct hook schema", %{dir: dir} do
      write_manifest(dir, @valid_manifest)

      assert {:ok, module} = JsonLoader.load(dir)

      hooks = module.__hook_schema__()
      assert length(hooks) == 1
      assert {:session_start, opts} = hd(hooks)
      assert Keyword.get(opts, :command) == Path.join(dir, "hooks/hello.sh")
    end

    test "generates correct skill schema", %{dir: dir} do
      write_manifest(dir, @valid_manifest)

      assert {:ok, module} = JsonLoader.load(dir)

      skills = module.__skill_schema__()
      assert skills == [Path.join(dir, "skills/greet")]
    end

    test "generates correct mcp_server schema", %{dir: dir} do
      write_manifest(dir, @valid_manifest)

      assert {:ok, module} = JsonLoader.load(dir)

      servers = module.__mcp_server_schema__()
      assert length(servers) == 1
      assert {:my_mcp, opts} = hd(servers)
      assert Keyword.get(opts, :command) == Path.join(dir, "servers/my-mcp")
      assert Keyword.get(opts, :args) == ["--port", "3000"]
    end

    test "generates correct slash_command schema", %{dir: dir} do
      write_manifest(dir, @valid_manifest)

      assert {:ok, module} = JsonLoader.load(dir)

      commands = module.__slash_command_schema__()
      assert length(commands) == 1
      assert {:greet, "Say hello", opts} = hd(commands)
      assert Keyword.get(opts, :command) == Path.join(dir, "commands/greet.sh")
    end
  end

  describe "${MINGA_PLUGIN_ROOT} substitution" do
    test "replaces placeholder in all string values", %{dir: dir} do
      write_manifest(dir, @valid_manifest)

      assert {:ok, module} = JsonLoader.load(dir)

      # Hook command
      [{_event, hook_opts}] = module.__hook_schema__()
      assert Keyword.get(hook_opts, :command) == Path.join(dir, "hooks/hello.sh")
      refute String.contains?(Keyword.get(hook_opts, :command), "${MINGA_PLUGIN_ROOT}")

      # Skills
      [skill_path] = module.__skill_schema__()
      assert skill_path == Path.join(dir, "skills/greet")
      refute String.contains?(skill_path, "${MINGA_PLUGIN_ROOT}")

      # MCP server
      [{_name, mcp_opts}] = module.__mcp_server_schema__()
      assert Keyword.get(mcp_opts, :command) == Path.join(dir, "servers/my-mcp")
      refute String.contains?(Keyword.get(mcp_opts, :command), "${MINGA_PLUGIN_ROOT}")

      # Slash command
      [{_name, _desc, cmd_opts}] = module.__slash_command_schema__()
      assert Keyword.get(cmd_opts, :command) == Path.join(dir, "commands/greet.sh")
      refute String.contains?(Keyword.get(cmd_opts, :command), "${MINGA_PLUGIN_ROOT}")
    end

    test "does not alter non-string values", %{dir: dir} do
      manifest =
        Jason.encode!(%{
          "name" => "num-test",
          "hooks" => [
            %{"event" => "session_start", "command" => "${MINGA_PLUGIN_ROOT}/hook.sh"}
          ],
          "mcp_servers" => [
            %{
              "name" => "svc",
              "command" => "${MINGA_PLUGIN_ROOT}/svc",
              "args" => ["--port", "3000"]
            }
          ]
        })

      write_manifest(dir, manifest)

      assert {:ok, module} = JsonLoader.load(dir)

      # The args list should still have plain strings (port number as string, not substituted weirdly)
      [{_name, opts}] = module.__mcp_server_schema__()
      assert Keyword.get(opts, :args) == ["--port", "3000"]
    end
  end

  describe "error handling" do
    test "missing plugin.json returns error", %{dir: dir} do
      assert {:error, msg} = JsonLoader.load(dir)
      assert msg =~ "failed to read"
      assert msg =~ "plugin.json"
    end

    test "malformed JSON returns error", %{dir: dir} do
      File.write!(Path.join(dir, "plugin.json"), "{not valid json!!!")

      assert {:error, msg} = JsonLoader.load(dir)
      assert msg =~ "malformed JSON"
    end

    test "JSON array instead of object returns error", %{dir: dir} do
      File.write!(Path.join(dir, "plugin.json"), "[1, 2, 3]")

      assert {:error, msg} = JsonLoader.load(dir)
      assert msg =~ "must be a JSON object"
    end

    test "unknown hook event atom returns error", %{dir: dir} do
      manifest =
        Jason.encode!(%{
          "name" => "bad-hook",
          "hooks" => [
            %{
              "event" =>
                "this_atom_definitely_does_not_exist_#{:erlang.unique_integer([:positive])}",
              "command" => "hook.sh"
            }
          ]
        })

      write_manifest(dir, manifest)

      assert {:error, msg} = JsonLoader.load(dir)
      assert msg =~ "unknown hook event"
    end
  end

  describe "missing name fallback" do
    test "uses directory basename when name field is absent", %{dir: dir} do
      manifest =
        Jason.encode!(%{
          "description" => "Nameless plugin",
          "version" => "0.2.0"
        })

      write_manifest(dir, manifest)

      assert {:ok, module} = JsonLoader.load(dir)

      # Module name derived from directory basename
      basename = Path.basename(dir)
      expected_module = Module.concat(Minga.Extension.Plugin, Macro.camelize(basename))
      assert module == expected_module

      # name callback returns the directory basename as an atom
      assert module.name() == String.to_atom(basename)
      assert module.description() == "Nameless plugin"
      assert module.version() == "0.2.0"
    end

    test "uses default description when description field is absent", %{dir: dir} do
      manifest = Jason.encode!(%{"name" => "no-desc"})
      write_manifest(dir, manifest)

      assert {:ok, module} = JsonLoader.load(dir)
      assert module.description() =~ "Plugin from"
    end

    test "uses default version when version field is absent", %{dir: dir} do
      manifest = Jason.encode!(%{"name" => "no-ver"})
      write_manifest(dir, manifest)

      assert {:ok, module} = JsonLoader.load(dir)
      assert module.version() == "0.1.0"
    end
  end

  describe "generated module schemas" do
    test "empty manifest produces empty schemas", %{dir: dir} do
      manifest = Jason.encode!(%{"name" => "empty-plugin"})
      write_manifest(dir, manifest)

      assert {:ok, module} = JsonLoader.load(dir)

      assert module.__hook_schema__() == []
      assert module.__skill_schema__() == []
      assert module.__mcp_server_schema__() == []
      assert module.__slash_command_schema__() == []
      assert module.__option_schema__() == []
    end

    test "multiple hooks are preserved in order", %{dir: dir} do
      manifest =
        Jason.encode!(%{
          "name" => "multi-hook",
          "hooks" => [
            %{"event" => "session_start", "command" => "first.sh"},
            %{"event" => "pre_tool_use", "tool" => "write_*", "command" => "second.sh"}
          ]
        })

      write_manifest(dir, manifest)

      assert {:ok, module} = JsonLoader.load(dir)

      hooks = module.__hook_schema__()
      assert length(hooks) == 2
      assert {:session_start, _} = Enum.at(hooks, 0)
      assert {:pre_tool_use, opts} = Enum.at(hooks, 1)
      assert Keyword.get(opts, :tool) == "write_*"
      assert Keyword.get(opts, :command) == "second.sh"
    end

    test "multiple skills are preserved in order", %{dir: dir} do
      manifest =
        Jason.encode!(%{
          "name" => "multi-skill",
          "skills" => ["skills/a", "skills/b", "skills/c"]
        })

      write_manifest(dir, manifest)

      assert {:ok, module} = JsonLoader.load(dir)
      assert module.__skill_schema__() == ["skills/a", "skills/b", "skills/c"]
    end

    test "module can be loaded into a Manifest struct", %{dir: dir} do
      write_manifest(dir, @valid_manifest)

      assert {:ok, module} = JsonLoader.load(dir)

      manifest = Minga.Extension.Manifest.from_module(module, :path)
      assert manifest.name == :"hello-world"
      assert manifest.description == "A simple greeting plugin"
      assert manifest.version == "0.1.0"
      assert length(manifest.hooks) == 1
      assert length(manifest.skills) == 1
      assert length(manifest.mcp_servers) == 1
      assert length(manifest.slash_commands) == 1
    end
  end

  defp write_manifest(dir, json) do
    File.write!(Path.join(dir, "plugin.json"), json)
  end
end
