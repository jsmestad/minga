defmodule Minga.Editor.State.BufferLifecycleTest do
  @moduledoc """
  Pure-function tests for buffer lifecycle operations on `EditorState`.

  Tests `add_buffer_pure/2` and `close_buffer_pure/2` without starting
  any GenServer. Uses `base_state/1` from `RenderPipeline.TestHelpers`
  to construct minimal state structs.

  Part of work item B3 from `docs/PLAN-ui-stability.md`.
  """

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
  alias Minga.Workspace.State, as: WorkspaceState

  import Minga.Editor.RenderPipeline.TestHelpers

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Creates a base state with a tab bar containing a single file tab.
  # The file tab is set up with a context snapshot matching the current
  # workspace state, simulating a real editor with an open file.
  @spec state_with_file_tab(keyword()) :: EditorState.t()
  defp state_with_file_tab(opts \\ []) do
    state = base_state(opts)
    tab = Tab.new_file(1, "test.ex")
    tb = TabBar.new(tab)

    # Snapshot the workspace into the active tab's context
    context = EditorState.snapshot_tab_context(state)
    tb = TabBar.update_context(tb, 1, context)

    EditorState.set_tab_bar(state, tb)
  end

  # Creates a state with an agent tab active and an agent_chat window.
  @spec state_with_agent_tab() :: {EditorState.t(), pid()}
  defp state_with_agent_tab do
    {:ok, agent_buf} = BufferServer.start_link(content: "")
    win_id = 1
    agent_window = Window.new_agent_chat(win_id, agent_buf, 24, 80)

    state = %EditorState{
      port_manager: self(),
      workspace: %WorkspaceState{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        keymap_scope: :agent,
        buffers: %Buffers{active: agent_buf, list: [agent_buf], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => agent_window},
          active: win_id,
          next_id: win_id + 1
        }
      }
    }

    agent_tab = Tab.new_agent(1, "Agent")
    context = EditorState.snapshot_tab_context(state)
    tb = TabBar.new(agent_tab)
    tb = TabBar.update_context(tb, 1, context)
    state = EditorState.set_tab_bar(state, tb)

    {state, agent_buf}
  end

  # Starts a buffer for use in tests. Returns the pid.
  @spec start_buffer(String.t()) :: pid()
  defp start_buffer(content) do
    {:ok, pid} = BufferServer.start_link(content: content)
    pid
  end

  # ── add_buffer_pure/2 ─────────────────────────────────────────────────────────

  describe "add_buffer_pure/2" do
    test "adds buffer to empty state (no tab bar)" do
      state = base_state()
      new_buf = start_buffer("new file")

      {new_state, effects} = EditorState.add_buffer_pure(state, new_buf)

      assert new_buf in new_state.workspace.buffers.list
      assert new_state.workspace.buffers.active == new_buf
      assert {:monitor, new_buf} in effects
    end

    test "adds buffer when file tab active (in-place replace)" do
      state = state_with_file_tab()
      original_buf = state.workspace.buffers.active
      new_buf = start_buffer("new file")

      {new_state, effects} = EditorState.add_buffer_pure(state, new_buf)

      # Buffer is in the pool and active
      assert new_buf in new_state.workspace.buffers.list
      assert new_state.workspace.buffers.active == new_buf

      # Monitor effect is present
      assert {:monitor, new_buf} in effects

      # The active tab should still be a file tab (in-place replace, not new tab)
      tb = new_state.shell_state.tab_bar
      active_tab = TabBar.active(tb)
      assert active_tab.kind == :file

      # Should still have the same number of tabs (in-place, may create new file tab)
      # The key invariant is that the new buffer is now active
      assert new_state.workspace.buffers.active == new_buf
      refute new_state.workspace.buffers.active == original_buf
    end

    test "adds buffer when agent tab active (new file tab)" do
      {state, _agent_buf} = state_with_agent_tab()
      file_buf = start_buffer("file content")

      {new_state, effects} = EditorState.add_buffer_pure(state, file_buf)

      # Buffer is in the pool and active
      assert file_buf in new_state.workspace.buffers.list
      assert new_state.workspace.buffers.active == file_buf

      # Monitor effect is present
      assert {:monitor, file_buf} in effects

      # A new file tab should be created and made active
      tb = new_state.shell_state.tab_bar
      active_tab = TabBar.active(tb)
      assert active_tab.kind == :file

      # Should have two tabs: the original agent tab + new file tab
      assert TabBar.count(tb) == 2

      # Keymap scope should switch from :agent to :editor
      assert new_state.workspace.keymap_scope == :editor

      # Active window content should be a buffer, not agent_chat
      window = Map.fetch!(new_state.workspace.windows.map, new_state.workspace.windows.active)
      assert Content.buffer?(window.content)
    end

    test "adds duplicate buffer (switches to existing tab)" do
      state = state_with_file_tab()
      buf = state.workspace.buffers.active

      # Create a second file tab with a different buffer
      {:ok, buf2} = BufferServer.start_link(content: "second file")
      state = EditorState.add_buffer(state, buf2)

      # Now we have two tabs; the second (buf2) is active
      tb = state.shell_state.tab_bar
      assert TabBar.count(tb) >= 2
      assert state.workspace.buffers.active == buf2

      # "Add" the first buffer again - should switch to its existing tab
      {new_state, effects} = EditorState.add_buffer_pure(state, buf)

      # The first buffer should now be active
      assert new_state.workspace.buffers.active == buf
      # No monitor effect — buffer was already monitored from the first add
      assert effects == []
    end

    test "syncs the active window buffer reference" do
      state = state_with_file_tab()
      new_buf = start_buffer("new file")

      {new_state, _effects} = EditorState.add_buffer_pure(state, new_buf)

      window = Map.fetch!(new_state.workspace.windows.map, new_state.workspace.windows.active)
      assert window.buffer == new_buf
    end
  end

  # ── close_buffer_pure/2 ────────────────────────────────────────────────────────

  describe "close_buffer_pure/2" do
    test "closes active buffer and switches to neighbor" do
      state = base_state()
      buf1 = state.workspace.buffers.active
      buf2 = start_buffer("second")

      # Add second buffer so we have two
      state = EditorState.add_buffer(state, buf2)
      assert state.workspace.buffers.active == buf2
      assert length(state.workspace.buffers.list) == 2

      # Monitor both buffers so close_buffer_pure can clean up
      state = EditorState.monitor_buffer(state, buf1)
      state = EditorState.monitor_buffer(state, buf2)

      # Close the active buffer
      {new_state, effects} = EditorState.close_buffer_pure(state, buf2)

      # buf2 should be removed, buf1 should become active
      refute buf2 in new_state.workspace.buffers.list
      assert buf1 in new_state.workspace.buffers.list
      assert new_state.workspace.buffers.active == buf1

      # Effects list should be empty (close_buffer_pure returns [])
      assert effects == []

      # Monitor ref should be cleaned up
      refute Map.has_key?(new_state.buffer_monitors, buf2)
    end

    test "closes only buffer gracefully" do
      state = base_state()
      buf = state.workspace.buffers.active
      state = EditorState.monitor_buffer(state, buf)

      {new_state, effects} = EditorState.close_buffer_pure(state, buf)

      assert new_state.workspace.buffers.list == []
      assert new_state.workspace.buffers.active == nil
      assert effects == []
      refute Map.has_key?(new_state.buffer_monitors, buf)
    end

    test "closes inactive buffer without affecting active" do
      state = base_state()
      buf1 = state.workspace.buffers.active
      buf2 = start_buffer("second")
      buf3 = start_buffer("third")

      state = EditorState.add_buffer(state, buf2)
      state = EditorState.add_buffer(state, buf3)
      state = EditorState.monitor_buffer(state, buf1)
      state = EditorState.monitor_buffer(state, buf2)
      state = EditorState.monitor_buffer(state, buf3)

      # buf3 is active; close buf1 (inactive)
      assert state.workspace.buffers.active == buf3

      {new_state, _effects} = EditorState.close_buffer_pure(state, buf1)

      # Active buffer should remain buf3
      assert new_state.workspace.buffers.active == buf3
      refute buf1 in new_state.workspace.buffers.list
    end

    test "clears special buffer slot when messages buffer dies" do
      {:ok, msg_buf} = BufferServer.start_link(content: "")

      state = %EditorState{
        port_manager: self(),
        workspace: %WorkspaceState{
          viewport: Viewport.new(24, 80),
          editing: VimState.new(),
          buffers: %Buffers{
            active: msg_buf,
            list: [msg_buf],
            active_index: 0,
            messages: msg_buf
          }
        }
      }

      state = EditorState.monitor_buffer(state, msg_buf)

      {new_state, _effects} = EditorState.close_buffer_pure(state, msg_buf)

      assert new_state.workspace.buffers.messages == nil
    end
  end

  # ── add_buffer_pure/2 with Board shell (agent_chat content guard) ──────────────

  describe "add_buffer_pure/2 with agent_chat content" do
    test "preserves agent_chat window content when adding buffer" do
      # This tests the A1 content-type guard in sync_active_window_buffer.
      # When a window has {:agent_chat, _} content, adding a new buffer
      # to the buffer pool should NOT overwrite the window's content type.
      {:ok, agent_buf} = BufferServer.start_link(content: "")
      win_id = 1
      agent_window = Window.new_agent_chat(win_id, agent_buf, 24, 80)

      state = %EditorState{
        port_manager: self(),
        workspace: %WorkspaceState{
          viewport: Viewport.new(24, 80),
          editing: VimState.new(),
          buffers: %Buffers{active: agent_buf, list: [agent_buf], active_index: 0},
          windows: %Windows{
            tree: WindowTree.new(win_id),
            map: %{win_id => agent_window},
            active: win_id,
            next_id: win_id + 1
          }
        }
      }

      # Confirm starting state: agent_chat content
      window = Map.fetch!(state.workspace.windows.map, win_id)
      assert Content.agent_chat?(window.content)

      # Add a new buffer without a tab bar (exercises the no-tab-bar clause)
      file_buf = start_buffer("file content")
      {new_state, effects} = EditorState.add_buffer_pure(state, file_buf)

      # The buffer should be added and active
      assert file_buf in new_state.workspace.buffers.list
      assert new_state.workspace.buffers.active == file_buf
      assert {:monitor, file_buf} in effects

      # But the window should still have agent_chat content because
      # sync_active_window_buffer guards on content type
      window = Map.fetch!(new_state.workspace.windows.map, win_id)

      assert Content.agent_chat?(window.content),
             "agent_chat window content should be preserved, got #{inspect(window.content)}"

      assert window.buffer == agent_buf,
             "window buffer pid should remain the agent buffer"
    end
  end
end
