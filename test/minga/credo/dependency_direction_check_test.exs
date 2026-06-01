Code.require_file("credo/checks/dependency_direction_check.exs")

defmodule Minga.Credo.DependencyDirectionCheckTest do
  use Credo.Test.Case, async: true

  alias Minga.Credo.DependencyDirectionCheck

  @moduletag :credo

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp check(source_code, filename) do
    source_code
    |> to_source_file(filename)
    |> run_check(DependencyDirectionCheck, [])
  end

  describe "Layer 0 violations (pure modules must not depend on Layer 1 or 2)" do
    test "flags Layer 0 module aliasing a Layer 1 module" do
      """
      defmodule Minga.Core.SomeHelper do
        alias Minga.Config.Options
      end
      """
      |> check("lib/minga/core/some_helper.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Layer 0"
        assert issue.message =~ "Layer 1"
      end)
    end

    test "flags Layer 0 module aliasing a Layer 2 module" do
      """
      defmodule Minga.Editing.Motion.SomeMotion do
        alias MingaEditor.State
      end
      """
      |> check("lib/minga/editing/motion/some_motion.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Layer 0"
        assert issue.message =~ "Layer 2"
      end)
    end

    test "flags Mode FSM module depending on Editor" do
      """
      defmodule Minga.Mode.Normal do
        alias MingaEditor.Commands
      end
      """
      |> check("lib/minga/mode/normal.ex")
      |> assert_issue()
    end

    test "flags Core module depending on Buffer.Process (Layer 1)" do
      """
      defmodule Minga.Core.Decorations do
        alias Minga.Buffer.Process, as: BufferProcess
      end
      """
      |> check("lib/minga/core/decorations.ex")
      |> assert_issue()
    end
  end

  describe "Layer 1 violations (services must not depend on Layer 2)" do
    test "flags Layer 1 module aliasing Editor (Layer 2)" do
      """
      defmodule Minga.LSP.Client do
        alias MingaEditor.State
      end
      """
      |> check("lib/minga/lsp/client.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Layer 1"
        assert issue.message =~ "Layer 2"
      end)
    end

    test "flags Git module depending on Input handler" do
      """
      defmodule Minga.Git.Tracker do
        alias MingaEditor.Input.AgentPanel
      end
      """
      |> check("lib/minga/git/tracker.ex")
      |> assert_issue()
    end

    test "flags Agent module depending on Shell" do
      """
      defmodule MingaAgent.Session do
        alias MingaEditor.Shell.Traditional
      end
      """
      |> check("lib/minga/agent/session.ex")
      |> assert_issue()
    end
  end

  describe "MingaAgent internal level violations" do
    test "flags Agent Level 0 contracts depending on Agent Level 1 runtime services" do
      """
      defmodule MingaAgent.Tool.Spec do
        alias MingaAgent.Tool.Registry
      end
      """
      |> check("lib/minga_agent/tool/spec.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Agent Level 0"
        assert issue.message =~ "Agent Level 1"
      end)
    end

    test "flags Agent Level 0 extension payloads depending on Agent Level 2 presentation" do
      """
      defmodule MingaEditor.Agent.SlashCommand.Command do
        alias MingaEditor.Agent.UIState
      end
      """
      |> check("lib/minga_editor/agent/slash_command/command.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Agent Level 0"
        assert issue.message =~ "Agent Level 2"
      end)
    end

    test "flags Agent Level 1 runtime services depending on Agent Level 2 presentation" do
      """
      defmodule MingaAgent.Session do
        alias MingaEditor.Agent.UIState
      end
      """
      |> check("lib/minga_agent/session.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Agent Level 1"
        assert issue.message =~ "Agent Level 2"
      end)
    end

    test "flags Agent Level 1 runtime services depending on bundled tool packs" do
      """
      defmodule MingaAgent.Tool.Registry do
        alias MingaAgent.ToolPacks.ReadOnly
      end
      """
      |> check("lib/minga_agent/tool/registry.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Agent Level 1"
        assert issue.message =~ "Agent Level 2"
      end)
    end

    test "uses declared acronym module names for source classification" do
      """
      defmodule MingaAgent.MCP.Tool do
        alias MingaAgent.MCP.Registry
      end
      """
      |> check("lib/minga_agent/mcp/tool.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Agent Level 0"
        assert issue.message =~ "Agent Level 1"
      end)
    end

    test "flags grouped aliases that cross Agent levels" do
      """
      defmodule MingaAgent.Tool.Spec do
        alias MingaAgent.Tool.{Registry, Spec}
      end
      """
      |> check("lib/minga_agent/tool/spec.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Agent Level 0"
        assert issue.message =~ "Agent Level 1"
      end)
    end

    test "flags direct remote calls that cross Agent levels" do
      """
      defmodule MingaAgent.Event do
        @type t :: %{status: MingaAgent.Session.status()}
      end
      """
      |> check("lib/minga_agent/event.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Agent Level 0"
        assert issue.message =~ "Agent Level 1"
      end)
    end

    test "flags direct module literals that cross Agent levels" do
      """
      defmodule MingaAgent.Event do
        @default_provider MingaAgent.Providers.Native
      end
      """
      |> check("lib/minga_agent/event.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Agent Level 0"
        assert issue.message =~ "Agent Level 1"
      end)
    end

    test "flags two-segment direct module literals that cross Agent levels" do
      """
      defmodule MingaAgent.Event do
        @config MingaAgent.Config
      end
      """
      |> check("lib/minga_agent/event.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Agent Level 0"
        assert issue.message =~ "Agent Level 1"
      end)
    end

    test "flags direct struct literals that cross Agent levels" do
      """
      defmodule MingaAgent.Event do
        def new_config, do: %MingaAgent.Config{}
      end
      """
      |> check("lib/minga_agent/event.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Agent Level 0"
        assert issue.message =~ "Agent Level 1"
      end)
    end

    test "flags bare module literals in function bodies that cross Agent levels" do
      """
      defmodule MingaAgent.Event do
        def default_provider, do: MingaAgent.Providers.Native
      end
      """
      |> check("lib/minga_agent/event.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Agent Level 0"
        assert issue.message =~ "Agent Level 1"
      end)
    end

    test "reports struct types in attributes only once" do
      """
      defmodule MingaAgent.Event do
        @type t :: %MingaAgent.Config{}
      end
      """
      |> check("lib/minga_agent/event.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Agent Level 0"
        assert issue.message =~ "Agent Level 1"
      end)
    end

    test "flags Level 0 editor payloads depending on non-agent editor presentation" do
      """
      defmodule MingaEditor.Agent.SlashCommand.Command do
        alias MingaEditor.State
      end
      """
      |> check("lib/minga_editor/agent/slash_command/command.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Agent Level 0"
        assert issue.message =~ "Agent Level 2"
      end)
    end
  end

  describe "MingaAgent valid internal dependencies" do
    test "Agent Level 1 runtime services may depend on Agent Level 0 contracts" do
      """
      defmodule MingaAgent.Tool.Registry do
        alias MingaAgent.Tool.Spec
      end
      """
      |> check("lib/minga_agent/tool/registry.ex")
      |> refute_issues()
    end

    test "Agent Level 2 presentation may depend on Agent Level 1 runtime services" do
      """
      defmodule MingaEditor.Agent.Events do
        alias MingaAgent.Session
      end
      """
      |> check("lib/minga_editor/agent/events.ex")
      |> refute_issues()
    end

    test "Agent Level 0 contracts may depend on Agent Level 0 value types" do
      """
      defmodule MingaAgent.Event do
        alias MingaAgent.TurnUsage
      end
      """
      |> check("lib/minga_agent/event.ex")
      |> refute_issues()
    end
  end

  describe "valid downward dependencies" do
    test "Layer 2 may depend on Layer 1" do
      """
      defmodule MingaEditor.Commands.Foo do
        alias Minga.Buffer.Process, as: BufferProcess
      end
      """
      |> check("lib/minga/editor/commands/foo.ex")
      |> refute_issues()
    end

    test "Layer 2 may depend on Layer 0" do
      """
      defmodule MingaEditor.Commands.Foo do
        alias Minga.Buffer.Document
        alias Minga.Core.Face
      end
      """
      |> check("lib/minga/editor/commands/foo.ex")
      |> refute_issues()
    end

    test "Layer 1 may depend on Layer 0" do
      """
      defmodule Minga.Buffer.Process do
        alias Minga.Buffer.Document
        alias Minga.Core.Decorations
      end
      """
      |> check("lib/minga/buffer/process.ex")
      |> refute_issues()
    end

    test "Layer 0 may depend on other Layer 0 modules" do
      """
      defmodule Minga.Editing.Motion.Word do
        alias Minga.Buffer.Document
        alias Minga.Core.Unicode
      end
      """
      |> check("lib/minga/editing/motion/word.ex")
      |> refute_issues()
    end

    test "Layer 1 may depend on other Layer 1 modules" do
      """
      defmodule Minga.LSP.Client do
        alias Minga.Config.Options
        alias Minga.Language.Registry
      end
      """
      |> check("lib/minga/lsp/client.ex")
      |> refute_issues()
    end
  end

  describe "cross-cutting modules" do
    test "any layer may use cross-cutting modules" do
      """
      defmodule Minga.Core.SomeHelper do
        alias Minga.Events
        alias Minga.Log
        alias Minga.Telemetry
        alias Minga.Clipboard
      end
      """
      |> check("lib/minga/core/some_helper.ex")
      |> refute_issues()
    end
  end

  describe "test files" do
    test "skips test files entirely" do
      """
      defmodule Minga.Core.FaceTest do
        alias MingaEditor.State
        alias Minga.Buffer.Process, as: BufferProcess
      end
      """
      |> check("test/minga/core/face_test.exs")
      |> refute_issues()
    end
  end

  describe "non-Minga modules" do
    test "ignores external library references" do
      """
      defmodule Minga.Core.SomeHelper do
        alias Phoenix.Socket
        alias JSON.Encoder
      end
      """
      |> check("lib/minga/core/some_helper.ex")
      |> refute_issues()
    end
  end
end
