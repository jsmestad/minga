defmodule MingaEditor.LspActions.RenameTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Command.Parser
  alias MingaEditor.LspActions
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  defp stub_state do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %SessionState{viewport: Viewport.new(40, 120)},
      appearance: %MingaEditor.State.Appearance{theme: MingaEditor.UI.Theme.get!(:doom_one)}
    }
  end

  describe "handle_prepare_rename_response/2" do
    test "keeps non-operation prepare notices unchanged" do
      error_state = LspActions.handle_prepare_rename_response(stub_state(), {:error, "invalid"})
      nil_state = LspActions.handle_prepare_rename_response(stub_state(), {:ok, nil})

      assert error_state.shell_runtime.state.notice.message == "Cannot rename at this position"
      assert nil_state.shell_runtime.state.notice.message == "Cannot rename at this position"
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

      {operation_feedback, operation} =
        OperationFeedback.start(
          state.feedback.operation_feedback,
          :lsp_rename,
          "lsp:rename:" <> path,
          "Renaming...",
          cancelable?: false
        )

      state = %{
        state
        | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)
      }

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
      assert OperationFeedback.selected(state.feedback.operation_feedback).status == :success

      assert OperationFeedback.selected(state.feedback.operation_feedback).message ==
               "Rename: applied 1 edits across 1 files"
    end

    test "error, no-result, and empty application outcomes finish one identity" do
      cases = [
        {{:error, "failed"}, :error, "Rename failed"},
        {{:error, :timeout}, :timeout, "Rename timed out"},
        {{:ok, nil}, :success, "Rename returned no edits"},
        {{:ok, %{}}, :success, "Rename: no edits to apply"}
      ]

      for {response, status, message} <- cases do
        {state, operation} = start_operation()
        state = LspActions.handle_rename_response(state, response, operation.id)
        selected = OperationFeedback.selected(state.feedback.operation_feedback)

        assert selected.id == operation.id
        assert selected.status == status
        assert selected.message == message
        assert state.shell_runtime.state.notice.message == nil
      end
    end

    test "a response for a replaced identity cannot apply workspace edits" do
      path = Path.join(System.tmp_dir!(), "stale-rename-#{System.unique_integer([:positive])}.ex")
      File.write!(path, "old_name\n")
      on_exit(fn -> File.rm(path) end)
      state = file_state(path)

      {old_feedback, old} =
        OperationFeedback.start(
          state.feedback.operation_feedback,
          :lsp_rename,
          "lsp:rename:" <> path,
          "Renaming...",
          cancelable?: false
        )

      state = %{
        state
        | feedback: Feedback.accept_operation_feedback(state.feedback, old_feedback)
      }

      {current_feedback, current} =
        OperationFeedback.start(
          state.feedback.operation_feedback,
          :lsp_rename,
          "lsp:rename:" <> path,
          "Renaming again...",
          cancelable?: false
        )

      state = %{
        state
        | feedback: Feedback.accept_operation_feedback(state.feedback, current_feedback)
      }

      result = LspActions.handle_rename_response(state, {:ok, rename_edit(path)}, old.id)

      assert result == state
      assert Minga.Buffer.content(result.workspace.buffers.active) == "old_name\n"
      assert OperationFeedback.selected(result.feedback.operation_feedback).id == current.id
      assert OperationFeedback.selected(result.feedback.operation_feedback).status == :pending
    end

    test "partial workspace edit application reports an error with applied and requested counts" do
      path =
        Path.join(System.tmp_dir!(), "partial-rename-#{System.unique_integer([:positive])}.ex")

      missing =
        Path.join(System.tmp_dir!(), "missing-rename-#{System.unique_integer([:positive])}.ex")

      File.write!(path, "old_name\n")
      on_exit(fn -> File.rm(path) end)
      state = file_state(path)

      {operation_feedback, operation} =
        OperationFeedback.start(
          state.feedback.operation_feedback,
          :lsp_rename,
          "lsp:rename:" <> path,
          "Renaming...",
          cancelable?: false
        )

      state = %{
        state
        | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)
      }

      edit =
        rename_edit(path)
        |> put_in(["changes", "file://#{missing}"], rename_edit_for_range())

      result = LspActions.handle_rename_response(state, {:ok, edit}, operation.id)
      selected = OperationFeedback.selected(result.feedback.operation_feedback)

      assert Minga.Buffer.content(result.workspace.buffers.active) == "new_name"
      assert selected.status == :error
      assert selected.message == "Rename: applied 1 edits across 1 of 2 files"
    end
  end

  describe "rename command parser" do
    test "parses and trims rename commands" do
      assert {:rename, "new_name"} = Parser.parse("rename new_name")
      assert {:rename, "new_name"} = Parser.parse("rename   new_name  ")
    end
  end

  @spec rename_edit(String.t()) :: map()
  defp rename_edit(path) do
    %{"changes" => %{"file://#{path}" => rename_edit_for_range()}}
  end

  @spec rename_edit_for_range() :: [map()]
  defp rename_edit_for_range do
    [
      %{
        "range" => %{
          "start" => %{"line" => 0, "character" => 0},
          "end" => %{"line" => 0, "character" => 8}
        },
        "newText" => "new_name"
      }
    ]
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

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: workspace
    }
  end

  @spec start_operation() :: {EditorState.t(), MingaEditor.State.Operation.t()}
  defp start_operation do
    state = stub_state()

    {operation_feedback, operation} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :lsp_rename,
        "lsp:rename:file.ex",
        "Renaming...",
        cancelable?: false
      )

    {%{state | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)},
     operation}
  end
end
