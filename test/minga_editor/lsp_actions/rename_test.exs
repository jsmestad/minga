defmodule MingaEditor.LspActions.RenameTest do
  use ExUnit.Case, async: true

  alias Minga.Command.Parser
  alias MingaEditor.LspActions
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport
  alias MingaEditor.Workspace.State, as: WorkspaceState

  defp stub_state do
    %EditorState{
      port_manager: nil,
      workspace: %WorkspaceState{viewport: Viewport.new(40, 120)},
      theme: MingaEditor.UI.Theme.get!(:doom_one)
    }
  end

  describe "handle_prepare_rename_response/2" do
    test "error sets status message" do
      state = LspActions.handle_prepare_rename_response(stub_state(), {:error, "invalid"})
      assert state.shell_state.status_msg == "Cannot rename at this position"
    end

    test "nil result sets status message" do
      state = LspActions.handle_prepare_rename_response(stub_state(), {:ok, nil})
      assert state.shell_state.status_msg == "Cannot rename at this position"
    end

    test "successful prepare enters command mode with rename prompt" do
      result = %{
        "range" => %{
          "start" => %{"line" => 5, "character" => 4},
          "end" => %{"line" => 5, "character" => 12}
        },
        "placeholder" => "my_func"
      }

      state = LspActions.handle_prepare_rename_response(stub_state(), {:ok, result})
      assert state.workspace.editing.mode == :command
      assert state.workspace.editing.mode_state.input == "rename my_func"
    end

    test "prepare with range-only response enters command mode" do
      result = %{
        "start" => %{"line" => 5, "character" => 4},
        "end" => %{"line" => 5, "character" => 12}
      }

      state = LspActions.handle_prepare_rename_response(stub_state(), {:ok, result})
      assert state.workspace.editing.mode == :command
      assert state.workspace.editing.mode_state.input == "rename "
    end
  end

  describe "handle_rename_response/2" do
    test "error sets status message" do
      state = LspActions.handle_rename_response(stub_state(), {:error, "failed"})
      assert state.shell_state.status_msg == "Rename failed"
    end

    test "nil result sets status message" do
      state = LspActions.handle_rename_response(stub_state(), {:ok, nil})
      assert state.shell_state.status_msg == "Rename returned no edits"
    end

    test "empty workspace edit sets status message" do
      state = LspActions.handle_rename_response(stub_state(), {:ok, %{}})
      assert state.shell_state.status_msg =~ "no edits to apply"
    end
  end

  describe "rename command parser" do
    test "parses rename command" do
      assert {:rename, "new_name"} = Parser.parse("rename new_name")
    end

    test "trims whitespace from name" do
      assert {:rename, "new_name"} = Parser.parse("rename   new_name  ")
    end
  end
end
