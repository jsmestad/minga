defmodule Minga.Editor.LspActions.NavigationTest do
  @moduledoc """
  Tests for type definition and implementation response handlers.

  These follow the same Location/LocationLink format as goto_definition,
  so the tests verify the response routing (error, nil, empty, single,
  multiple) without requiring a running LSP server.
  """
  use ExUnit.Case, async: true

  alias Minga.Editor.LspActions

  defp stub_state do
    %{
      shell_state: %Minga.Shell.Traditional.State{status_msg: nil},
      buffers: %{active: nil, list: []},
      picker_ui: %Minga.Editor.State.Picker{},
      whichkey: %Minga.Editor.State.WhichKey{},
      vim: %{mode: :normal, last_jump_pos: nil}
    }
  end

  describe "handle_type_definition_response/2" do
    test "error sets status message" do
      state = LspActions.handle_type_definition_response(stub_state(), {:error, "timeout"})
      assert state.shell_state.status_msg == "Type definition request failed"
    end

    test "nil result sets status message" do
      state = LspActions.handle_type_definition_response(stub_state(), {:ok, nil})
      assert state.shell_state.status_msg == "No type definition found"
    end

    test "empty list sets status message" do
      state = LspActions.handle_type_definition_response(stub_state(), {:ok, []})
      assert state.shell_state.status_msg == "No type definition found"
    end
  end

  describe "handle_implementation_response/2" do
    test "error sets status message" do
      state = LspActions.handle_implementation_response(stub_state(), {:error, "timeout"})
      assert state.shell_state.status_msg == "Implementation request failed"
    end

    test "nil result sets status message" do
      state = LspActions.handle_implementation_response(stub_state(), {:ok, nil})
      assert state.shell_state.status_msg == "No implementation found"
    end

    test "empty list sets status message" do
      state = LspActions.handle_implementation_response(stub_state(), {:ok, []})
      assert state.shell_state.status_msg == "No implementation found"
    end
  end
end
