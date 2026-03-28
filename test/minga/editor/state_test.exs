defmodule Minga.Editor.StateTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Editor.WindowTree

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp new_state do
    %EditorState{
      port_manager: nil,
      workspace: %Minga.Workspace.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new()
      }
    }
  end

  defp start_buffer(content \\ "hello") do
    {:ok, pid} = BufferServer.start_link(content: content)
    pid
  end

  defp state_with_buffer(content \\ "hello") do
    buf = start_buffer(content)

    state =
      put_in(new_state().workspace.buffers, %Buffers{list: [buf], active_index: 0, active: buf})
      |> setup_windows()

    {state, buf}
  end

  defp setup_windows(state) do
    buf = state.workspace.buffers.active
    tree = WindowTree.new(1)
    window = Window.new(1, buf, 24, 80)

    %{
      state
      | workspace: %{
          state.workspace
          | windows: %Windows{tree: tree, map: %{1 => window}, active: 1, next_id: 2}
        }
    }
  end

  # ── add_buffer/2 ─────────────────────────────────────────────────────────────

  describe "add_buffer/2" do
    test "adds buffer and makes it active" do
      {state, _buf1} = state_with_buffer()
      buf2 = start_buffer("world")

      new_state = EditorState.add_buffer(state, buf2)

      assert new_state.workspace.buffers.active == buf2
      assert length(new_state.workspace.buffers.list) == 2
      assert new_state.workspace.buffers.active_index == 1
    end

    test "syncs the active window's buffer reference" do
      {state, _buf1} = state_with_buffer()
      buf2 = start_buffer("world")

      new_state = EditorState.add_buffer(state, buf2)

      window = Map.fetch!(new_state.workspace.windows.map, new_state.workspace.windows.active)
      assert window.buffer == buf2
    end

    test "syncs window buffer in split mode" do
      {state, _buf1} = state_with_buffer()

      # Create a split: window 1 (active) and window 2
      {:ok, tree} = WindowTree.split(state.workspace.windows.tree, 1, :vertical, 2)
      win2 = Window.new(2, state.workspace.buffers.active, 24, 40)
      ws = state.workspace.windows

      state =
        put_in(state.workspace.windows, %{
          ws
          | tree: tree,
            map: Map.put(ws.map, 2, win2),
            next_id: 3
        })

      buf2 = start_buffer("new file")
      new_state = EditorState.add_buffer(state, buf2)

      # Active window (1) should point to new buffer
      assert Map.fetch!(new_state.workspace.windows.map, 1).buffer == buf2
      # Inactive window (2) should still point to old buffer
      assert Map.fetch!(new_state.workspace.windows.map, 2).buffer != buf2
    end

    test "works without windows initialized" do
      state = new_state()
      buf = start_buffer()
      new_state = EditorState.add_buffer(state, buf)

      assert new_state.workspace.buffers.active == buf
    end
  end

  # ── switch_buffer/2 ──────────────────────────────────────────────────────────

  describe "switch_buffer/2" do
    test "switches to existing buffer by index" do
      {state, buf1} = state_with_buffer()
      buf2 = start_buffer("world")
      state = EditorState.add_buffer(state, buf2)

      new_state = EditorState.switch_buffer(state, 0)

      assert new_state.workspace.buffers.active == buf1
      assert new_state.workspace.buffers.active_index == 0
    end

    test "syncs active window's buffer reference on switch" do
      {state, buf1} = state_with_buffer()
      buf2 = start_buffer("world")
      state = EditorState.add_buffer(state, buf2)

      # Switch back to first buffer
      new_state = EditorState.switch_buffer(state, 0)

      window = Map.fetch!(new_state.workspace.windows.map, new_state.workspace.windows.active)
      assert window.buffer == buf1
    end

    test "syncs window buffer in split mode on switch" do
      {state, buf1} = state_with_buffer()
      buf2 = start_buffer("world")
      state = EditorState.add_buffer(state, buf2)

      # Create a split: window 1 (active, buf2) and window 2 (buf2)
      {:ok, tree} = WindowTree.split(state.workspace.windows.tree, 1, :vertical, 2)
      win2 = Window.new(2, buf2, 24, 40)
      ws = state.workspace.windows

      state =
        put_in(state.workspace.windows, %{
          ws
          | tree: tree,
            map: Map.put(ws.map, 2, win2),
            next_id: 3
        })

      # Switch active window to buf1
      new_state = EditorState.switch_buffer(state, 0)

      assert Map.fetch!(new_state.workspace.windows.map, 1).buffer == buf1
      # Window 2 unchanged
      assert Map.fetch!(new_state.workspace.windows.map, 2).buffer == buf2
    end
  end

  # ── focus_window/2 ───────────────────────────────────────────────────────────

  describe "focus_window/2" do
    test "switches active window and restores cursor" do
      {state, buf1} = state_with_buffer("hello\nworld\nfoo")
      BufferServer.move_to(buf1, {2, 0})

      # Split: window 1 at {2,0}, window 2 gets copy
      {:ok, tree} = WindowTree.split(state.workspace.windows.tree, 1, :vertical, 2)
      cursor = BufferServer.cursor(buf1)
      win1 = %{Map.fetch!(state.workspace.windows.map, 1) | cursor: cursor}
      win2 = Window.new(2, buf1, 24, 40, {0, 0})

      state =
        put_in(state.workspace.windows, %Windows{
          tree: tree,
          map: %{1 => win1, 2 => win2},
          active: 1,
          next_id: 3
        })

      # Move cursor in active window to {2,0}
      BufferServer.move_to(buf1, {2, 0})

      # Focus window 2 (which has stored cursor {0,0})
      new_state = EditorState.focus_window(state, 2)

      assert new_state.workspace.windows.active == 2
      assert BufferServer.cursor(buf1) == {0, 0}
    end

    test "saves outgoing window's cursor" do
      {state, buf1} = state_with_buffer("hello\nworld\nfoo")

      {:ok, tree} = WindowTree.split(state.workspace.windows.tree, 1, :vertical, 2)
      win2 = Window.new(2, buf1, 24, 40)
      ws = state.workspace.windows

      state =
        put_in(state.workspace.windows, %{
          ws
          | tree: tree,
            map: Map.put(ws.map, 2, win2),
            next_id: 3
        })

      # Move cursor to {1, 3}
      BufferServer.move_to(buf1, {1, 3})

      new_state = EditorState.focus_window(state, 2)

      # Window 1 should have saved cursor {1, 3}
      assert Map.fetch!(new_state.workspace.windows.map, 1).cursor == {1, 3}
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

      window = Map.fetch!(new_state.workspace.windows.map, 1)
      assert window.cursor == {1, 3}
    end

    test "no-op when buffer is nil" do
      state = new_state()
      assert EditorState.sync_active_window_cursor(state) == state
    end
  end

  # ── screen_rect/1 ───────────────────────────────────────────────────────────

  describe "screen_rect/1" do
    test "excludes one row for minibuffer" do
      {state, _} = state_with_buffer()
      assert EditorState.screen_rect(state) == {0, 0, 80, 23}
    end
  end

  # ── sync_active_window_buffer/1 — window.content field ───────────────────────

  describe "sync_active_window_buffer/1 content field" do
    test "updates window.content to {:buffer, new_pid} when buffer changes" do
      {state, _buf1} = state_with_buffer("hello")
      buf2 = start_buffer("world")

      state = %{
        state
        | workspace: %{state.workspace | buffers: Buffers.add(state.workspace.buffers, buf2)}
      }

      new_state = EditorState.sync_active_window_buffer(state)

      window = Map.fetch!(new_state.workspace.windows.map, new_state.workspace.windows.active)
      assert window.buffer == buf2
      assert Content.buffer?(window.content), "content should be a :buffer reference"

      assert Content.buffer_pid(window.content) == buf2,
             "content should reference the new buffer pid, " <>
               "got #{inspect(window.content)}"
    end

    test "preserves agent_chat content when buffer changes" do
      agent_buf = start_buffer("")
      file_buf = start_buffer("defmodule Foo, do: :ok")

      # Build state with an agent_chat window
      state =
        %{
          new_state()
          | workspace: %{
              new_state().workspace
              | buffers: %Buffers{list: [agent_buf], active_index: 0, active: agent_buf}
            }
        }

      tree = WindowTree.new(1)
      agent_window = Window.new_agent_chat(1, agent_buf, 24, 80)

      state =
        put_in(state.workspace.windows, %Windows{
          tree: tree,
          map: %{1 => agent_window},
          active: 1,
          next_id: 2
        })

      # Confirm starting state: agent_chat content
      window = Map.fetch!(state.workspace.windows.map, 1)
      assert Content.agent_chat?(window.content)

      # Switch active buffer to the file buffer
      state = %{
        state
        | workspace: %{state.workspace | buffers: Buffers.add(state.workspace.buffers, file_buf)}
      }

      # sync_active_window_buffer should NOT overwrite agent_chat content
      new_state = EditorState.sync_active_window_buffer(state)

      window = Map.fetch!(new_state.workspace.windows.map, 1)
      assert window.buffer == agent_buf

      assert Content.agent_chat?(window.content),
             "content should remain agent_chat, got #{inspect(window.content)}"
    end

    test "no-op when buffer has not changed" do
      {state, buf1} = state_with_buffer("hello")
      window_before = Map.fetch!(state.workspace.windows.map, state.workspace.windows.active)

      new_state = EditorState.sync_active_window_buffer(state)

      window_after =
        Map.fetch!(new_state.workspace.windows.map, new_state.workspace.windows.active)

      assert window_after.buffer == buf1
      assert window_after.content == window_before.content
    end
  end

  # ── add_buffer/2 from agent tab ──────────────────────────────────────────────

  describe "add_buffer/2 from agent tab" do
    setup do
      agent_buf = start_buffer("")

      state =
        %{
          new_state()
          | workspace: %{
              new_state().workspace
              | buffers: %Buffers{list: [agent_buf], active_index: 0, active: agent_buf}
            }
        }

      tree = WindowTree.new(1)
      agent_window = Window.new_agent_chat(1, agent_buf, 24, 80)

      state =
        put_in(state.workspace.windows, %Windows{
          tree: tree,
          map: %{1 => agent_window},
          active: 1,
          next_id: 2
        })

      state = put_in(state.workspace.keymap_scope, :agent)
      state = EditorState.set_tab_bar(state, TabBar.new(Tab.new_agent(1, "Agent")))

      %{state: state, agent_buf: agent_buf}
    end

    test "creates a file tab and makes it active", %{state: state} do
      file_buf = start_buffer("file content")
      new_state = EditorState.add_buffer(state, file_buf)

      active_tab = TabBar.active(new_state.shell_state.tab_bar)
      assert active_tab.kind == :file
    end

    test "switches keymap_scope from :agent to :editor", %{state: state} do
      file_buf = start_buffer("file content")
      new_state = EditorState.add_buffer(state, file_buf)

      assert new_state.workspace.keymap_scope == :editor
    end

    test "active window buffer points to the new file buffer", %{state: state} do
      file_buf = start_buffer("file content")
      new_state = EditorState.add_buffer(state, file_buf)

      window = Map.fetch!(new_state.workspace.windows.map, new_state.workspace.windows.active)
      assert window.buffer == file_buf
    end

    test "active window content is {:buffer, _}, not {:agent_chat, _}", %{state: state} do
      file_buf = start_buffer("file content")
      new_state = EditorState.add_buffer(state, file_buf)

      window = Map.fetch!(new_state.workspace.windows.map, new_state.workspace.windows.active)

      assert Content.buffer?(window.content),
             "window content should be {:buffer, _} after opening file from agent tab, " <>
               "got #{inspect(window.content)}"

      refute Content.agent_chat?(window.content),
             "window content should not be :agent_chat after opening file"
    end

    test "new file tab context has correct window content type", %{state: state} do
      file_buf = start_buffer("file content")
      new_state = EditorState.add_buffer(state, file_buf)

      # The new file tab's snapshotted context should also have the correct
      # window content type, so switching tabs restores it properly.
      active_tab = TabBar.active(new_state.shell_state.tab_bar)
      tab_windows = active_tab.context[:windows]

      if tab_windows do
        active_win_id = tab_windows.active
        tab_window = Map.get(tab_windows.map, active_win_id)

        if tab_window do
          assert Content.buffer?(tab_window.content),
                 "tab context window content should be {:buffer, _}, " <>
                   "got #{inspect(tab_window.content)}"
        end
      end
    end
  end

  describe "buffer monitoring" do
    test "monitor_buffer/2 stores a monitor ref for the pid" do
      buf = start_buffer()
      state = new_state() |> EditorState.monitor_buffer(buf)

      assert Map.has_key?(state.buffer_monitors, buf)
      assert is_reference(state.buffer_monitors[buf])
    end

    test "monitor_buffer/2 is idempotent" do
      buf = start_buffer()
      state = new_state() |> EditorState.monitor_buffer(buf)
      ref = state.buffer_monitors[buf]

      state2 = EditorState.monitor_buffer(state, buf)
      assert state2.buffer_monitors[buf] == ref
      assert map_size(state2.buffer_monitors) == 1
    end

    test "monitor_buffers/2 monitors multiple pids" do
      buf1 = start_buffer("one")
      buf2 = start_buffer("two")
      state = new_state() |> EditorState.monitor_buffers([buf1, buf2])

      assert map_size(state.buffer_monitors) == 2
      assert Map.has_key?(state.buffer_monitors, buf1)
      assert Map.has_key?(state.buffer_monitors, buf2)
    end

    test "remove_dead_buffer/2 removes pid from buffer list" do
      buf1 = start_buffer("one")
      buf2 = start_buffer("two")

      state =
        new_state()
        |> EditorState.add_buffer(buf1)
        |> EditorState.add_buffer(buf2)
        |> EditorState.monitor_buffer(buf1)
        |> EditorState.monitor_buffer(buf2)

      state = EditorState.remove_dead_buffer(state, buf1)

      refute buf1 in state.workspace.buffers.list
      assert buf2 in state.workspace.buffers.list
      refute Map.has_key?(state.buffer_monitors, buf1)
      assert Map.has_key?(state.buffer_monitors, buf2)
    end

    test "remove_dead_buffer/2 switches active to next buffer" do
      buf1 = start_buffer("one")
      buf2 = start_buffer("two")

      state =
        new_state()
        |> EditorState.add_buffer(buf1)
        |> EditorState.add_buffer(buf2)

      # buf2 is active (last added)
      assert state.workspace.buffers.active == buf2

      state = EditorState.remove_dead_buffer(state, buf2)

      assert state.workspace.buffers.active == buf1
      assert state.workspace.buffers.list == [buf1]
    end

    test "remove_dead_buffer/2 clears special buffer slot" do
      buf = start_buffer()

      state =
        put_in(new_state().workspace.buffers, %Buffers{
          messages: buf,
          list: [buf],
          active: buf,
          active_index: 0
        })

      state = EditorState.monitor_buffer(state, buf)
      state = EditorState.remove_dead_buffer(state, buf)

      assert state.workspace.buffers.messages == nil
      assert state.workspace.buffers.list == []
    end
  end
end
