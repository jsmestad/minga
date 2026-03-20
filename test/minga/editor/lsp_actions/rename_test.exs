defmodule Minga.Editor.LspActions.RenameTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.LspActions

  defp stub_state do
    %{
      status_msg: nil,
      buffers: %Minga.Editor.State.Buffers{},
      picker_ui: %Minga.Editor.State.Picker{},
      whichkey: %Minga.Editor.State.WhichKey{},
      vim: Minga.Editor.VimState.new(),
      theme: Minga.Theme.get!(:doom_one),
      viewport: %Minga.Editor.Viewport{rows: 40, cols: 120, top: 0, left: 0}
    }
  end

  describe "handle_prepare_rename_response/2" do
    test "error sets status message" do
      state = LspActions.handle_prepare_rename_response(stub_state(), {:error, "invalid"})
      assert state.status_msg == "Cannot rename at this position"
    end

    test "nil result sets status message" do
      state = LspActions.handle_prepare_rename_response(stub_state(), {:ok, nil})
      assert state.status_msg == "Cannot rename at this position"
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
      assert state.vim.mode == :command
      assert state.vim.mode_state.input == "rename my_func"
    end

    test "prepare with range-only response enters command mode" do
      result = %{
        "start" => %{"line" => 5, "character" => 4},
        "end" => %{"line" => 5, "character" => 12}
      }

      state = LspActions.handle_prepare_rename_response(stub_state(), {:ok, result})
      assert state.vim.mode == :command
      assert state.vim.mode_state.input == "rename "
    end
  end

  describe "handle_rename_response/2" do
    test "error sets status message" do
      state = LspActions.handle_rename_response(stub_state(), {:error, "failed"})
      assert state.status_msg == "Rename failed"
    end

    test "nil result sets status message" do
      state = LspActions.handle_rename_response(stub_state(), {:ok, nil})
      assert state.status_msg == "Rename returned no edits"
    end

    test "empty workspace edit sets status message" do
      state = LspActions.handle_rename_response(stub_state(), {:ok, %{}})
      assert state.status_msg =~ "no edits to apply"
    end
  end

  describe "rename command parser" do
    test "parses rename command" do
      assert {:rename, "new_name"} = Minga.Command.Parser.parse("rename new_name")
    end

    test "trims whitespace from name" do
      assert {:rename, "new_name"} = Minga.Command.Parser.parse("rename   new_name  ")
    end
  end
end
