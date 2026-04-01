defmodule MingaEditor.LspActions.CodeActionTest do
  use ExUnit.Case, async: true

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

  describe "handle_code_action_response/2" do
    test "error sets status message" do
      state = LspActions.handle_code_action_response(stub_state(), {:error, "timeout"})
      assert state.shell_state.status_msg == "Code action request failed"
    end

    test "nil result sets status message" do
      state = LspActions.handle_code_action_response(stub_state(), {:ok, nil})
      assert state.shell_state.status_msg == "No code actions available"
    end

    test "empty list sets status message" do
      state = LspActions.handle_code_action_response(stub_state(), {:ok, []})
      assert state.shell_state.status_msg == "No code actions available"
    end

    test "actions with non-empty list opens picker" do
      # The handler calls PickerUI.open, which needs a full state.
      # We verify the handler doesn't crash and doesn't set an error message.
      actions = [
        %{"title" => "Add alias", "kind" => "quickfix"},
        %{"title" => "Extract function", "kind" => "refactor.extract"}
      ]

      result = LspActions.handle_code_action_response(stub_state(), {:ok, actions})

      # When PickerUI.open succeeds, it sets the picker source.
      # When items are empty (which they won't be since we have actions),
      # it returns state unchanged. The picker_ui.source being set confirms
      # the picker was opened.
      assert result.shell_state.picker_ui.source == MingaEditor.UI.Picker.CodeActionSource
    end
  end
end
