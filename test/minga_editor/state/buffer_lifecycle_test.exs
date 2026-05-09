defmodule MingaEditor.State.BufferLifecycleTest do
  @moduledoc """
  Pure-function tests for buffer lifecycle operations on `EditorState`.

  Tests `add_buffer_pure/2` and `close_buffer_pure/2` without starting
  any GenServer. Uses `base_state/1` from `RenderPipeline.TestHelpers`
  to construct minimal state structs.

  Part of work item B3 from `docs/PLAN-ui-stability.md`.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.WindowTree
  alias MingaEditor.Workspace.State, as: WorkspaceState

  import MingaEditor.RenderPipeline.TestHelpers

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

  @spec state_with_file_tab_for_path(String.t(), String.t()) :: {EditorState.t(), pid()}
  defp state_with_file_tab_for_path(path, content) do
    buf = start_file_buffer(path, content)
    win_id = 1
    window = Window.new(win_id, buf, 24, 80)

    state = %EditorState{
      port_manager: self(),
      workspace: %WorkspaceState{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        buffers: %Buffers{active: buf, list: [buf], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => window},
          active: win_id,
          next_id: win_id + 1
        }
      }
    }

    tab = Tab.new_file(1, Path.basename(path))
    context = EditorState.snapshot_tab_context(state)
    tb = TabBar.new(tab)
    tb = TabBar.update_context(tb, 1, context)

    {EditorState.set_tab_bar(state, tb), buf}
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

  @spec start_file_buffer(String.t(), String.t()) :: pid()
  defp start_file_buffer(path, content) do
    File.write!(path, content)
    {:ok, pid} = BufferServer.start_link(file_path: path)
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

    test "opening a file from a file tab snapshots the outgoing tab before activating the new buffer" do
      state = state_with_file_tab()
      original_buf = state.workspace.buffers.active
      opened_buf = start_buffer("opened")

      {new_state, effects} = EditorState.add_buffer_pure(state, opened_buf, context: :open)

      assert {:monitor, opened_buf} in effects

      tb = new_state.shell_state.tab_bar
      assert TabBar.count(tb) == 2
      assert tb.active_id == 2
      assert %Buffers{active: ^original_buf} = TabBar.get(tb, 1).context.buffers
      assert %Buffers{active: ^opened_buf} = TabBar.get(tb, 2).context.buffers
      assert new_state.workspace.buffers.active == opened_buf
    end

    test "opening a file from an agent tab snapshots the agent tab with the agent buffer" do
      {state, agent_buf} = state_with_agent_tab()
      file_buf = start_buffer("file content")

      {new_state, _effects} = EditorState.add_buffer_pure(state, file_buf, context: :open)

      tb = new_state.shell_state.tab_bar
      agent_tab = TabBar.get(tb, 1)
      file_tab = TabBar.active(tb)

      assert agent_tab.kind == :agent
      assert %Buffers{active: ^agent_buf} = agent_tab.context.buffers
      assert agent_tab.context.keymap_scope == :agent
      assert file_tab.kind == :file
      assert %Buffers{active: ^file_buf} = file_tab.context.buffers
      assert file_tab.context.keymap_scope == :editor
    end

    test "previewing a file does not overwrite the current tab context with the preview buffer" do
      state = state_with_file_tab()
      original_buf = state.workspace.buffers.active
      preview_buf = start_buffer("preview")

      {new_state, _effects} = EditorState.add_buffer_pure(state, preview_buf, context: :preview)

      tb = new_state.shell_state.tab_bar
      assert TabBar.count(tb) == 1
      assert tb.active_id == 1
      assert new_state.workspace.buffers.active == preview_buf
      assert %Buffers{active: ^original_buf} = TabBar.get(tb, 1).context.buffers
      assert new_state.buffer_add_context == :open
    end

    @tag :tmp_dir
    test "opening a file that already has a tab snapshots the outgoing tab before switching", %{
      tmp_dir: tmp_dir
    } do
      path1 = Path.join(tmp_dir, "one.ex")
      path2 = Path.join(tmp_dir, "two.ex")
      {state, buf1} = state_with_file_tab_for_path(path1, "one")
      buf2 = start_file_buffer(path2, "two")

      {state, _effects} = EditorState.add_buffer_pure(state, buf2, context: :open)
      assert state.workspace.buffers.active == buf2

      {new_state, effects} = EditorState.add_buffer_pure(state, buf1, context: :open)

      assert effects == []

      tb = new_state.shell_state.tab_bar
      assert tb.active_id == 1
      assert new_state.workspace.buffers.active == buf1
      assert %Buffers{active: ^buf1} = TabBar.get(tb, 1).context.buffers
      assert %Buffers{active: ^buf2} = TabBar.get(tb, 2).context.buffers
    end

    @tag :tmp_dir
    test "opening a different file with the same basename creates a distinct tab", %{
      tmp_dir: tmp_dir
    } do
      dir1 = Path.join(tmp_dir, "one")
      dir2 = Path.join(tmp_dir, "two")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      path1 = Path.join(dir1, "same.ex")
      path2 = Path.join(dir2, "same.ex")
      {state, buf1} = state_with_file_tab_for_path(path1, "one")
      buf2 = start_file_buffer(path2, "two")

      {new_state, effects} = EditorState.add_buffer_pure(state, buf2, context: :open)

      assert {:monitor, buf2} in effects
      tb = new_state.shell_state.tab_bar
      assert TabBar.count(tb) == 2
      assert tb.active_id == 2
      assert TabBar.get(tb, 1).label == "same.ex"
      assert TabBar.get(tb, 2).label == "same.ex"
      assert %Buffers{active: ^buf1} = TabBar.get(tb, 1).context.buffers
      assert %Buffers{active: ^buf2} = TabBar.get(tb, 2).context.buffers
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

  describe "switch_buffer/2" do
    test "refreshes the active file tab context after an in-place buffer switch" do
      state = state_with_file_tab()
      original_buf = state.workspace.buffers.active
      other_buf = start_buffer("other")

      state =
        EditorState.update_workspace(state, fn workspace ->
          %Buffers{} = buffers = workspace.buffers

          %{
            workspace
            | buffers: %{buffers | list: [original_buf, other_buf]}
          }
        end)

      new_state = EditorState.switch_buffer(state, 1)

      assert new_state.workspace.buffers.active == other_buf

      assert %Buffers{active: ^other_buf} =
               TabBar.active(new_state.shell_state.tab_bar).context.buffers
    end

    test "preview buffer switch does not rewrite the active file tab context" do
      state = state_with_file_tab()
      original_buf = state.workspace.buffers.active
      preview_buf = start_buffer("preview")

      state =
        EditorState.update_workspace(state, fn workspace ->
          %Buffers{} = buffers = workspace.buffers

          %{
            workspace
            | buffers: %{buffers | list: [original_buf, preview_buf]}
          }
        end)
        |> EditorState.set_buffer_add_context(:preview)

      new_state = EditorState.switch_buffer(state, 1)

      assert new_state.workspace.buffers.active == preview_buf
      assert new_state.buffer_add_context == :open

      assert %Buffers{active: ^original_buf} =
               TabBar.active(new_state.shell_state.tab_bar).context.buffers
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
