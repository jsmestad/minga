defmodule MingaEditor.State.ShellCallbacksTest do
  @moduledoc """
  Tests for shell callback dispatch in `EditorState`.

  Verifies that `switch_buffer`, `close_buffer_pure`, and the tab delegate
  functions correctly dispatch through the Shell behaviour. Tests both
  Traditional (with tab bar) and tab-less extension shell paths.

  Part of the shell-owned state transitions proposal
  (`docs/PROPOSAL-shell-state-transitions.md`).
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
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
  alias MingaEditor.Session.State, as: SessionState

  import MingaEditor.RenderPipeline.TestHelpers

  # ── Helpers ──────────────────────────────────────────────────────────────────

  @spec start_buffer(String.t()) :: pid()
  defp start_buffer(content) do
    {:ok, pid} = BufferProcess.start_link(content: content)
    pid
  end

  @spec state_with_file_tab(keyword()) :: EditorState.t()
  defp state_with_file_tab(opts \\ []) do
    state = base_state(opts)
    tab = Tab.new_file(1, "test.ex")
    tb = TabBar.new(tab)
    context = EditorState.snapshot_tab_context(state)
    tb = TabBar.update_context(tb, 1, context)
    EditorState.set_tab_bar(state, tb)
  end

  @spec state_with_agent_chat() :: EditorState.t()
  defp state_with_agent_chat do
    win_id = 1
    agent_window = Window.new_agent_chat(win_id, 24, 80)

    state = %EditorState{
      port_manager: self(),
      shell_runtime: Runtime.new(Registry.get(:traditional), %TraditionalState{}),
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        keymap_scope: :agent,
        buffers: %Buffers{active: nil, list: [], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => agent_window},
          active: win_id,
          next_id: win_id + 1
        }
      }
    }

    state
  end

  @spec state_with_agent_tab() :: EditorState.t()
  defp state_with_agent_tab do
    win_id = 1
    agent_window = Window.new_agent_chat(win_id, 24, 80)

    state = %EditorState{
      port_manager: self(),
      shell_runtime: Runtime.new(Registry.get(:traditional), %TraditionalState{}),
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        keymap_scope: :agent,
        buffers: %Buffers{active: nil, list: [], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => agent_window},
          active: win_id,
          next_id: win_id + 1
        }
      }
    }

    agent_tab = Tab.new_agent(1, "Agent")
    tb = TabBar.new(agent_tab)
    context = EditorState.snapshot_tab_context(state)
    tb = TabBar.update_context(tb, 1, context)
    state = EditorState.set_tab_bar(state, tb)

    state
  end

  # ── on_buffer_switched via BufferActivation ─────────────────────────────────

  describe "BufferActivation.activate/2 dispatches on_buffer_switched" do
    test "Traditional: tab context.buffers.active tracks workspace after switch" do
      state = state_with_file_tab()
      buf2 = start_buffer("second.ex")
      state = EditorState.add_buffer(state, buf2)

      new_state = MingaEditor.BufferActivation.activate(state, 1)

      assert new_state.workspace.buffers.active == buf2

      active_tab = TabBar.active(EditorState.tab_bar(new_state))
      assert active_tab.context.buffers.active == buf2
      assert active_tab.context.buffers.active == new_state.workspace.buffers.active
    end

    test "Traditional: agent tab context.buffers.active tracks workspace after switch" do
      state = state_with_agent_tab()
      buf1 = start_buffer("first agent workspace buffer")
      buf2 = start_buffer("second agent workspace buffer")

      # Manually add buf2 to the buffer list without triggering tab creation
      # (EditorState.add_buffer from an agent tab would create a new file tab)
      state =
        EditorState.update_buffers(state, fn buffers ->
          %{buffers | active: buf1, list: [buf1, buf2], active_index: 0}
        end)

      new_state = MingaEditor.BufferActivation.activate(state, 1)

      assert new_state.workspace.buffers.active == buf2

      active_tab = TabBar.active(EditorState.tab_bar(new_state))
      assert active_tab.kind == :agent
      assert active_tab.context.buffers.active == buf2
      assert active_tab.context.buffers.active == new_state.workspace.buffers.active
    end

    test "Traditional: find_tab_by_buffer returns active tab after switch" do
      state = state_with_file_tab()
      buf2 = start_buffer("second.ex")
      state = EditorState.add_buffer(state, buf2)

      new_state = MingaEditor.BufferActivation.activate(state, 1)

      tab = EditorState.find_tab_by_buffer(new_state, buf2)
      assert %Tab{kind: :file} = tab
      assert tab.id == EditorState.tab_bar(new_state).active_id
    end

    test "Traditional: dirty marker queries correct buffer after switch" do
      state = state_with_file_tab()
      buf1 = state.workspace.buffers.active
      buf2 = start_buffer("clean.ex")
      state = EditorState.add_buffer(state, buf2)

      BufferProcess.insert_char(buf1, "x")
      assert BufferProcess.dirty?(buf1)
      refute BufferProcess.dirty?(buf2)

      new_state = MingaEditor.BufferActivation.activate(state, 1)

      active_tab = TabBar.active(EditorState.tab_bar(new_state))
      tab_buf = active_tab.context.buffers.active
      assert tab_buf == buf2
      refute BufferProcess.dirty?(tab_buf)
    end

    test "Traditional: repeated switch_buffer cycles maintain snapshot invariant" do
      state = state_with_file_tab()
      buf2 = start_buffer("second.ex")
      buf3 = start_buffer("third.ex")
      state = EditorState.add_buffer(state, buf2)
      state = EditorState.add_buffer(state, buf3)

      state = MingaEditor.BufferActivation.activate(state, 1)
      assert TabBar.active(EditorState.tab_bar(state)).context.buffers.active == buf2

      state = MingaEditor.BufferActivation.activate(state, 2)
      assert TabBar.active(EditorState.tab_bar(state)).context.buffers.active == buf3

      state = MingaEditor.BufferActivation.activate(state, 0)
      buf1 = state.workspace.buffers.active
      assert TabBar.active(EditorState.tab_bar(state)).context.buffers.active == buf1

      assert EditorState.find_tab_by_buffer(state, buf1) != nil
    end

    test "no tab bar: switch_buffer still works" do
      state = base_state()
      buf2 = start_buffer("second")
      state = EditorState.add_buffer(state, buf2)

      # Switch back to first buffer
      new_state = MingaEditor.BufferActivation.activate(state, 0)

      # The active buffer changed without error
      refute new_state.workspace.buffers.active == buf2
    end

    test "tab-less extension shell: switch_buffer preserves agent_chat window content" do
      state = state_with_agent_chat()
      file_buf = start_buffer("file content")

      # Add file buffer (the tab-less shell's on_buffer_added doesn't overwrite agent_chat)
      state = EditorState.add_buffer(state, file_buf)

      # Verify window still shows agent_chat
      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)
      assert Content.agent_chat?(window.content)

      # Switch to the only file buffer. The agent window content stays semantic.
      new_state = MingaEditor.BufferActivation.activate(state, 0)
      assert new_state.workspace.buffers.active == file_buf

      # Window content should still be agent_chat
      window = Map.fetch!(new_state.workspace.windows.map, win_id)
      assert Content.agent_chat?(window.content)
    end
  end

  # ── on_buffer_died via close_buffer_pure/2 ───────────────────────────────────

  describe "close_buffer_pure/2 dispatches on_buffer_died" do
    test "Traditional: syncs active window after buffer death" do
      state = state_with_file_tab()
      buf1 = state.workspace.buffers.active
      buf2 = start_buffer("second")
      state = EditorState.add_buffer(state, buf2)
      state = EditorState.monitor_buffer(state, buf1)
      state = EditorState.monitor_buffer(state, buf2)

      # Close the active buffer (buf2)
      new_state = EditorState.close_buffer_pure(state, buf2)

      # buf1 should become active
      assert new_state.workspace.buffers.active == buf1

      # Window should be synced to show buf1 (via on_buffer_died callback)
      win_id = new_state.workspace.windows.active
      window = Map.fetch!(new_state.workspace.windows.map, win_id)
      assert window.buffer == buf1
    end

    test "tab-less extension shell: preserves agent_chat window content on buffer death" do
      state = state_with_agent_chat()
      file_buf = start_buffer("file content")

      # Add and monitor the file buffer
      state = EditorState.add_buffer(state, file_buf)
      state = EditorState.monitor_buffer(state, file_buf)

      # Verify agent_chat window
      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)
      assert Content.agent_chat?(window.content)

      # Close the file buffer
      new_state = EditorState.close_buffer_pure(state, file_buf)

      # Window should still show agent_chat (on_buffer_died respects content guard)
      window = Map.fetch!(new_state.workspace.windows.map, win_id)

      assert Content.agent_chat?(window.content),
             "agent_chat window content should be preserved after buffer death"
    end
  end

  # ── Tab delegate callbacks ──────────────────────────────────────────────────

  describe "active_tab/1 delegates to shell" do
    test "Traditional: returns active tab" do
      state = state_with_file_tab()
      tab = EditorState.active_tab(state)
      assert %Tab{kind: :file} = tab
    end

    test "no tab bar: returns nil" do
      state = base_state()
      assert EditorState.active_tab(state) == nil
    end
  end

  describe "find_tab_by_buffer/2 delegates to shell" do
    test "Traditional: finds tab by buffer pid" do
      state = state_with_file_tab()
      buf = state.workspace.buffers.active

      tab = EditorState.find_tab_by_buffer(state, buf)
      assert %Tab{kind: :file} = tab
    end

    test "Traditional: returns nil for unknown buffer" do
      state = state_with_file_tab()
      fake_pid = spawn(fn -> :ok end)
      assert EditorState.find_tab_by_buffer(state, fake_pid) == nil
    end

    test "no tab bar: returns nil" do
      state = base_state()
      buf = state.workspace.buffers.active
      assert EditorState.find_tab_by_buffer(state, buf) == nil
    end
  end

  describe "active_tab_kind/1 delegates to shell" do
    test "Traditional: returns :file for file tab" do
      state = state_with_file_tab()
      assert EditorState.active_tab_kind(state) == :file
    end

    test "no tab bar: returns :file (default)" do
      state = base_state()
      assert EditorState.active_tab_kind(state) == :file
    end
  end

  describe "set_tab_session/3 delegates to shell" do
    test "Traditional: associates session pid with tab" do
      state = state_with_file_tab()
      session_pid = spawn(fn -> :ok end)
      tab = EditorState.active_tab(state)

      new_state = EditorState.set_tab_session(state, tab.id, session_pid)

      updated_tab = EditorState.active_tab(new_state)
      assert updated_tab.session == session_pid
    end

    test "no tab bar: set_tab_session is no-op" do
      state = base_state()
      session_pid = spawn(fn -> :ok end)

      # Should not crash
      new_state = EditorState.set_tab_session(state, 1, session_pid)
      assert new_state.shell_runtime == state.shell_runtime
    end
  end

  # ── switch_tab_pure/2 no longer pattern-matches tab_bar ─────────────────────

  describe "switch_tab_pure/2 accessor-based dispatch" do
    test "no-op when tab bar is nil" do
      state = base_state()
      {new_state, result} = EditorState.switch_tab_pure(state, 999)
      assert new_state == state
      assert result == :unchanged
    end

    test "no-op when switching to already active tab" do
      state = state_with_file_tab()
      tb = EditorState.tab_bar(state)
      active_id = tb.active_id

      {new_state, result} = EditorState.switch_tab_pure(state, active_id)
      assert new_state == state
      assert result == :unchanged
    end
  end
end
