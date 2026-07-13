defmodule MingaEditor.LspActions.RenameTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Command.Parser
  alias MingaEditor.LspActions
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  defp stub_state do
    %EditorState{
      port_manager: nil,
      workspace: %SessionState{viewport: Viewport.new(40, 120)},
      theme: MingaEditor.UI.Theme.get!(:doom_one)
    }
  end

  describe "handle_prepare_rename_response/2" do
    test "keeps non-operation prepare notices unchanged" do
      error_state = LspActions.handle_prepare_rename_response(stub_state(), {:error, "invalid"})
      nil_state = LspActions.handle_prepare_rename_response(stub_state(), {:ok, nil})

      assert EditorState.status_msg(error_state) == "Cannot rename at this position"
      assert EditorState.status_msg(nil_state) == "Cannot rename at this position"
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

  describe "handle_rename_response/3" do
    test "applies workspace edits and finishes the correlated identity successfully" do
      path =
        Path.join(System.tmp_dir!(), "rename-feedback-#{System.unique_integer([:positive])}.ex")

      File.write!(path, "old_name\n")
      on_exit(fn -> File.rm(path) end)

      state = file_state(path)

      {state, operation} =
        OperationFeedback.start_in(
          state,
          :lsp_rename,
          "lsp:rename:" <> path,
          "Renaming...",
          cancelable?: false
        )

      edit = %{
        "changes" => %{
          "file://#{path}" => [
            %{
              "range" => %{
                "start" => %{"line" => 0, "character" => 0},
                "end" => %{"line" => 0, "character" => 8}
              },
              "newText" => "new_name"
            }
          ]
        }
      }

      state = LspActions.handle_rename_response(state, {:ok, edit}, operation.id)

      assert Minga.Buffer.content(state.workspace.buffers.active) == "new_name"
      assert OperationFeedback.selected(state.operation_feedback).status == :success

      assert OperationFeedback.selected(state.operation_feedback).message ==
               "Rename: applied 1 edits across 1 files"
    end

    test "error, no-result, and empty application outcomes finish one identity" do
      cases = [
        {{:error, "failed"}, :error, "Rename failed"},
        {{:ok, nil}, :success, "Rename returned no edits"},
        {{:ok, %{}}, :success, "Rename: no edits to apply"}
      ]

      for {response, status, message} <- cases do
        {state, operation} = start_operation()
        state = LspActions.handle_rename_response(state, response, operation.id)
        selected = OperationFeedback.selected(state.operation_feedback)

        assert selected.id == operation.id
        assert selected.status == status
        assert selected.message == message
        assert EditorState.status_msg(state) == nil
      end
    end
  end

  describe "rename command parser" do
    test "parses and trims rename commands" do
      assert {:rename, "new_name"} = Parser.parse("rename new_name")
      assert {:rename, "new_name"} = Parser.parse("rename   new_name  ")
    end
  end

  @spec file_state(String.t()) :: EditorState.t()
  defp file_state(path) do
    buffer =
      start_supervised!({BufferProcess, file_path: path, content: "old_name\n"},
        id: {:rename_buffer, make_ref()}
      )

    workspace = %SessionState{
      viewport: Viewport.new(40, 120),
      buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => Window.new(1, buffer, 40, 120)},
        active: 1,
        next_id: 2
      }
    }

    %EditorState{port_manager: self(), workspace: workspace}
  end

  @spec start_operation() :: {EditorState.t(), MingaEditor.State.Operation.t()}
  defp start_operation do
    OperationFeedback.start_in(
      stub_state(),
      :lsp_rename,
      "lsp:rename:file.ex",
      "Renaming...",
      cancelable?: false
    )
  end
end
