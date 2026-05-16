Code.require_file("credo/checks/no_direct_state_machine_write_check.exs")

defmodule Minga.Credo.NoDirectStateMachineWriteCheckTest do
  use Credo.Test.Case, async: true

  alias Minga.Credo.NoDirectStateMachineWriteCheck

  @moduletag :credo

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp check(source_code, filename) do
    source_code
    |> to_source_file(filename)
    |> run_check(NoDirectStateMachineWriteCheck, [])
  end

  test "flags put_in through guarded workspace sub-structs" do
    """
    defmodule MingaEditor.BadPutIn do
      def set_active(state, pid) do
        put_in(state.workspace.buffers.active, pid)
      end
    end
    """
    |> check("lib/minga_editor/bad_put_in.ex")
    |> assert_issue(fn issue ->
      assert issue.trigger == "put_in"
      assert issue.message =~ "workspace.buffers"
    end)
  end

  test "flags map updates on guarded workspace sub-structs" do
    """
    defmodule MingaEditor.BadMapUpdate do
      def focus_window(state, id) do
        %{state.workspace.windows | active: id}
      end
    end
    """
    |> check("lib/minga_editor/bad_map_update.ex")
    |> assert_issue(fn issue ->
      assert issue.trigger == "active:"
      assert issue.message =~ "workspace.windows"
    end)
  end

  test "allows owning workspace state module" do
    """
    defmodule MingaEditor.Workspace.State do
      def set_buffers(workspace, buffers) do
        %{workspace | buffers: buffers}
      end
    end
    """
    |> check("lib/minga_editor/workspace/state.ex")
    |> refute_issues()
  end
end
