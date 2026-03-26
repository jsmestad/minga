Code.require_file("credo/checks/domain_boundary_check.exs")

defmodule Minga.Credo.DomainBoundaryCheckTest do
  use Credo.Test.Case, async: false

  alias Minga.Credo.DomainBoundaryCheck

  @moduletag :credo

  # Credo's test helpers need the SourceFileAST service running.
  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  # Helper: run the check against inline source code with a given filename.
  defp check(source_code, filename) do
    source_code
    |> to_source_file(filename)
    |> run_check(DomainBoundaryCheck, [])
  end

  describe "catches violations" do
    test "flags alias of internal module from outside the domain" do
      """
      defmodule Minga.Editor.Commands.Foo do
        alias Minga.Buffer.Server
      end
      """
      |> check("lib/minga/editor/commands/foo.ex")
      |> assert_issue(%{trigger: "Minga.Buffer.Server"})
    end

    test "flags import of internal module" do
      """
      defmodule Minga.Editor.Foo do
        import Minga.Config.Options
      end
      """
      |> check("lib/minga/editor/foo.ex")
      |> assert_issue(%{trigger: "Minga.Config.Options"})
    end

    test "flags require of internal module" do
      """
      defmodule Minga.Agent.Foo do
        require Minga.Buffer.Document
      end
      """
      |> check("lib/minga/agent/foo.ex")
      |> assert_issue(%{trigger: "Minga.Buffer.Document"})
    end

    test "flags use of internal module" do
      """
      defmodule Minga.Project.Foo do
        use Minga.Git.Backend
      end
      """
      |> check("lib/minga/project/foo.ex")
      |> assert_issue(%{trigger: "Minga.Git.Backend"})
    end

    test "flags deeply nested internal module" do
      """
      defmodule Minga.Editor.Foo do
        alias Minga.Buffer.Document
      end
      """
      |> check("lib/minga/editor/foo.ex")
      |> assert_issue(%{trigger: "Minga.Buffer.Document"})
    end

    test "flags multiple violations in one file" do
      """
      defmodule Minga.Agent.Foo do
        alias Minga.Buffer.Server
        alias Minga.Config.Options
        alias Minga.UI.Theme
      end
      """
      |> check("lib/minga/agent/foo.ex")
      |> assert_issues(3)
    end

    test "flags crossing from top-level module into domain" do
      """
      defmodule Minga.SomeTopLevel do
        alias Minga.Buffer.Server
      end
      """
      |> check("lib/minga/some_top_level.ex")
      |> assert_issue()
    end

    test "flags protocols and behaviours (no exceptions)" do
      """
      defmodule Minga.Agent.Foo do
        alias Minga.Command.Provider
        alias Minga.Input.Handler
      end
      """
      |> check("lib/minga/agent/foo.ex")
      |> assert_issues(2)
    end
  end

  describe "allows valid references" do
    test "allows alias of facade module" do
      """
      defmodule Minga.Editor.Foo do
        alias Minga.Buffer
      end
      """
      |> check("lib/minga/editor/foo.ex")
      |> refute_issues()
    end

    test "allows intra-domain references" do
      """
      defmodule Minga.Buffer.Server do
        alias Minga.Buffer.Document
      end
      """
      |> check("lib/minga/buffer/server.ex")
      |> refute_issues()
    end

    test "allows references to non-domain modules" do
      """
      defmodule Minga.Editor.Foo do
        alias Minga.Events
        alias Minga.Log
        alias Minga.Clipboard
      end
      """
      |> check("lib/minga/editor/foo.ex")
      |> refute_issues()
    end

    test "skips test files entirely" do
      """
      defmodule Minga.Buffer.ServerTest do
        alias Minga.Buffer.Server
        alias Minga.Config.Options
      end
      """
      |> check("test/minga/buffer/server_test.exs")
      |> refute_issues()
    end

    test "allows multiple facade references" do
      """
      defmodule Minga.Editor.Foo do
        alias Minga.Buffer
        alias Minga.Config
        alias Minga.UI
      end
      """
      |> check("lib/minga/editor/foo.ex")
      |> refute_issues()
    end
  end

  describe "covers all 14 domains" do
    # Map domain atoms to their facade module name segments.
    # Most are Macro.camelize, but "ui" -> "UI" is a special case.
    domain_facades = %{
      "agent" => "Agent",
      "buffer" => "Buffer",
      "editing" => "Editing",
      "frontend" => "Frontend",
      "ui" => "UI",
      "project" => "Project",
      "language" => "Language",
      "session" => "Session",
      "config" => "Config",
      "keymap" => "Keymap",
      "command" => "Command",
      "git" => "Git",
      "input" => "Input",
      "mode" => "Mode"
    }

    for {domain, segment} <- domain_facades do
      test "catches violations targeting #{domain} domain" do
        facade = "Minga.#{unquote(segment)}"
        internal = "#{facade}.SomeInternal"

        """
        defmodule Minga.Editor.TestModule do
          alias #{internal}
        end
        """
        |> check("lib/minga/editor/test_module.ex")
        |> assert_issue(fn issue ->
          assert issue.message =~ facade
        end)
      end
    end
  end

  describe "message format" do
    test "suggests the correct facade module" do
      """
      defmodule Minga.Editor.Foo do
        alias Minga.Git.Tracker
      end
      """
      |> check("lib/minga/editor/foo.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Use the `Minga.Git` facade instead."
      end)
    end

    test "names the violating form and module" do
      """
      defmodule Minga.Agent.Foo do
        alias Minga.Buffer.Server
      end
      """
      |> check("lib/minga/agent/foo.ex")
      |> assert_issue(fn issue ->
        assert issue.message =~ "alias Minga.Buffer.Server"
      end)
    end
  end
end
