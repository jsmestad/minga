defmodule MingaEditor.State.TabSwitchTest do
  @moduledoc """
  Pure-function tests for tab switching via `switch_tab_pure/2`.

  Tests snapshot/restore of workspace context across tab switches without
  starting any GenServer. Uses `base_state/1` from `RenderPipeline.TestHelpers`
  to construct minimal state structs.

  Part of work item B3 from `docs/PLAN-ui-stability.md`.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Session.State, as: SessionState

  alias MingaEditor.State.Highlighting
  alias MingaEditor.UI.Highlight

  import MingaEditor.RenderPipeline.TestHelpers

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Builds a state with two file tabs. Tab 1 is active with buf1, tab 2
  # has buf2 snapshotted in its context.
  @spec state_with_two_file_tabs() :: {EditorState.t(), pid(), pid()}
  defp state_with_two_file_tabs do
    {:ok, buf1} = BufferProcess.start_link(content: "file one")
    {:ok, buf2} = BufferProcess.start_link(content: "file two")

    win_id = 1
    window1 = Window.new(win_id, buf1, 24, 80)

    state = %EditorState{
      port_manager: self(),
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        keymap_scope: :editor,
        buffers: %Buffers{active: buf1, list: [buf1], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => window1},
          active: win_id,
          next_id: win_id + 1
        }
      }
    }

    # Set up tab bar with tab 1 active
    tab1 = Tab.new_file(1, "one.ex")
    tb = TabBar.new(tab1)
    context1 = EditorState.snapshot_tab_context(state)
    tb = TabBar.update_context(tb, 1, context1)

    # Create tab 2 with buf2 in its context
    {tb, tab2} = TabBar.add(tb, :file, "two.ex")

    # Build tab 2's context: a workspace with buf2 active
    win2 = Window.new(win_id, buf2, 24, 80)

    tab2_ws = %SessionState{
      viewport: Viewport.new(24, 80),
      editing: VimState.new(),
      keymap_scope: :editor,
      buffers: %Buffers{active: buf2, list: [buf2], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(win_id),
        map: %{win_id => win2},
        active: win_id,
        next_id: win_id + 1
      }
    }

    tab2_context = Map.from_struct(tab2_ws)
    tb = TabBar.update_context(tb, tab2.id, tab2_context)

    # Switch back to tab 1 as active
    tb = TabBar.switch_to(tb, 1)

    state = EditorState.set_tab_bar(state, tb)

    {state, buf1, buf2}
  end

  # Builds a state with a file tab and an agent tab.
  # File tab (tab 1) is active.
  @spec state_with_file_and_agent_tabs() ::
          {EditorState.t(), Tab.id(), Tab.id(), pid(), pid()}
  defp state_with_file_and_agent_tabs do
    {:ok, file_buf} = BufferProcess.start_link(content: "file content")
    {:ok, agent_buf} = BufferProcess.start_link(content: "")

    win_id = 1
    file_window = Window.new(win_id, file_buf, 24, 80)

    state = %EditorState{
      port_manager: self(),
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        keymap_scope: :editor,
        buffers: %Buffers{active: file_buf, list: [file_buf], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => file_window},
          active: win_id,
          next_id: win_id + 1
        }
      }
    }

    # Set up tab bar: file tab 1 active, agent tab 2
    file_tab = Tab.new_file(1, "app.ex")
    tb = TabBar.new(file_tab)
    file_context = EditorState.snapshot_tab_context(state)
    tb = TabBar.update_context(tb, 1, file_context)

    {tb, agent_tab} = TabBar.add(tb, :agent, "Agent")

    # Build agent tab context with :agent keymap_scope and agent_chat window
    agent_window = Window.new_agent_chat(win_id, agent_buf, 24, 80)

    agent_ws = %SessionState{
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

    agent_context = Map.from_struct(agent_ws)
    tb = TabBar.update_context(tb, agent_tab.id, agent_context)

    # Switch back to tab 1 (file tab active)
    tb = TabBar.switch_to(tb, 1)

    state = EditorState.set_tab_bar(state, tb)

    {state, file_tab.id, agent_tab.id, file_buf, agent_buf}
  end

  # ── switch_tab_pure/2 ─────────────────────────────────────────────────────────

  describe "switch_tab_pure/2" do
    test "no-op when tab bar is nil" do
      state = base_state()
      assert state.shell_state.tab_bar == nil

      {new_state, effects} = EditorState.switch_tab_pure(state, 42)

      assert new_state == state
      assert effects == []
    end

    test "no-op when switching to already active tab" do
      {state, _buf1, _buf2} = state_with_two_file_tabs()
      tb = state.shell_state.tab_bar
      active_id = tb.active_id

      {new_state, effects} = EditorState.switch_tab_pure(state, active_id)

      assert new_state == state
      assert effects == []
    end

    test "file-to-file preserves both tab contexts" do
      {state, buf1, buf2} = state_with_two_file_tabs()
      tb = state.shell_state.tab_bar
      tab2_id = Enum.find(tb.tabs, &(&1.id != tb.active_id)).id

      # Confirm starting state
      assert state.workspace.buffers.active == buf1
      assert state.workspace.keymap_scope == :editor

      # Switch to tab 2
      {new_state, effects} = EditorState.switch_tab_pure(state, tab2_id)

      # Active buffer should now be buf2 (restored from tab 2's context)
      assert new_state.workspace.buffers.active == buf2
      assert new_state.workspace.keymap_scope == :editor

      # Effects should include spinner lifecycle effects
      assert :stop_spinner in effects
      assert :start_spinner in effects

      # Tab 1's context should be snapshotted (preserved for later restore)
      tb = new_state.shell_state.tab_bar
      tab1 = TabBar.get(tb, 1)
      assert tab1.context.buffers.active == buf1
    end

    test "file-to-agent sets keymap_scope to :agent" do
      {state, file_tab_id, agent_tab_id, _file_buf, _agent_buf} =
        state_with_file_and_agent_tabs()

      # Confirm starting state: file tab active with :editor scope
      assert state.workspace.keymap_scope == :editor

      # Switch to agent tab
      {new_state, _effects} = EditorState.switch_tab_pure(state, agent_tab_id)

      # The restored workspace should have :agent scope (from the agent tab's context)
      assert new_state.workspace.keymap_scope == :agent

      # The tab bar should show the agent tab as active
      tb = new_state.shell_state.tab_bar
      assert tb.active_id == agent_tab_id
      active_tab = TabBar.active(tb)
      assert active_tab.kind == :agent

      # The file tab's context should be snapshotted
      file_tab = TabBar.get(tb, file_tab_id)
      assert file_tab.context.keymap_scope == :editor
    end

    test "agent-to-file sets keymap_scope to :editor" do
      {state, file_tab_id, agent_tab_id, _file_buf, _agent_buf} =
        state_with_file_and_agent_tabs()

      # First switch to agent tab to set up the agent-active state
      {state, _effects} = EditorState.switch_tab_pure(state, agent_tab_id)
      assert state.workspace.keymap_scope == :agent

      # Now switch back to file tab
      {new_state, _effects} = EditorState.switch_tab_pure(state, file_tab_id)

      # Should restore :editor scope
      assert new_state.workspace.keymap_scope == :editor

      # The agent tab's context should be preserved
      tb = new_state.shell_state.tab_bar
      agent_tab = TabBar.get(tb, agent_tab_id)
      assert agent_tab.context.keymap_scope == :agent
    end

    test "round-trip invariant: switch away and back restores equivalent state" do
      {state, _buf1, buf2} = state_with_two_file_tabs()
      tb = state.shell_state.tab_bar
      tab2_id = Enum.find(tb.tabs, &(&1.id != tb.active_id)).id

      # Capture the workspace state before any switch
      original_buffers = state.workspace.buffers
      original_scope = state.workspace.keymap_scope
      original_editing = state.workspace.editing

      # Switch to tab 2
      {state_after_switch, _effects1} = EditorState.switch_tab_pure(state, tab2_id)
      assert state_after_switch.workspace.buffers.active == buf2

      # Switch back to tab 1
      {state_after_roundtrip, _effects2} = EditorState.switch_tab_pure(state_after_switch, 1)

      # The workspace should be equivalent to the original
      assert state_after_roundtrip.workspace.buffers.active == original_buffers.active
      assert state_after_roundtrip.workspace.buffers.list == original_buffers.list

      assert state_after_roundtrip.workspace.buffers.active_index ==
               original_buffers.active_index

      assert state_after_roundtrip.workspace.keymap_scope == original_scope
      assert state_after_roundtrip.workspace.editing.mode == original_editing.mode
    end

    test "effects include spinner lifecycle and agent session rebuild" do
      {state, _file_tab_id, agent_tab_id, _file_buf, _agent_buf} =
        state_with_file_and_agent_tabs()

      {_new_state, effects} = EditorState.switch_tab_pure(state, agent_tab_id)

      assert :stop_spinner in effects
      assert :start_spinner in effects

      # There should be a rebuild_agent_session effect with the target tab
      assert Enum.any?(effects, fn
               {:rebuild_agent_session, %Tab{}} -> true
               _ -> false
             end)
    end

    test "invalidates layout after switch" do
      {state, _buf1, _buf2} = state_with_two_file_tabs()
      tb = state.shell_state.tab_bar
      tab2_id = Enum.find(tb.tabs, &(&1.id != tb.active_id)).id

      {new_state, _effects} = EditorState.switch_tab_pure(state, tab2_id)

      # Layout should be cleared after a tab switch
      assert new_state.layout == nil
    end

    test "tab switch restores the target tab's pending LSP refs" do
      {state, _buf1, buf2} = state_with_two_file_tabs()
      tb = state.shell_state.tab_bar
      current_id = tb.active_id
      target_id = Enum.find(tb.tabs, &(&1.id != tb.active_id)).id

      pending_current = %{make_ref() => :completion_resolve}
      pending_target = %{make_ref() => {:semantic_tokens, buf2}}

      state = put_in(state.workspace.lsp_pending, pending_current)
      tab2 = TabBar.get(tb, target_id)
      tab2_context = Context.put_fields(tab2.context, lsp_pending: pending_target)
      state = EditorState.set_tab_bar(state, TabBar.update_context(tb, target_id, tab2_context))

      {switched, _effects} = EditorState.switch_tab_pure(state, target_id)

      assert switched.workspace.lsp_pending == pending_target

      assert TabBar.get(switched.shell_state.tab_bar, current_id).context.lsp_pending ==
               pending_current

      {switched_back, _effects} = EditorState.switch_tab_pure(switched, current_id)

      assert switched_back.workspace.lsp_pending == pending_current

      assert TabBar.get(switched_back.shell_state.tab_bar, target_id).context.lsp_pending ==
               pending_target
    end

    test "tab switch restores explicit target highlight without snapshotting outgoing highlight" do
      {state, buf1, buf2} = state_with_two_file_tabs()
      tb = state.shell_state.tab_bar
      current_id = tb.active_id
      target_id = Enum.find(tb.tabs, &(&1.id != tb.active_id)).id

      hl_data = Highlight.new()

      current_highlight = %Highlighting{
        buffer_ids: %{buf1 => 1},
        reverse_buffer_ids: %{1 => buf1},
        next_buffer_id: 2,
        version: 5,
        highlights: %{buf1 => hl_data},
        last_active_at: %{buf1 => 100}
      }

      target_highlight = %Highlighting{
        buffer_ids: %{buf2 => 7},
        reverse_buffer_ids: %{7 => buf2},
        next_buffer_id: 8,
        version: 9,
        highlights: %{buf2 => hl_data},
        last_active_at: %{buf2 => 200}
      }

      state = put_in(state.workspace.highlight, current_highlight)
      target_tab = TabBar.get(tb, target_id)
      target_context = Context.put_fields(target_tab.context, highlight: target_highlight)
      state = EditorState.set_tab_bar(state, TabBar.update_context(tb, target_id, target_context))

      {switched, _effects} = EditorState.switch_tab_pure(state, target_id)

      assert switched.workspace.highlight == target_highlight

      assert TabBar.get(switched.shell_state.tab_bar, current_id).context.highlight == nil

      {switched_back, _effects} = EditorState.switch_tab_pure(switched, current_id)

      assert switched_back.workspace.highlight == target_highlight
      assert TabBar.get(switched_back.shell_state.tab_bar, target_id).context.highlight == nil
    end

    test "tab switch restores explicit target injection_ranges without snapshotting outgoing ranges" do
      {state, buf1, buf2} = state_with_two_file_tabs()
      tb = state.shell_state.tab_bar
      current_id = tb.active_id
      target_id = Enum.find(tb.tabs, &(&1.id != tb.active_id)).id

      current_ranges = %{buf1 => [:current_range]}
      target_ranges = %{buf2 => [:target_range]}

      state = put_in(state.workspace.injection_ranges, current_ranges)
      target_tab = TabBar.get(tb, target_id)
      target_context = Context.put_fields(target_tab.context, injection_ranges: target_ranges)
      state = EditorState.set_tab_bar(state, TabBar.update_context(tb, target_id, target_context))

      {switched, _effects} = EditorState.switch_tab_pure(state, target_id)

      assert switched.workspace.injection_ranges == target_ranges

      assert TabBar.get(switched.shell_state.tab_bar, current_id).context.injection_ranges == nil

      {switched_back, _effects} = EditorState.switch_tab_pure(switched, current_id)

      assert switched_back.workspace.injection_ranges == target_ranges

      assert TabBar.get(switched_back.shell_state.tab_bar, target_id).context.injection_ranges ==
               nil
    end
  end
end
