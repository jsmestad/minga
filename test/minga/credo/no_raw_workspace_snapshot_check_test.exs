Code.require_file("credo/checks/no_raw_workspace_snapshot_check.exs")

defmodule Minga.Credo.NoRawWorkspaceSnapshotCheckTest do
  use Credo.Test.Case, async: true

  alias Minga.Credo.NoRawWorkspaceSnapshotCheck

  @moduletag :credo

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp check(source_code, filename \\ "lib/minga_editor/session/snapshot.ex") do
    source_code
    |> to_source_file(filename)
    |> run_check(NoRawWorkspaceSnapshotCheck, [])
  end

  describe "flags workspace-related Map.from_struct calls" do
    test "flags Map.from_struct(workspace)" do
      """
      defmodule MingaEditor.BadSnapshot do
        def snapshot(workspace) do
          Map.from_struct(workspace)
        end
      end
      """
      |> check()
      |> assert_issue(fn issue ->
        assert issue.message =~ "TabContext.from_workspace/1"
        assert issue.message =~ "#1403"
      end)
    end

    test "flags Map.from_struct(state.workspace)" do
      """
      defmodule MingaEditor.BadSnapshot do
        def snapshot(state) do
          Map.from_struct(state.workspace)
        end
      end
      """
      |> check()
      |> assert_issue(fn issue ->
        assert issue.trigger == "Map.from_struct"
      end)
    end

    test "flags Map.from_struct(ws)" do
      """
      defmodule MingaEditor.BadSnapshot do
        def snapshot(ws) do
          Map.from_struct(ws)
        end
      end
      """
      |> check()
      |> assert_issue()
    end
  end

  describe "ignores non-workspace Map.from_struct calls" do
    test "allows Map.from_struct(theme)" do
      """
      defmodule MingaEditor.ThemeConverter do
        def to_map(theme) do
          Map.from_struct(theme)
        end
      end
      """
      |> check()
      |> refute_issues()
    end

    test "allows Map.from_struct(tb)" do
      """
      defmodule MingaEditor.ToolbarConverter do
        def to_map(tb) do
          Map.from_struct(tb)
        end
      end
      """
      |> check()
      |> refute_issues()
    end
  end

  describe "skips test files" do
    test "allows Map.from_struct(workspace) in test files" do
      """
      defmodule MingaEditor.SessionTest do
        def test_helper(workspace) do
          Map.from_struct(workspace)
        end
      end
      """
      |> check("test/minga_editor/session_test.exs")
      |> refute_issues()
    end
  end
end
