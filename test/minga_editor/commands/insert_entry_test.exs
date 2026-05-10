defmodule MingaEditor.Commands.InsertEntryTest do
  @moduledoc """
  Layer-1 tests for the read-only buffer guard on mode-entry keys.

  Builds an EditorState backed by a real `Buffer.Server` flagged
  `read_only: true`, then exercises `KeyDispatch.handle_key/3` for the
  `i` (insert) and `R` (replace) keys. The guard in
  `KeyDispatch.guard_read_only/4` should keep the editor in :normal
  mode and emit the "Buffer is read-only" status message.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias MingaEditor.KeyDispatch
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Workspace.State, as: WorkspaceState

  defp start_read_only_buffer do
    start_supervised!({BufferServer, content: "read only", read_only: true})
  end

  defp build_state(buffer) do
    %EditorState{
      port_manager: nil,
      workspace: %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: buffer, list: [buffer]},
        editing: VimState.new()
      }
    }
  end

  describe "read-only buffer guard" do
    test "i (insert) keeps mode :normal and sets status" do
      buffer = start_read_only_buffer()
      state = build_state(buffer)

      result = KeyDispatch.handle_key(state, ?i, 0)

      assert result.workspace.editing.mode == :normal
      assert EditorState.status_msg(result) == "Buffer is read-only"
    end

    test "R (replace) keeps mode :normal and sets status" do
      buffer = start_read_only_buffer()
      state = build_state(buffer)

      result = KeyDispatch.handle_key(state, ?R, 0)

      assert result.workspace.editing.mode == :normal
      assert EditorState.status_msg(result) == "Buffer is read-only"
    end

    test "writable buffer transitions into :insert on i" do
      {:ok, buffer} = start_supervised({BufferServer, content: "writable"})
      state = build_state(buffer)

      result = KeyDispatch.handle_key(state, ?i, 0)

      assert result.workspace.editing.mode == :insert
      assert EditorState.status_msg(result) == nil
    end
  end
end
