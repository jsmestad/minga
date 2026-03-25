defmodule Minga.Editor.LspActions.RenameTest do
  use ExUnit.Case, async: true

  alias Minga.Command.Parser
  alias Minga.Editor.LspActions
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Picker, as: PickerState
  alias Minga.Editor.State.WhichKey
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState

  defp stub_state do
    %{
      workspace: %{
        buffers: %Buffers{},
        vim: VimState.new(),
        viewport: Viewport.new(40, 120)
      },
      shell_state: %Minga.Shell.Traditional.State{status_msg: nil},
      picker_ui: %PickerState{},
      whichkey: %WhichKey{},
      theme: Minga.UI.Theme.get!(:doom_one)
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
      assert state.workspace.vim.mode == :command
      assert state.workspace.vim.mode_state.input == "rename my_func"
    end

    test "prepare with range-only response enters command mode" do
      result = %{
        "start" => %{"line" => 5, "character" => 4},
        "end" => %{"line" => 5, "character" => 12}
      }

      state = LspActions.handle_prepare_rename_response(stub_state(), {:ok, result})
      assert state.workspace.vim.mode == :command
      assert state.workspace.vim.mode_state.input == "rename "
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
