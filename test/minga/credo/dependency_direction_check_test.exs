Code.require_file("credo/checks/dependency_direction_check.exs")

defmodule Minga.Credo.DependencyDirectionCheckTest do
  use Credo.Test.Case, async: false

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
        alias Minga.Editor.State
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
        alias Minga.Editor.Commands
      end
      """
      |> check("lib/minga/mode/normal.ex")
      |> assert_issue()
    end

    test "flags Core module depending on Buffer.Server (Layer 1)" do
      """
      defmodule Minga.Core.Decorations do
        alias Minga.Buffer.Server
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
        alias Minga.Editor.State
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
        alias Minga.Input.AgentPanel
      end
      """
      |> check("lib/minga/git/tracker.ex")
      |> assert_issue()
    end

    test "flags Agent module depending on Shell" do
      """
      defmodule Minga.Agent.Session do
        alias Minga.Shell.Traditional
      end
      """
      |> check("lib/minga/agent/session.ex")
      |> assert_issue()
    end
  end

  describe "valid downward dependencies" do
    test "Layer 2 may depend on Layer 1" do
      """
      defmodule Minga.Editor.Commands.Foo do
        alias Minga.Buffer.Server
      end
      """
      |> check("lib/minga/editor/commands/foo.ex")
      |> refute_issues()
    end

    test "Layer 2 may depend on Layer 0" do
      """
      defmodule Minga.Editor.Commands.Foo do
        alias Minga.Buffer.Document
        alias Minga.Core.Face
      end
      """
      |> check("lib/minga/editor/commands/foo.ex")
      |> refute_issues()
    end

    test "Layer 1 may depend on Layer 0" do
      """
      defmodule Minga.Buffer.Server do
        alias Minga.Buffer.Document
        alias Minga.Core.Decorations
      end
      """
      |> check("lib/minga/buffer/server.ex")
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
        alias Minga.Editor.State
        alias Minga.Buffer.Server
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
        alias Jason.Encoder
      end
      """
      |> check("lib/minga/core/some_helper.ex")
      |> refute_issues()
    end
  end
end
