defmodule MingaEditor.LspActions.CodeActionTest do
  use ExUnit.Case, async: true

  alias MingaEditor.LspActions
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Session.State, as: SessionState

  defp stub_state do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %SessionState{},
      appearance: %MingaEditor.State.Appearance{theme: MingaEditor.UI.Theme.get!(:doom_one)}
    }
  end

  describe "handle_code_action_response/2" do
    test "error sets status message" do
      state = LspActions.handle_code_action_response(stub_state(), {:error, "timeout"})
      assert state.shell_runtime.state.notice.message == "Code action request failed"
    end

    test "no code actions answer in the echo line and name the next step, opening nothing" do
      for result <- [nil, []] do
        state = LspActions.handle_code_action_response(stub_state(), {:ok, result})
        notice = state.shell_runtime.state.notice

        assert notice.message == "No code actions here"
        assert [%{id: "inline_ask", key: "SPC a ?", label: "ask Minga"}] = notice.actions
        assert state.shell_runtime.state.modal == :none
      end
    end

    test "actions with non-empty list opens picker" do
      # The handler calls PickerUI.open, which needs a full state.
      # We verify the handler doesn't crash and doesn't set an error message.
      actions = [
        %{"title" => "Add alias", "kind" => "quickfix"},
        %{"title" => "Extract function", "kind" => "refactor.extract"}
      ]

      result = LspActions.handle_code_action_response(stub_state(), {:ok, actions})

      # When PickerUI.open succeeds, the picker is active in the modal.
      {:picker, %{picker_ui: picker_ui}} =
        MingaEditor.Shell.Runtime.state(result.shell_runtime).modal

      assert picker_ui.source == MingaEditor.UI.Picker.CodeActionSource
    end
  end
end
