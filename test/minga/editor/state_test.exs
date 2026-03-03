defmodule Minga.Editor.StateTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Mode

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp new_state do
    %EditorState{
      port_manager: nil,
      viewport: Viewport.new(24, 80),
      mode: :normal,
      mode_state: Mode.initial_state()
    }
  end

  defp start_buffer(content \\ "hello") do
    {:ok, pid} = BufferServer.start_link(content: content)
    pid
  end

  defp state_with_buffer(content \\ "hello") do
    buf = start_buffer(content)

    state =
      %{new_state() | buf: %Buffers{buffers: [buf], active_buffer: 0, buffer: buf}}
      |> setup_windows()

    {state, buf}
  end

  defp setup_windows(state) do
    buf = state.buf.buffer
    tree = WindowTree.new(1)
    window = Window.new(1, buf, 24, 80)
    %{state | window_tree: tree, windows: %{1 => window}, active_window: 1, next_window_id: 2}
  end

  # ── add_buffer/2 ─────────────────────────────────────────────────────────────

  describe "add_buffer/2" do
    test "adds buffer and makes it active" do
      {state, _buf1} = state_with_buffer()
      buf2 = start_buffer("world")

      new_state = EditorState.add_buffer(state, buf2)

      assert new_state.buf.buffer == buf2
      assert length(new_state.buf.buffers) == 2
      assert new_state.buf.active_buffer == 1
    end

    test "syncs the active window's buffer reference" do
      {state, _buf1} = state_with_buffer()
      buf2 = start_buffer("world")

      new_state = EditorState.add_buffer(state, buf2)

      window = Map.fetch!(new_state.windows, new_state.active_window)
      assert window.buffer == buf2
    end

    test "syncs window buffer in split mode" do
      {state, _buf1} = state_with_buffer()

      # Create a split: window 1 (active) and window 2
      {:ok, tree} = WindowTree.split(state.window_tree, 1, :vertical, 2)
      win2 = Window.new(2, state.buf.buffer, 24, 40)

      state = %{
        state
        | window_tree: tree,
          windows: Map.put(state.windows, 2, win2),
          next_window_id: 3
      }

      buf2 = start_buffer("new file")
      new_state = EditorState.add_buffer(state, buf2)

      # Active window (1) should point to new buffer
      assert Map.fetch!(new_state.windows, 1).buffer == buf2
      # Inactive window (2) should still point to old buffer
      assert Map.fetch!(new_state.windows, 2).buffer != buf2
    end

    test "works without windows initialized" do
      state = new_state()
      buf = start_buffer()
      new_state = EditorState.add_buffer(state, buf)

      assert new_state.buf.buffer == buf
    end
  end

  # ── switch_buffer/2 ──────────────────────────────────────────────────────────

  describe "switch_buffer/2" do
    test "switches to existing buffer by index" do
      {state, buf1} = state_with_buffer()
      buf2 = start_buffer("world")
      state = EditorState.add_buffer(state, buf2)

      new_state = EditorState.switch_buffer(state, 0)

      assert new_state.buf.buffer == buf1
      assert new_state.buf.active_buffer == 0
    end

    test "syncs active window's buffer reference on switch" do
      {state, buf1} = state_with_buffer()
      buf2 = start_buffer("world")
      state = EditorState.add_buffer(state, buf2)

      # Switch back to first buffer
      new_state = EditorState.switch_buffer(state, 0)

      window = Map.fetch!(new_state.windows, new_state.active_window)
      assert window.buffer == buf1
    end

    test "syncs window buffer in split mode on switch" do
      {state, buf1} = state_with_buffer()
      buf2 = start_buffer("world")
      state = EditorState.add_buffer(state, buf2)

      # Create a split: window 1 (active, buf2) and window 2 (buf2)
      {:ok, tree} = WindowTree.split(state.window_tree, 1, :vertical, 2)
      win2 = Window.new(2, buf2, 24, 40)

      state = %{
        state
        | window_tree: tree,
          windows: Map.put(state.windows, 2, win2),
          next_window_id: 3
      }

      # Switch active window to buf1
      new_state = EditorState.switch_buffer(state, 0)

      assert Map.fetch!(new_state.windows, 1).buffer == buf1
      # Window 2 unchanged
      assert Map.fetch!(new_state.windows, 2).buffer == buf2
    end
  end

  # ── focus_window/2 ───────────────────────────────────────────────────────────

  describe "focus_window/2" do
    test "switches active window and restores cursor" do
      {state, buf1} = state_with_buffer("hello\nworld\nfoo")
      BufferServer.move_to(buf1, {2, 0})

      # Split: window 1 at {2,0}, window 2 gets copy
      {:ok, tree} = WindowTree.split(state.window_tree, 1, :vertical, 2)
      cursor = BufferServer.cursor(buf1)
      win1 = %{Map.fetch!(state.windows, 1) | cursor: cursor}
      win2 = Window.new(2, buf1, 24, 40, {0, 0})

      state = %{state | window_tree: tree, windows: %{1 => win1, 2 => win2}, next_window_id: 3}

      # Move cursor in active window to {2,0}
      BufferServer.move_to(buf1, {2, 0})

      # Focus window 2 (which has stored cursor {0,0})
      new_state = EditorState.focus_window(state, 2)

      assert new_state.active_window == 2
      assert BufferServer.cursor(buf1) == {0, 0}
    end

    test "saves outgoing window's cursor" do
      {state, buf1} = state_with_buffer("hello\nworld\nfoo")

      {:ok, tree} = WindowTree.split(state.window_tree, 1, :vertical, 2)
      win2 = Window.new(2, buf1, 24, 40)

      state = %{
        state
        | window_tree: tree,
          windows: Map.put(state.windows, 2, win2),
          next_window_id: 3
      }

      # Move cursor to {1, 3}
      BufferServer.move_to(buf1, {1, 3})

      new_state = EditorState.focus_window(state, 2)

      # Window 1 should have saved cursor {1, 3}
      assert Map.fetch!(new_state.windows, 1).cursor == {1, 3}
    end

    test "no-op when focusing already active window" do
      {state, _buf} = state_with_buffer()
      new_state = EditorState.focus_window(state, 1)
      assert new_state == state
    end

    test "no-op when buffer is nil" do
      state = new_state()
      new_state = EditorState.focus_window(state, 2)
      assert new_state == state
    end
  end

  # ── sync_active_window_cursor/1 ─────────────────────────────────────────────

  describe "sync_active_window_cursor/1" do
    test "snapshots buffer cursor into active window" do
      {state, buf} = state_with_buffer("hello\nworld")
      BufferServer.move_to(buf, {1, 3})

      new_state = EditorState.sync_active_window_cursor(state)

      window = Map.fetch!(new_state.windows, 1)
      assert window.cursor == {1, 3}
    end

    test "no-op when buffer is nil" do
      state = new_state()
      assert EditorState.sync_active_window_cursor(state) == state
    end
  end

  # ── split?/1 ─────────────────────────────────────────────────────────────────

  describe "split?/1" do
    test "false for nil tree" do
      refute EditorState.split?(new_state())
    end

    test "false for single leaf" do
      {state, _} = state_with_buffer()
      refute EditorState.split?(state)
    end

    test "true after split" do
      {state, _} = state_with_buffer()
      {:ok, tree} = WindowTree.split(state.window_tree, 1, :vertical, 2)
      win2 = Window.new(2, state.buf.buffer, 24, 40)
      state = %{state | window_tree: tree, windows: Map.put(state.windows, 2, win2)}
      assert EditorState.split?(state)
    end
  end

  # ── screen_rect/1 ───────────────────────────────────────────────────────────

  describe "screen_rect/1" do
    test "excludes one row for minibuffer" do
      {state, _} = state_with_buffer()
      assert EditorState.screen_rect(state) == {0, 0, 80, 23}
    end
  end
end
