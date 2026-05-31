defmodule Minga.Extension.ManifestAgentTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Manifest

  describe "from_module/2 with agent-only extension" do
    defmodule AgentOnlyExt do
      use Minga.Extension.Agent

      hook(:session_start, command: "hooks/init.sh")
      hook(:pre_tool_use, tool: "write_*", command: "hooks/lint.sh")

      skill("skills/greet")
      skill("skills/deploy")

      mcp_server(:my_mcp, command: "servers/my-mcp", args: ["--port", "3000"])

      slash_command(:deploy, "Deploy current branch", command: "commands/deploy.sh")
      slash_command(:rollback, "Rollback last deploy", command: "commands/rollback.sh")

      @impl true
      def name, do: :manifest_agent_only

      @impl true
      def description, do: "Agent-only extension for manifest test"

      @impl true
      def version, do: "1.2.3"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "populates all four agent fields" do
      manifest = Manifest.from_module(AgentOnlyExt, :path)

      assert manifest.name == :manifest_agent_only
      assert manifest.description == "Agent-only extension for manifest test"
      assert manifest.version == "1.2.3"
      assert manifest.source == :path

      assert length(manifest.hooks) == 2
      assert length(manifest.skills) == 2
      assert length(manifest.mcp_servers) == 1
      assert length(manifest.slash_commands) == 2
    end

    test "hooks are in declaration order" do
      manifest = Manifest.from_module(AgentOnlyExt, :path)
      events = Enum.map(manifest.hooks, &elem(&1, 0))
      assert events == [:session_start, :pre_tool_use]
    end

    test "hooks preserve their options" do
      manifest = Manifest.from_module(AgentOnlyExt, :path)
      [{_, opts1}, {_, opts2}] = manifest.hooks
      assert Keyword.get(opts1, :command) == "hooks/init.sh"
      assert Keyword.get(opts2, :tool) == "write_*"
      assert Keyword.get(opts2, :command) == "hooks/lint.sh"
    end

    test "skills preserve paths" do
      manifest = Manifest.from_module(AgentOnlyExt, :path)
      assert manifest.skills == ["skills/greet", "skills/deploy"]
    end

    test "mcp_servers include options" do
      manifest = Manifest.from_module(AgentOnlyExt, :path)
      [{name, opts}] = manifest.mcp_servers
      assert name == :my_mcp
      assert Keyword.get(opts, :command) == "servers/my-mcp"
      assert Keyword.get(opts, :args) == ["--port", "3000"]
    end

    test "slash_commands include descriptions and options" do
      manifest = Manifest.from_module(AgentOnlyExt, :path)
      [{name1, desc1, opts1}, {name2, desc2, _opts2}] = manifest.slash_commands
      assert name1 == :deploy
      assert desc1 == "Deploy current branch"
      assert Keyword.get(opts1, :command) == "commands/deploy.sh"
      assert name2 == :rollback
      assert desc2 == "Rollback last deploy"
    end

    test "editor fields are empty for agent-only extension" do
      manifest = Manifest.from_module(AgentOnlyExt, :path)
      assert manifest.commands == []
      assert manifest.keybindings == []
      assert manifest.modeline_segments == []
      assert manifest.capabilities == []
    end

    test "all source types are accepted" do
      for source <- [:path, :git, :hex, :module] do
        manifest = Manifest.from_module(AgentOnlyExt, source)
        assert manifest.source == source
      end
    end
  end

  describe "from_module/2 with editor-only extension" do
    defmodule EditorOnlyExt do
      use Minga.Extension.Editor

      command(:test_cmd, "A test command", execute: {Minga.Extension.ManifestAgentTest, :noop})

      keybind(:normal, "SPC m t", :test_cmd, "Test command")

      capability(:filetype, :org)

      @impl true
      def name, do: :manifest_editor_only

      @impl true
      def description, do: "Editor-only extension for manifest test"

      @impl true
      def version, do: "2.0.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "editor fields are populated" do
      manifest = Manifest.from_module(EditorOnlyExt, :module)

      assert manifest.name == :manifest_editor_only
      assert manifest.source == :module
      assert length(manifest.commands) == 1
      assert length(manifest.keybindings) == 1
      assert length(manifest.capabilities) == 1
    end

    test "agent fields are empty for editor-only extension" do
      manifest = Manifest.from_module(EditorOnlyExt, :module)

      assert manifest.hooks == []
      assert manifest.skills == []
      assert manifest.mcp_servers == []
      assert manifest.slash_commands == []
    end
  end

  describe "from_module/2 with bare agent extension (no declarations)" do
    defmodule BareAgentExt do
      use Minga.Extension.Agent

      @impl true
      def name, do: :manifest_bare_agent

      @impl true
      def description, do: "Bare agent extension"

      @impl true
      def version, do: "0.0.1"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "all agent fields are empty lists" do
      manifest = Manifest.from_module(BareAgentExt, :path)
      assert manifest.hooks == []
      assert manifest.skills == []
      assert manifest.mcp_servers == []
      assert manifest.slash_commands == []
    end

    test "required fields are still populated" do
      manifest = Manifest.from_module(BareAgentExt, :path)
      assert manifest.name == :manifest_bare_agent
      assert manifest.description == "Bare agent extension"
      assert manifest.version == "0.0.1"
    end
  end

  describe "paired editor and agent modules (dual-surface via separate modules)" do
    # Using both `use Minga.Extension.Editor` and `use Minga.Extension.Agent`
    # in a single module causes a compile warning (duplicate @behaviour).
    # The supported pattern is separate modules. This test verifies that
    # Manifest.from_module/2 works correctly with each surface module, and
    # that neither surface's schema functions interfere with the other.

    defmodule PairedEditorSurface do
      use Minga.Extension.Editor

      command(:paired_cmd, "Paired editor command",
        execute: {Minga.Extension.ManifestAgentTest, :noop}
      )

      keybind(:normal, "SPC m p", :paired_cmd, "Paired binding")

      modeline_segment :paired_status do
        _ctx = ctx
        {" PAIRED ", :green, :black, [], nil}
      end

      capability(:filetype, :elixir)

      @impl true
      def name, do: :manifest_paired_editor

      @impl true
      def description, do: "Editor half of paired extension"

      @impl true
      def version, do: "4.0.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    defmodule PairedAgentSurface do
      use Minga.Extension.Agent

      hook(:session_start, command: "hooks/paired.sh")
      skill("skills/paired")
      mcp_server(:paired_mcp, command: "servers/paired-mcp")
      slash_command(:paired_slash, "Paired slash", command: "commands/paired.sh")

      @impl true
      def name, do: :manifest_paired_agent

      @impl true
      def description, do: "Agent half of paired extension"

      @impl true
      def version, do: "4.0.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "editor manifest has editor fields but no agent fields" do
      manifest = Manifest.from_module(PairedEditorSurface, :path)

      assert length(manifest.commands) == 1
      assert length(manifest.keybindings) == 1
      assert length(manifest.modeline_segments) == 1
      assert length(manifest.capabilities) == 1

      assert manifest.hooks == []
      assert manifest.skills == []
      assert manifest.mcp_servers == []
      assert manifest.slash_commands == []
    end

    test "agent manifest has agent fields but no editor fields" do
      manifest = Manifest.from_module(PairedAgentSurface, :path)

      assert length(manifest.hooks) == 1
      assert length(manifest.skills) == 1
      assert length(manifest.mcp_servers) == 1
      assert length(manifest.slash_commands) == 1

      assert manifest.commands == []
      assert manifest.keybindings == []
      assert manifest.modeline_segments == []
      assert manifest.capabilities == []
    end

    test "editor module lacks agent schema functions entirely" do
      refute function_exported?(PairedEditorSurface, :__hook_schema__, 0)
      refute function_exported?(PairedEditorSurface, :__skill_schema__, 0)
      refute function_exported?(PairedEditorSurface, :__mcp_server_schema__, 0)
      refute function_exported?(PairedEditorSurface, :__slash_command_schema__, 0)
    end

    test "agent module lacks editor schema functions entirely" do
      refute function_exported?(PairedAgentSurface, :__command_schema__, 0)
      refute function_exported?(PairedAgentSurface, :__keybind_schema__, 0)
      refute function_exported?(PairedAgentSurface, :__modeline_segment_schema__, 0)
      refute function_exported?(PairedAgentSurface, :__capability_schema__, 0)
    end

    test "both modules generate __option_schema__/0 (shared macro)" do
      assert function_exported?(PairedEditorSurface, :__option_schema__, 0)
      assert function_exported?(PairedAgentSurface, :__option_schema__, 0)
      assert PairedEditorSurface.__option_schema__() == []
      assert PairedAgentSurface.__option_schema__() == []
    end

    test "editor modeline segment render function is callable" do
      result = PairedEditorSurface.__modeline_segment_paired_status__(%{})
      assert result == {" PAIRED ", :green, :black, [], nil}
    end
  end

  describe "@before_compile generates all schema functions" do
    # Verifies that the @before_compile callback in each surface macro
    # generates the expected schema functions, even when no declarations
    # are made (empty schemas).

    defmodule BareEditorForCompile do
      use Minga.Extension.Editor

      @impl true
      def name, do: :bare_editor_compile

      @impl true
      def description, do: "Bare editor for compile test"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    defmodule BareAgentForCompile do
      use Minga.Extension.Agent

      @impl true
      def name, do: :bare_agent_compile

      @impl true
      def description, do: "Bare agent for compile test"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "Editor @before_compile generates all five editor schema functions" do
      assert function_exported?(BareEditorForCompile, :__option_schema__, 0)
      assert function_exported?(BareEditorForCompile, :__command_schema__, 0)
      assert function_exported?(BareEditorForCompile, :__keybind_schema__, 0)
      assert function_exported?(BareEditorForCompile, :__modeline_segment_schema__, 0)
      assert function_exported?(BareEditorForCompile, :__capability_schema__, 0)
    end

    test "Agent @before_compile generates all five agent schema functions" do
      assert function_exported?(BareAgentForCompile, :__option_schema__, 0)
      assert function_exported?(BareAgentForCompile, :__hook_schema__, 0)
      assert function_exported?(BareAgentForCompile, :__skill_schema__, 0)
      assert function_exported?(BareAgentForCompile, :__mcp_server_schema__, 0)
      assert function_exported?(BareAgentForCompile, :__slash_command_schema__, 0)
    end

    test "Editor @before_compile does not generate agent-specific functions" do
      refute function_exported?(BareEditorForCompile, :__hook_schema__, 0)
      refute function_exported?(BareEditorForCompile, :__skill_schema__, 0)
      refute function_exported?(BareEditorForCompile, :__mcp_server_schema__, 0)
      refute function_exported?(BareEditorForCompile, :__slash_command_schema__, 0)
    end

    test "Agent @before_compile does not generate editor-specific functions" do
      refute function_exported?(BareAgentForCompile, :__command_schema__, 0)
      refute function_exported?(BareAgentForCompile, :__keybind_schema__, 0)
      refute function_exported?(BareAgentForCompile, :__modeline_segment_schema__, 0)
      refute function_exported?(BareAgentForCompile, :__capability_schema__, 0)
    end

    test "bare editor schemas are all empty" do
      assert BareEditorForCompile.__option_schema__() == []
      assert BareEditorForCompile.__command_schema__() == []
      assert BareEditorForCompile.__keybind_schema__() == []
      assert BareEditorForCompile.__modeline_segment_schema__() == []
      assert BareEditorForCompile.__capability_schema__() == []
    end

    test "bare agent schemas are all empty" do
      assert BareAgentForCompile.__option_schema__() == []
      assert BareAgentForCompile.__hook_schema__() == []
      assert BareAgentForCompile.__skill_schema__() == []
      assert BareAgentForCompile.__mcp_server_schema__() == []
      assert BareAgentForCompile.__slash_command_schema__() == []
    end
  end

  # Helper used as MFA target in command specs
  @spec noop(map()) :: map()
  def noop(state), do: state
end
