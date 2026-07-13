Code.require_file("credo/checks/no_blocking_editor_call_check.exs")

defmodule Minga.Credo.NoBlockingEditorCallCheckTest do
  use Credo.Test.Case, async: true

  alias Minga.Credo.NoBlockingEditorCallCheck

  @moduletag :credo

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp check(source_code, filename \\ "lib/minga_editor/commands/example.ex") do
    source_code
    |> to_source_file(filename)
    |> run_check(NoBlockingEditorCallCheck, [])
  end

  # ── Flagged calls ──────────────────────────────────────────────────────

  test "flags inline System.cmd" do
    """
    defmodule MingaEditor.Commands.Example do
      def run(state) do
        System.cmd("formatter", ["--stdin"], input: content)
      end
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "System.cmd"
      assert issue.message =~ "blocks the editor GenServer"
    end)
  end

  test "flags inline Client.request_sync" do
    """
    defmodule MingaEditor.Commands.Example do
      def run(state) do
        Client.request_sync(client, "textDocument/formatting", params, 5_000)
      end
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "Client.request_sync"
    end)
  end

  test "flags fully-qualified Minga.LSP.Client.request_sync" do
    """
    defmodule MingaEditor.Commands.Example do
      def run(state) do
        Minga.LSP.Client.request_sync(client, "textDocument/formatting", params, 5_000)
      end
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "Minga.LSP.Client.request_sync"
    end)
  end

  test "flags inline Task.await" do
    """
    defmodule MingaEditor.Commands.Example do
      def run(state) do
        task = Task.async(fn -> :work end)
        Task.await(task, 5_000)
      end
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "Task.await"
    end)
  end

  test "flags inline Process.sleep" do
    """
    defmodule MingaEditor.Commands.Example do
      def run(state) do
        Process.sleep(100)
      end
    end
    """
    |> check()
    |> assert_issue(fn issue ->
      assert issue.trigger == "Process.sleep"
    end)
  end

  # ── Exempt wrappers ────────────────────────────────────────────────────

  test "passes blocking call inside Task.start body" do
    """
    defmodule MingaEditor.Commands.Example do
      def run(state) do
        Task.start(fn -> System.cmd("git", ["status"]) end)
        state
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  test "passes blocking call inside Task.async body" do
    """
    defmodule MingaEditor.Commands.Example do
      def run(state) do
        Task.async(fn -> System.cmd("git", ["log"]) end)
        state
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  # ── Inline comment suppression ─────────────────────────────────────────

  test "suppresses with minga:allow-blocking comment and justification" do
    """
    defmodule MingaEditor.Commands.Example do
      def run(state) do
        System.cmd("formatter", ["--stdin"], input: content) # minga:allow-blocking — fast local binary, <10ms
      end
    end
    """
    |> check()
    |> refute_issues()
  end

  test "does not suppress bare minga:allow-blocking without justification" do
    """
    defmodule MingaEditor.Commands.Example do
      def run(state) do
        System.cmd("formatter", ["--stdin"], input: content) # minga:allow-blocking
      end
    end
    """
    |> check()
    |> assert_issue()
  end

  # ── Scope filtering ────────────────────────────────────────────────────

  test "skips files outside minga_editor/" do
    """
    defmodule Minga.Git.System do
      def run_command(args) do
        System.cmd("git", args)
      end
    end
    """
    |> check("lib/minga/git/system.ex")
    |> refute_issues()
  end

  test "skips test files" do
    """
    defmodule MingaEditor.Commands.ExampleTest do
      def test_example do
        System.cmd("echo", ["test"])
      end
    end
    """
    |> check("test/minga_editor/commands/example_test.exs")
    |> refute_issues()
  end
end
