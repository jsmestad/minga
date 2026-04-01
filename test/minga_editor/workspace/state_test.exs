defmodule MingaEditor.Workspace.StateTest do
  @moduledoc """
  Pure-function tests for `MingaEditor.Workspace.State`.

  Uses `RenderPipeline.TestHelpers.base_state/1` to construct state
  without starting a GenServer.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Window.Content
  alias MingaEditor.Workspace.State, as: WorkspaceState

  import MingaEditor.RenderPipeline.TestHelpers

  describe "sync_active_window_buffer/1" do
    test "syncs buffer content when window shows a buffer" do
      state = base_state()
      ws = state.workspace
      win_id = ws.windows.active
      original_buf = ws.buffers.active

      # Create a new buffer to switch to
      {:ok, new_buf} = Minga.Buffer.Server.start_link(content: "new content")

      # Update buffers.active to the new buffer, but leave the window pointing at the old one
      ws = %{ws | buffers: %{ws.buffers | active: new_buf}}

      # Confirm the window still points at the old buffer
      window = Map.get(ws.windows.map, win_id)
      assert window.buffer == original_buf
      assert window.content == {:buffer, original_buf}

      # sync should update the window to point at the new buffer
      ws = WorkspaceState.sync_active_window_buffer(ws)

      updated_window = Map.get(ws.windows.map, win_id)
      assert updated_window.buffer == new_buf
      assert updated_window.content == {:buffer, new_buf}
    end

    test "preserves agent_chat content when syncing" do
      state = base_state()
      ws = state.workspace
      win_id = ws.windows.active

      # Set the window's content to agent_chat
      agent_pid = spawn(fn -> Process.sleep(:infinity) end)
      window = Map.get(ws.windows.map, win_id)
      agent_window = %{window | content: Content.agent_chat(agent_pid)}
      ws = %{ws | windows: %{ws.windows | map: Map.put(ws.windows.map, win_id, agent_window)}}

      # Change the active buffer to something different
      {:ok, new_buf} = Minga.Buffer.Server.start_link(content: "new content")
      ws = %{ws | buffers: %{ws.buffers | active: new_buf}}

      # sync should NOT touch the agent_chat window
      ws = WorkspaceState.sync_active_window_buffer(ws)

      result_window = Map.get(ws.windows.map, win_id)
      assert result_window.content == {:agent_chat, agent_pid}
      # buffer field should remain unchanged (still the original, not new_buf)
      assert result_window.buffer == window.buffer
    end
  end
end
