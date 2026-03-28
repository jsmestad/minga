defmodule Minga.Editor.LspActions.ReferencesTest do
  @moduledoc """
  Tests for the find-references response handling logic in LspActions.

  These test the response parsing and routing (single result vs multiple,
  error handling, empty results) without requiring a running LSP server.
  """
  use ExUnit.Case, async: true

  alias Minga.Editor.LspActions
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Workspace.State, as: WorkspaceState

  defp stub_state do
    %EditorState{
      port_manager: nil,
      workspace: %WorkspaceState{viewport: Viewport.new(40, 120)}
    }
  end

  describe "handle_references_response/2" do
    test "error result sets status message" do
      state = LspActions.handle_references_response(stub_state(), {:error, "timeout"})
      assert state.shell_state.status_msg == "References request failed"
    end

    test "nil result sets status message" do
      state = LspActions.handle_references_response(stub_state(), {:ok, nil})
      assert state.shell_state.status_msg == "No references found"
    end

    test "empty list sets status message" do
      state = LspActions.handle_references_response(stub_state(), {:ok, []})
      assert state.shell_state.status_msg == "No references found"
    end
  end
end
