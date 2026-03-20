defmodule Minga.Editor.LspActions.ReferencesTest do
  @moduledoc """
  Tests for the find-references response handling logic in LspActions.

  These test the response parsing and routing (single result vs multiple,
  error handling, empty results) without requiring a running LSP server.
  """
  use ExUnit.Case, async: true

  alias Minga.Editor.LspActions

  # Minimal state stub for testing response handlers.
  # Only needs the fields that handlers read/write.
  defp stub_state do
    %{
      status_msg: nil,
      buffers: %{active: nil, list: []},
      picker_ui: %Minga.Editor.State.Picker{},
      whichkey: %Minga.Editor.State.WhichKey{},
      vim: %{mode: :normal, last_jump_pos: nil}
    }
  end

  describe "handle_references_response/2" do
    test "error result sets status message" do
      state = LspActions.handle_references_response(stub_state(), {:error, "timeout"})
      assert state.status_msg == "References request failed"
    end

    test "nil result sets status message" do
      state = LspActions.handle_references_response(stub_state(), {:ok, nil})
      assert state.status_msg == "No references found"
    end

    test "empty list sets status message" do
      state = LspActions.handle_references_response(stub_state(), {:ok, []})
      assert state.status_msg == "No references found"
    end
  end
end
