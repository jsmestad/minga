defmodule MingaEditor.Workspace.StateTest do
  @moduledoc """
  Pure-function tests for `MingaEditor.Workspace.State`.

  Uses `RenderPipeline.TestHelpers.base_state/1` to construct state
  without starting a GenServer.
  """

  use ExUnit.Case, async: true

  alias Minga.Mode
  alias MingaEditor.VimState
  alias MingaEditor.State.Tab.Context
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

  describe "restore_tab_context/2" do
    test "restores flat workspace fields from a tab context" do
      ws = base_state().workspace
      replacement = %{ws.buffers | active: nil, list: [], active_index: 0}

      restored = WorkspaceState.restore_tab_context(ws, %{buffers: replacement})

      assert restored.buffers == replacement
      assert restored.windows == ws.windows
      assert restored.viewport == ws.viewport
    end

    test "ignores fields that are not part of the workspace" do
      ws = base_state().workspace

      restored = WorkspaceState.restore_tab_context(ws, %{unknown_field: :ignored})

      assert restored == ws
    end
  end

  describe "to_tab_context/1" do
    test "returns a typed context of workspace fields" do
      ws = base_state().workspace
      ctx = WorkspaceState.to_tab_context(ws)

      assert %Context{} = ctx
      assert ctx.buffers == ws.buffers
      assert ctx.windows == ws.windows
      assert ctx.viewport == ws.viewport
      assert Enum.sort(WorkspaceState.field_names()) == Enum.sort(ctx.present_fields)
    end

    test "normalises an in-flight CommandState back to %Mode.State{} when mode is :normal" do
      # Simulates the moment after Command.handle_key/2 returns
      # `{:execute_then_transition, [...], :normal, %CommandState{input: ""}}`
      # and the dispatch wrote that pair into workspace.editing before the
      # ex-command ran (the same moment :e <path> would snapshot).
      ws = base_state().workspace
      mismatched = %VimState{mode: :normal, mode_state: %Mode.CommandState{input: ""}}
      ws = %{ws | editing: mismatched}

      ctx = WorkspaceState.to_tab_context(ws)

      assert ctx.editing.mode == :normal
      assert match?(%Mode.State{}, ctx.editing.mode_state)
    end

    test "passes through editing when mode_state already matches mode" do
      ws = base_state().workspace
      visual_state = %Mode.VisualState{visual_type: :char, visual_anchor: {3, 0}}
      vim = %VimState{mode: :visual, mode_state: visual_state}
      ws = %{ws | editing: vim}

      ctx = WorkspaceState.to_tab_context(ws)

      # Visual is a context-required mode and the snapshot already had a
      # properly-typed VisualState — the visual_anchor must be preserved
      # so the context can be restored verbatim.
      assert ctx.editing.mode == :visual
      assert ctx.editing.mode_state == visual_state
    end
  end
end
