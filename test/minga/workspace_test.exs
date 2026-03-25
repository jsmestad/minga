defmodule Minga.WorkspaceTest do
  @moduledoc """
  Unit tests for `Minga.Workspace` pure calculation functions.

  These tests verify that workspace operations produce correct results
  without GenServer calls. Buffer pids are started via `BufferServer.start_link`
  for realistic struct shapes, but the Workspace functions themselves
  never call BufferServer.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Editor.WindowTree
  alias Minga.Workspace
  alias Minga.Workspace.State, as: WorkspaceState

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp new_workspace do
    %WorkspaceState{viewport: Viewport.new(24, 80)}
  end

  defp start_buffer(content \\ "hello") do
    {:ok, pid} = BufferServer.start_link(content: content)
    pid
  end

  defp workspace_with_buffer(content \\ "hello") do
    buf = start_buffer(content)

    ws =
      %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{list: [buf], active_index: 0, active: buf}
      }
      |> setup_windows()

    {ws, buf}
  end

  defp setup_windows(%WorkspaceState{buffers: %{active: buf}} = ws) do
    tree = WindowTree.new(1)
    window = Window.new(1, buf, 24, 80)

    %{
      ws
      | windows: %Windows{tree: tree, map: %{1 => window}, active: 1, next_id: 2}
    }
  end

  # ── Window operations ────────────────────────────────────────────────────────

  describe "active_window_struct/1" do
    test "returns the active window" do
      {ws, buf} = workspace_with_buffer()
      win = Workspace.active_window_struct(ws)
      assert %Window{id: 1, buffer: ^buf} = win
    end

    test "returns nil when windows not initialized" do
      ws = new_workspace()
      assert Workspace.active_window_struct(ws) == nil
    end
  end

  describe "split?/1" do
    test "returns false for a single window" do
      {ws, _buf} = workspace_with_buffer()
      refute Workspace.split?(ws)
    end

    test "returns false when tree is nil" do
      ws = new_workspace()
      refute Workspace.split?(ws)
    end
  end

  describe "update_window/3" do
    test "updates the window via a mapper function" do
      {ws, _buf} = workspace_with_buffer()

      updated = Workspace.update_window(ws, 1, fn w -> %{w | cursor: {5, 10}} end)

      assert %Window{cursor: {5, 10}} = Workspace.active_window_struct(updated)
    end

    test "returns unchanged when window id not found" do
      {ws, _buf} = workspace_with_buffer()

      updated = Workspace.update_window(ws, 999, fn w -> %{w | cursor: {5, 10}} end)
      assert updated == ws
    end
  end

  describe "invalidate_all_windows/1" do
    test "clears cached content for all windows" do
      {ws, _buf} = workspace_with_buffer()

      # Set cached content so we can verify it gets cleared
      ws =
        Workspace.update_window(ws, 1, fn w ->
          %{w | cached_content: %{0 => :some_data}}
        end)

      invalidated = Workspace.invalidate_all_windows(ws)
      win = Workspace.active_window_struct(invalidated)
      assert win.cached_content == %{}
    end
  end

  describe "active_window_viewport/1" do
    test "returns the active window's viewport" do
      {ws, _buf} = workspace_with_buffer()
      vp = Workspace.active_window_viewport(ws)
      assert %Viewport{rows: 24, cols: 80} = vp
    end

    test "falls back to workspace viewport when no window" do
      ws = new_workspace()
      vp = Workspace.active_window_viewport(ws)
      assert %Viewport{rows: 24, cols: 80} = vp
    end
  end

  describe "put_active_window_viewport/2" do
    test "updates the active window's viewport" do
      {ws, _buf} = workspace_with_buffer()
      new_vp = Viewport.new(40, 120)
      updated = Workspace.put_active_window_viewport(ws, new_vp)
      win = Workspace.active_window_struct(updated)
      assert win.viewport.rows == 40
      assert win.viewport.cols == 120
    end

    test "falls back to workspace viewport when no window" do
      ws = new_workspace()
      new_vp = Viewport.new(40, 120)
      updated = Workspace.put_active_window_viewport(ws, new_vp)
      assert updated.viewport.rows == 40
      assert updated.viewport.cols == 120
    end
  end

  describe "find_agent_chat_window/1" do
    test "returns nil when no agent chat window exists" do
      {ws, _buf} = workspace_with_buffer()
      assert Workspace.find_agent_chat_window(ws) == nil
    end

    test "returns agent chat window when present" do
      buf = start_buffer()

      window = %Window{
        id: 2,
        buffer: buf,
        content: {:agent_chat, buf},
        viewport: Viewport.new(24, 80),
        cursor: {0, 0}
      }

      ws = %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{list: [buf], active_index: 0, active: buf},
        windows: %Windows{
          tree: WindowTree.new(2),
          map: %{2 => window},
          active: 2,
          next_id: 3
        }
      }

      assert {2, %Window{content: {:agent_chat, ^buf}}} =
               Workspace.find_agent_chat_window(ws)
    end
  end

  describe "scope_for_content/2" do
    test "agent chat always returns :agent" do
      buf = start_buffer()
      assert Workspace.scope_for_content({:agent_chat, buf}, :editor) == :agent
      assert Workspace.scope_for_content({:agent_chat, buf}, :file_tree) == :agent
    end

    test "buffer from agent scope returns :editor" do
      buf = start_buffer()
      assert Workspace.scope_for_content({:buffer, buf}, :agent) == :editor
    end

    test "buffer preserves current scope" do
      buf = start_buffer()
      assert Workspace.scope_for_content({:buffer, buf}, :file_tree) == :file_tree
      assert Workspace.scope_for_content({:buffer, buf}, :editor) == :editor
    end
  end

  describe "scope_for_active_window/1" do
    test "returns :editor for buffer windows" do
      {ws, _buf} = workspace_with_buffer()
      assert Workspace.scope_for_active_window(ws) == :editor
    end

    test "returns :editor when no window" do
      ws = new_workspace()
      assert Workspace.scope_for_active_window(ws) == :editor
    end
  end

  describe "scroll_agent_chat_window/3" do
    test "scrolls agent chat window viewport" do
      buf = start_buffer(String.duplicate("line\n", 100))

      window = %Window{
        id: 2,
        buffer: buf,
        content: {:agent_chat, buf},
        viewport: Viewport.new(24, 80),
        cursor: {0, 0}
      }

      ws = %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{list: [buf], active_index: 0, active: buf},
        windows: %Windows{
          tree: WindowTree.new(2),
          map: %{2 => window},
          active: 2,
          next_id: 3
        }
      }

      updated = Workspace.scroll_agent_chat_window(ws, 5, 100)
      {_id, scrolled_win} = Workspace.find_agent_chat_window(updated)
      assert scrolled_win.viewport.top > 0
    end

    test "returns unchanged when no agent chat window" do
      {ws, _buf} = workspace_with_buffer()
      assert Workspace.scroll_agent_chat_window(ws, 5, 100) == ws
    end
  end

  # ── Buffer operations ────────────────────────────────────────────────────────

  describe "switch_buffer/2" do
    test "switches the active buffer and syncs window" do
      buf1 = start_buffer("first")
      buf2 = start_buffer("second")

      ws =
        %WorkspaceState{
          viewport: Viewport.new(24, 80),
          buffers: %Buffers{list: [buf1, buf2], active_index: 0, active: buf1}
        }
        |> setup_windows()

      updated = Workspace.switch_buffer(ws, 1)
      assert updated.buffers.active == buf2
      assert updated.buffers.active_index == 1

      # Window should have synced
      win = Workspace.active_window_struct(updated)
      assert win.buffer == buf2
    end
  end

  describe "add_buffer/2" do
    test "adds a buffer and syncs window" do
      {ws, _buf1} = workspace_with_buffer("first")
      buf2 = start_buffer("second")

      updated = Workspace.add_buffer(ws, buf2)
      assert buf2 in updated.buffers.list
      assert updated.buffers.active == buf2

      # Window should have synced to the new buffer
      win = Workspace.active_window_struct(updated)
      assert win.buffer == buf2
    end
  end

  describe "remove_dead_buffer/2" do
    test "removes the buffer and picks a new active" do
      buf1 = start_buffer("first")
      buf2 = start_buffer("second")

      ws =
        %WorkspaceState{
          viewport: Viewport.new(24, 80),
          buffers: %Buffers{list: [buf1, buf2], active_index: 0, active: buf1}
        }
        |> setup_windows()

      updated = Workspace.remove_dead_buffer(ws, buf1)
      refute buf1 in updated.buffers.list
      assert updated.buffers.active == buf2
    end

    test "handles removing the only buffer" do
      {ws, buf} = workspace_with_buffer()

      updated = Workspace.remove_dead_buffer(ws, buf)
      assert updated.buffers.list == []
      assert updated.buffers.active == nil
    end

    test "clears special buffer slots when they match" do
      buf1 = start_buffer("first")
      buf2 = start_buffer("messages")

      ws = %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{
          list: [buf1, buf2],
          active_index: 0,
          active: buf1,
          messages: buf2
        }
      }

      updated = Workspace.remove_dead_buffer(ws, buf2)
      assert updated.buffers.messages == nil
    end
  end

  describe "sync_active_window_buffer/1" do
    test "syncs window buffer to match active buffer" do
      buf1 = start_buffer("first")
      buf2 = start_buffer("second")

      ws =
        %WorkspaceState{
          viewport: Viewport.new(24, 80),
          buffers: %Buffers{list: [buf1, buf2], active_index: 0, active: buf1}
        }
        |> setup_windows()

      # Manually change active buffer without syncing
      ws = %{ws | buffers: %{ws.buffers | active: buf2}}

      synced = Workspace.sync_active_window_buffer(ws)
      win = Workspace.active_window_struct(synced)
      assert win.buffer == buf2
      assert win.content == Content.buffer(buf2)
    end

    test "no-op when buffer is nil" do
      ws = new_workspace()
      assert Workspace.sync_active_window_buffer(ws) == ws
    end

    test "no-op when window buffer already matches" do
      {ws, _buf} = workspace_with_buffer()
      assert Workspace.sync_active_window_buffer(ws) == ws
    end
  end

  # ── Focus window ─────────────────────────────────────────────────────────────

  describe "focus_window/3" do
    test "returns unchanged when target is already active" do
      {ws, _buf} = workspace_with_buffer()

      assert {^ws, nil} = Workspace.focus_window(ws, 1, {0, 0})
    end

    test "returns unchanged when no active buffer" do
      ws = new_workspace()
      assert {^ws, nil} = Workspace.focus_window(ws, 2, {0, 0})
    end

    test "switches active window and returns target cursor" do
      buf1 = start_buffer("first")
      buf2 = start_buffer("second")

      win1 = Window.new(1, buf1, 24, 80)
      win2 = %{Window.new(2, buf2, 24, 80) | cursor: {5, 3}}

      ws = %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{list: [buf1, buf2], active_index: 0, active: buf1},
        windows: %Windows{
          tree: {:split, :horizontal, 0.5, {:leaf, 1}, {:leaf, 2}},
          map: %{1 => win1, 2 => win2},
          active: 1,
          next_id: 3
        }
      }

      {updated, target_cursor} = Workspace.focus_window(ws, 2, {3, 7})

      # Active window switched
      assert updated.windows.active == 2
      assert updated.buffers.active == buf2

      # Old window got cursor saved
      assert Map.get(updated.windows.map, 1).cursor == {3, 7}

      # Target cursor returned for side effect
      assert target_cursor == {5, 3}
    end

    test "returns unchanged for invalid target window id" do
      {ws, _buf} = workspace_with_buffer()

      # Window id 999 doesn't exist in the map
      assert {^ws, nil} = Workspace.focus_window(ws, 999, {0, 0})
    end

    test "derives keymap scope from target window content" do
      buf1 = start_buffer("file")
      buf2 = start_buffer("agent")

      win1 = Window.new(1, buf1, 24, 80)
      win2 = %{Window.new(2, buf2, 24, 80) | content: {:agent_chat, buf2}}

      ws = %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{list: [buf1, buf2], active_index: 0, active: buf1},
        keymap_scope: :editor,
        windows: %Windows{
          tree: {:split, :horizontal, 0.5, {:leaf, 1}, {:leaf, 2}},
          map: %{1 => win1, 2 => win2},
          active: 1,
          next_id: 3
        }
      }

      {updated, _cursor} = Workspace.focus_window(ws, 2, {0, 0})
      assert updated.keymap_scope == :agent
    end
  end

  # ── Mode transitions ────────────────────────────────────────────────────────

  describe "transition_mode/2,3" do
    test "transitions to normal mode" do
      ws = %WorkspaceState{
        viewport: Viewport.new(24, 80),
        vim: %VimState{VimState.new() | mode: :insert}
      }

      updated = Workspace.transition_mode(ws, :normal)
      assert updated.vim.mode == :normal
    end

    test "transitions to insert mode" do
      {ws, _buf} = workspace_with_buffer()
      updated = Workspace.transition_mode(ws, :insert)
      assert updated.vim.mode == :insert
    end
  end

  # ── Cursor sync ──────────────────────────────────────────────────────────────

  describe "sync_active_window_cursor/2" do
    test "stores cursor in the active window" do
      {ws, _buf} = workspace_with_buffer()

      updated = Workspace.sync_active_window_cursor(ws, {10, 5})
      win = Workspace.active_window_struct(updated)
      assert win.cursor == {10, 5}
    end

    test "no-op when no active buffer" do
      ws = new_workspace()
      assert Workspace.sync_active_window_cursor(ws, {0, 0}) == ws
    end
  end
end
