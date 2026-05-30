defmodule Minga.Extension.AgentExtensionTest do
  use ExUnit.Case, async: true

  describe "hook/2 DSL macro" do
    defmodule HookExtension do
      use Minga.Extension.Agent

      hook(:pre_tool_use, tool: "write_*", command: "hooks/lint.sh")
      hook(:session_start, command: "hooks/hello.sh")

      @impl true
      def name, do: :agent_hook_ext

      @impl true
      def description, do: "Hook test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates __hook_schema__/0 with all declared hooks" do
      schema = HookExtension.__hook_schema__()

      assert schema == [
               {:pre_tool_use, [tool: "write_*", command: "hooks/lint.sh"]},
               {:session_start, [command: "hooks/hello.sh"]}
             ]
    end

    test "hooks are in declaration order" do
      events = HookExtension.__hook_schema__() |> Enum.map(&elem(&1, 0))
      assert events == [:pre_tool_use, :session_start]
    end
  end

  describe "skill/1 DSL macro" do
    defmodule SkillExtension do
      use Minga.Extension.Agent

      skill("skills/greet")
      skill("skills/refactor")
      skill("skills/deploy")

      @impl true
      def name, do: :agent_skill_ext

      @impl true
      def description, do: "Skill test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates __skill_schema__/0 with all declared skills" do
      schema = SkillExtension.__skill_schema__()
      assert schema == ["skills/greet", "skills/refactor", "skills/deploy"]
    end

    test "skills are in declaration order" do
      assert SkillExtension.__skill_schema__() == ["skills/greet", "skills/refactor", "skills/deploy"]
    end
  end

  describe "mcp_server/2 DSL macro" do
    defmodule McpServerExtension do
      use Minga.Extension.Agent

      mcp_server(:my_mcp, command: "servers/my-mcp", args: ["--port", "3000"])
      mcp_server(:db_tools, command: "servers/db-tools")

      @impl true
      def name, do: :agent_mcp_ext

      @impl true
      def description, do: "MCP server test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates __mcp_server_schema__/0 with all declared servers" do
      schema = McpServerExtension.__mcp_server_schema__()

      assert schema == [
               {:my_mcp, [command: "servers/my-mcp", args: ["--port", "3000"]]},
               {:db_tools, [command: "servers/db-tools"]}
             ]
    end

    test "MCP servers are in declaration order" do
      names = McpServerExtension.__mcp_server_schema__() |> Enum.map(&elem(&1, 0))
      assert names == [:my_mcp, :db_tools]
    end
  end

  describe "slash_command/3 DSL macro" do
    defmodule SlashCommandExtension do
      use Minga.Extension.Agent

      slash_command(:my_cmd, "Runs my custom command", command: "commands/my-cmd.sh")
      slash_command(:deploy, "Deploy the current branch", command: "commands/deploy.sh")

      @impl true
      def name, do: :agent_slash_ext

      @impl true
      def description, do: "Slash command test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates __slash_command_schema__/0 with all declared commands" do
      schema = SlashCommandExtension.__slash_command_schema__()

      assert schema == [
               {:my_cmd, "Runs my custom command", [command: "commands/my-cmd.sh"]},
               {:deploy, "Deploy the current branch", [command: "commands/deploy.sh"]}
             ]
    end

    test "slash commands are in declaration order" do
      names = SlashCommandExtension.__slash_command_schema__() |> Enum.map(&elem(&1, 0))
      assert names == [:my_cmd, :deploy]
    end

    test "descriptions are preserved" do
      descs = SlashCommandExtension.__slash_command_schema__() |> Enum.map(&elem(&1, 1))
      assert descs == ["Runs my custom command", "Deploy the current branch"]
    end
  end

  describe "option/3 DSL macro (agent surface)" do
    defmodule AgentOptionExtension do
      use Minga.Extension.Agent

      option(:auto_fix, :boolean,
        default: false,
        description: "Automatically apply lint fixes"
      )

      option(:severity, {:enum, [:error, :warning, :info]},
        default: :warning,
        description: "Minimum severity to report"
      )

      @impl true
      def name, do: :agent_opt_ext

      @impl true
      def description, do: "Agent option test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates __option_schema__/0 with all declared options" do
      schema = AgentOptionExtension.__option_schema__()

      assert schema == [
               {:auto_fix, :boolean, false, "Automatically apply lint fixes"},
               {:severity, {:enum, [:error, :warning, :info]}, :warning, "Minimum severity to report"}
             ]
    end

    test "options are in declaration order" do
      names = AgentOptionExtension.__option_schema__() |> Enum.map(&elem(&1, 0))
      assert names == [:auto_fix, :severity]
    end
  end

  describe "extension without any declarations" do
    defmodule BareAgentExtension do
      use Minga.Extension.Agent

      @impl true
      def name, do: :agent_bare

      @impl true
      def description, do: "No declarations"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates empty __option_schema__/0" do
      assert BareAgentExtension.__option_schema__() == []
    end

    test "generates empty __hook_schema__/0" do
      assert BareAgentExtension.__hook_schema__() == []
    end

    test "generates empty __skill_schema__/0" do
      assert BareAgentExtension.__skill_schema__() == []
    end

    test "generates empty __mcp_server_schema__/0" do
      assert BareAgentExtension.__mcp_server_schema__() == []
    end

    test "generates empty __slash_command_schema__/0" do
      assert BareAgentExtension.__slash_command_schema__() == []
    end
  end

  describe "default child_spec/1" do
    defmodule ChildSpecExtension do
      use Minga.Extension.Agent

      @impl true
      def name, do: :agent_childspec_ext

      @impl true
      def description, do: "Child spec test"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "returns a valid supervisor child spec" do
      spec = ChildSpecExtension.child_spec(foo: :bar)
      assert spec.id == ChildSpecExtension
      assert spec.restart == :permanent
      assert spec.type == :worker
      assert {Agent, :start_link, [fun]} = spec.start
      assert is_function(fun, 0)
      assert fun.() == [foo: :bar]
    end
  end

  describe "mixed agent DSL extension" do
    defmodule FullAgentExtension do
      use Minga.Extension.Agent

      option(:enabled, :boolean,
        default: true,
        description: "Enable the extension"
      )

      hook(:pre_tool_use, tool: "write_*", command: "hooks/lint.sh")

      skill("skills/greet")

      mcp_server(:my_mcp, command: "servers/my-mcp", args: ["--port", "3000"])

      slash_command(:my_cmd, "Runs my custom command", command: "commands/my-cmd.sh")

      @impl true
      def name, do: :agent_full_ext

      @impl true
      def description, do: "Full agent test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "all five schemas are populated" do
      assert length(FullAgentExtension.__option_schema__()) == 1
      assert length(FullAgentExtension.__hook_schema__()) == 1
      assert length(FullAgentExtension.__skill_schema__()) == 1
      assert length(FullAgentExtension.__mcp_server_schema__()) == 1
      assert length(FullAgentExtension.__slash_command_schema__()) == 1
    end
  end

  describe "extension with only hooks" do
    defmodule HooksOnlyExtension do
      use Minga.Extension.Agent

      hook(:session_start, command: "hooks/init.sh")
      hook(:session_end, command: "hooks/cleanup.sh")

      @impl true
      def name, do: :agent_hooks_only

      @impl true
      def description, do: "Hooks only"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "hooks are populated while other schemas are empty" do
      assert length(HooksOnlyExtension.__hook_schema__()) == 2
      assert HooksOnlyExtension.__option_schema__() == []
      assert HooksOnlyExtension.__skill_schema__() == []
      assert HooksOnlyExtension.__mcp_server_schema__() == []
      assert HooksOnlyExtension.__slash_command_schema__() == []
    end
  end

  describe "extension with only skills" do
    defmodule SkillsOnlyExtension do
      use Minga.Extension.Agent

      skill("skills/a")
      skill("skills/b")

      @impl true
      def name, do: :agent_skills_only

      @impl true
      def description, do: "Skills only"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "skills are populated while other schemas are empty" do
      assert length(SkillsOnlyExtension.__skill_schema__()) == 2
      assert SkillsOnlyExtension.__option_schema__() == []
      assert SkillsOnlyExtension.__hook_schema__() == []
      assert SkillsOnlyExtension.__mcp_server_schema__() == []
      assert SkillsOnlyExtension.__slash_command_schema__() == []
    end
  end

  describe "separate editor and agent modules" do
    defmodule EditorSurface do
      use Minga.Extension.Editor

      command(:my_editor_cmd, "An editor command",
        execute: {Minga.Extension.AgentExtensionTest, :noop}
      )

      keybind(:normal, "SPC m e", :my_editor_cmd, "Editor command")

      @impl true
      def name, do: :mixed_editor

      @impl true
      def description, do: "Editor half of mixed extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    defmodule AgentSurface do
      use Minga.Extension.Agent

      hook(:session_start, command: "hooks/init.sh")
      skill("skills/helper")

      @impl true
      def name, do: :mixed_agent

      @impl true
      def description, do: "Agent half of mixed extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "editor module has editor schemas but not agent schemas" do
      assert length(EditorSurface.__command_schema__()) == 1
      assert length(EditorSurface.__keybind_schema__()) == 1
      assert EditorSurface.__option_schema__() == []
      assert EditorSurface.__modeline_segment_schema__() == []
      assert EditorSurface.__capability_schema__() == []
    end

    test "agent module has agent schemas but not editor schemas" do
      assert length(AgentSurface.__hook_schema__()) == 1
      assert length(AgentSurface.__skill_schema__()) == 1
      assert AgentSurface.__option_schema__() == []
      assert AgentSurface.__mcp_server_schema__() == []
      assert AgentSurface.__slash_command_schema__() == []
    end

    test "editor and agent modules do not interfere with each other" do
      refute function_exported?(EditorSurface, :__hook_schema__, 0)
      refute function_exported?(EditorSurface, :__skill_schema__, 0)
      refute function_exported?(AgentSurface, :__command_schema__, 0)
      refute function_exported?(AgentSurface, :__keybind_schema__, 0)
    end
  end

  # Helper used as MFA target in command specs
  @spec noop(map()) :: map()
  def noop(state), do: state
end
