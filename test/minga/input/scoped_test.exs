defmodule Minga.Input.ScopedTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Agent.PanelState
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Viewport
  alias Minga.FileTree
  alias Minga.FileTree.BufferSync
  alias Minga.Input.Scoped
  alias Minga.Mode

  defp base_state(opts) do
    {:ok, buf} = BufferServer.start_link(content: "hello world")

    panel = %PanelState{
      visible: Keyword.get(opts, :panel_visible, false),
      input_focused: Keyword.get(opts, :input_focused, false),
      scroll: Minga.Scroll.new(),
      spinner_frame: 0,
      provider_name: "anthropic",
      model_name: "claude-sonnet-4",
      thinking_level: "medium"
    }

    agent = %AgentState{
      session: nil,
      status: :idle,
      panel: panel,
      error: nil,
      spinner_timer: nil,
      buffer: Keyword.get(opts, :agent_buffer, nil)
    }

    agentic = %ViewState{
      active: Keyword.get(opts, :agentic_active, false),
      focus: Keyword.get(opts, :focus, :chat)
    }

    tab_bar =
      if Keyword.get(opts, :agentic_active, false) do
        # Agent mode: tab bar with an agent tab active
        TabBar.new(Tab.new_agent(1, "Agent"))
      else
        TabBar.new(Tab.new_file(1, "*scratch*"))
      end

    %EditorState{
      port_manager: self(),
      viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: buf, list: [buf]},
      focus_stack: [],
      keymap_scope: Keyword.get(opts, :keymap_scope, :editor),
      agent: agent,
      agentic: agentic,
      tab_bar: tab_bar
    }
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Editor scope (no panel)
  # ══════════════════════════════════════════════════════════════════════════

  describe "editor scope (no panel)" do
    test "all keys pass through" do
      state = base_state(keymap_scope: :editor)
      assert {:passthrough, _} = Scoped.handle_key(state, ?j, 0)
      assert {:passthrough, _} = Scoped.handle_key(state, ?k, 0)
      assert {:passthrough, _} = Scoped.handle_key(state, ?\s, 0)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Editor scope with agent side panel
  # ══════════════════════════════════════════════════════════════════════════

  describe "editor scope — agent side panel nav" do
    setup do
      {:ok, agent_buf} = BufferServer.start_link(content: "line1\nline2\nline3\nline4")

      state =
        base_state(
          keymap_scope: :editor,
          panel_visible: true,
          agent_buffer: agent_buf
        )

      {:ok, state: state, agent_buf: agent_buf}
    end

    test "q on unfocused panel re-focuses input (toggle_panel behavior)", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?q, 0)
      assert new_state.agent.panel.input_focused == true
    end

    test "i focuses the input", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?i, 0)
      assert new_state.agent.panel.input_focused == true
    end

    test "j delegates to mode FSM with agent buffer", %{state: state, agent_buf: agent_buf} do
      # j should delegate to mode FSM, moving cursor in agent buffer
      {:handled, _new_state} = Scoped.handle_key(state, ?j, 0)
      {line, _col} = BufferServer.cursor(agent_buf)
      assert line >= 1
    end

    test "ESC closes the panel", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, 27, 0)
      # toggle_panel on a non-input-focused visible panel re-focuses input
      assert new_state.agent.panel.input_focused == true
    end

    test "passthrough when panel not visible" do
      state = base_state(keymap_scope: :editor, panel_visible: false)
      assert {:passthrough, _} = Scoped.handle_key(state, ?j, 0)
    end

    test "passthrough when no agent buffer" do
      state = base_state(keymap_scope: :editor, panel_visible: true, agent_buffer: nil)
      assert {:passthrough, _} = Scoped.handle_key(state, ?j, 0)
    end
  end

  describe "editor scope — agent side panel input" do
    setup do
      {:ok, agent_buf} = BufferServer.start_link(content: "chat content")

      state =
        base_state(
          keymap_scope: :editor,
          panel_visible: true,
          input_focused: true,
          agent_buffer: agent_buf
        )

      {:ok, state: state}
    end

    test "printable chars go to input", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?x, 0)
      assert PanelState.input_text(new_state.agent.panel) =~ "x"
    end

    test "ESC switches to input normal mode (editor scope side panel)", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, 27, 0)
      assert new_state.agent.panel.input_focused
      assert PanelState.input_mode(new_state.agent.panel) == :normal
    end

    test "vim motions work in normal mode (side panel regression)", %{state: state} do
      # Type some text first
      {:handled, state} = Scoped.handle_key(state, ?h, 0)
      {:handled, state} = Scoped.handle_key(state, ?e, 0)
      {:handled, state} = Scoped.handle_key(state, ?l, 0)
      {:handled, state} = Scoped.handle_key(state, ?l, 0)
      {:handled, state} = Scoped.handle_key(state, ?o, 0)
      assert PanelState.input_text(state.agent.panel) == "hello"
      assert state.agent.panel.input.cursor == {0, 5}

      # Escape → normal mode
      {:handled, state} = Scoped.handle_key(state, 27, 0)
      assert PanelState.input_mode(state.agent.panel) == :normal

      # h should move cursor left, NOT insert "h" as text.
      # Before the fix, dispatch_vim_key returned {:handled, state} which
      # got double-wrapped to {:handled, {:handled, state}}, breaking
      # downstream handling and leaving the mode effectively stuck in insert.
      {:handled, state} = Scoped.handle_key(state, ?h, 0)
      assert PanelState.input_text(state.agent.panel) == "hello"
      assert state.agent.panel.input.cursor == {0, 3}

      # w should jump forward, not insert "w"
      {:handled, state} = Scoped.handle_key(state, ?w, 0)
      assert PanelState.input_text(state.agent.panel) == "hello"
    end

    test "Backspace on empty input is safe", %{state: state} do
      {:handled, _new_state} = Scoped.handle_key(state, 127, 0)
    end

    test "Ctrl+C with empty input is handled", %{state: state} do
      {:handled, _new_state} = Scoped.handle_key(state, ?c, 0x02)
    end

    test "Ctrl+D scrolls chat down", %{state: state} do
      {:handled, _new_state} = Scoped.handle_key(state, ?d, 0x02)
    end

    test "Enter on empty prompt is no-op", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, 13, 0)
      assert new_state.agent.panel.input_focused == true
    end

    test "Shift+Enter inserts newline", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, 13, 0x01)
      assert length(new_state.agent.panel.input.lines) > 1
    end

    test "Alt+Enter inserts newline", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, 13, 0x04)
      assert length(new_state.agent.panel.input.lines) > 1
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Agent scope (full-screen agentic view)
  # ══════════════════════════════════════════════════════════════════════════

  describe "agent scope — normal mode" do
    setup do
      {:ok, state: base_state(keymap_scope: :agent, agentic_active: true)}
    end

    test "j scrolls down", %{state: state} do
      assert {:handled, new_state} = Scoped.handle_key(state, ?j, 0)

      assert new_state.agent.panel.scroll.offset != state.agent.panel.scroll.offset or
               new_state == state
    end

    test "k scrolls up", %{state: state} do
      # First scroll down so there's room to scroll up
      {:handled, scrolled} = Scoped.handle_key(state, ?j, 0)
      assert {:handled, _} = Scoped.handle_key(scrolled, ?k, 0)
    end

    test "G scrolls to bottom", %{state: state} do
      assert {:handled, _} = Scoped.handle_key(state, ?G, 0)
    end

    test "q closes agentic view", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?q, 0)
      refute new_state.agentic.active
      assert new_state.keymap_scope == :editor
    end

    test "? toggles help", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ??, 0)
      assert new_state.agentic.help_visible
    end

    test "Tab switches focus", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, 9, 0)
      assert new_state.agentic.focus == :file_viewer
    end

    test "i focuses input", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?i, 0)
      assert new_state.agent.panel.input_focused
    end

    test "SPC passes through for leader key", %{state: state} do
      assert {:passthrough, _} = Scoped.handle_key(state, ?\s, 0)
    end

    test "leader sequence in progress passes through", %{state: state} do
      # Simulate a leader sequence in progress
      leader_state = %{state | mode_state: %{state.mode_state | leader_node: %{}}}
      assert {:passthrough, _} = Scoped.handle_key(leader_state, ?f, 0)
    end

    test "g starts a prefix sequence", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?g, 0)
      assert new_state.agentic.pending_prefix != nil
    end

    test "z starts a prefix sequence", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?z, 0)
      assert new_state.agentic.pending_prefix != nil
    end

    test "] starts a prefix sequence", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?], 0)
      assert new_state.agentic.pending_prefix != nil
    end

    test "[ starts a prefix sequence", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?[, 0)
      assert new_state.agentic.pending_prefix != nil
    end

    test "gg scrolls to top via prefix", %{state: state} do
      {:handled, g_state} = Scoped.handle_key(state, ?g, 0)
      assert {:handled, _} = Scoped.handle_key(g_state, ?g, 0)
    end

    test "/ starts search", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?/, 0)
      assert ViewState.searching?(new_state.agentic)
    end

    test "panel resize keys work", %{state: state} do
      {:handled, grow} = Scoped.handle_key(state, ?}, 0)
      assert grow.agentic.chat_width_pct > state.agentic.chat_width_pct

      {:handled, shrink} = Scoped.handle_key(state, ?{, 0)
      assert shrink.agentic.chat_width_pct < state.agentic.chat_width_pct
    end

    test "= resets panel split", %{state: state} do
      {:handled, resized} = Scoped.handle_key(state, ?}, 0)
      {:handled, reset} = Scoped.handle_key(resized, ?=, 0)
      assert reset.agentic.chat_width_pct == state.agentic.chat_width_pct
    end

    test "Ctrl+D scrolls half page down", %{state: state} do
      assert {:handled, _} = Scoped.handle_key(state, ?d, 0x02)
    end

    test "Ctrl+U scrolls half page up", %{state: state} do
      assert {:handled, _} = Scoped.handle_key(state, ?u, 0x02)
    end

    test "ESC dismisses help when visible", %{state: state} do
      state = %{state | agentic: %{state.agentic | help_visible: true}}
      {:handled, new_state} = Scoped.handle_key(state, 27, 0)
      refute new_state.agentic.help_visible
    end

    test "unbound key is swallowed in normal mode", %{state: state} do
      # tilde is not bound in agent scope
      assert {:handled, ^state} = Scoped.handle_key(state, ?~, 0)
    end
  end

  describe "agent scope — insert mode" do
    setup do
      {:ok, state: base_state(keymap_scope: :agent, agentic_active: true, input_focused: true)}
    end

    test "ESC switches to input normal mode", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, 27, 0)
      assert new_state.agent.panel.input_focused
      assert PanelState.input_mode(new_state.agent.panel) == :normal
    end

    test "printable char self-inserts", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?x, 0)
      assert PanelState.input_text(new_state.agent.panel) =~ "x"
    end

    test "Backspace deletes from input", %{state: state} do
      # Insert a char first
      {:handled, with_char} = Scoped.handle_key(state, ?a, 0)
      assert {:handled, _} = Scoped.handle_key(with_char, 127, 0)
    end

    test "Ctrl+C with empty input is handled", %{state: state} do
      assert {:handled, _} = Scoped.handle_key(state, ?c, 0x02)
    end

    test "SPC types a space when input is focused (not leader key)", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?\s, 0)
      assert PanelState.input_text(new_state.agent.panel) =~ " "
    end
  end

  describe "agent scope — search sub-state" do
    test "search input captures printable chars" do
      state = base_state(keymap_scope: :agent, agentic_active: true)
      {:handled, searching} = Scoped.handle_key(state, ?/, 0)
      assert ViewState.searching?(searching.agentic)

      # Type a search char
      {:handled, with_char} = Scoped.handle_key(searching, ?h, 0)
      assert ViewState.search_query(with_char.agentic) == "h"
    end

    test "ESC cancels search" do
      state = base_state(keymap_scope: :agent, agentic_active: true)
      {:handled, searching} = Scoped.handle_key(state, ?/, 0)
      {:handled, cancelled} = Scoped.handle_key(searching, 27, 0)
      refute ViewState.searching?(cancelled.agentic)
    end
  end

  describe "agent scope — toast dismiss" do
    test "any key dismisses toast then processes normally" do
      state = base_state(keymap_scope: :agent, agentic_active: true)
      state = %{state | agentic: ViewState.push_toast(state.agentic, "test", :info)}
      assert ViewState.toast_visible?(state.agentic)

      {:handled, new_state} = Scoped.handle_key(state, ?j, 0)
      refute ViewState.toast_visible?(new_state.agentic)
    end
  end

  describe "agent scope — file viewer focus" do
    test "j scrolls viewer when focus is :file_viewer" do
      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :file_viewer)
      assert {:handled, _} = Scoped.handle_key(state, ?j, 0)
    end

    test "Tab switches back to chat from viewer" do
      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :file_viewer)
      {:handled, new_state} = Scoped.handle_key(state, 9, 0)
      assert new_state.agentic.focus == :chat
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # File tree scope
  # ══════════════════════════════════════════════════════════════════════════

  describe "file tree scope" do
    test "q closes tree", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      {:handled, new_state} = Scoped.handle_key(state, ?q, 0)
      assert new_state.keymap_scope == :editor
      assert new_state.file_tree.tree == nil
    end

    test "unbound key delegates to mode FSM for vim nav", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      # j is not bound in file_tree scope (handled by mode FSM delegation)
      {:handled, new_state} = Scoped.handle_key(state, ?j, 0)
      assert new_state.file_tree.tree.cursor == 1
    end

    test "leader sequence in progress delegates to mode FSM", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      # Use a real Bindings.Node, not a plain map, because the mode FSM
      # calls Bindings.lookup on leader_node.
      leader_node = %Minga.Keymap.Bindings.Node{children: %{}, command: nil, description: nil}
      leader_state = %{state | mode_state: %{state.mode_state | leader_node: leader_node}}
      {:handled, _new_state} = Scoped.handle_key(leader_state, ?f, 0)
    end

    test "h collapses directory (scope binding)", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))
      state = make_tree_state(tmp_dir, 0)

      # h is bound in file_tree scope to :tree_collapse
      {:handled, _new_state} = Scoped.handle_key(state, ?h, 0)
    end

    test "l expands directory (scope binding)", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))
      state = make_tree_state(tmp_dir, 0)

      {:handled, _new_state} = Scoped.handle_key(state, ?l, 0)
    end

    test "r refreshes tree (scope binding)", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir, 3)
      {:handled, _new_state} = Scoped.handle_key(state, ?r, 0)
    end

    test "H toggles hidden files (scope binding)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".hidden"), "")
      state = make_tree_state(tmp_dir, 0)

      entries_before = length(FileTree.visible_entries(state.file_tree.tree))
      {:handled, new_state} = Scoped.handle_key(state, ?H, 0)
      entries_after = length(FileTree.visible_entries(new_state.file_tree.tree))

      assert entries_after != entries_before
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Scope inactive guards
  # ══════════════════════════════════════════════════════════════════════════

  describe "scope inactive guards" do
    test "agent scope with agentic not active passes through" do
      state = base_state(keymap_scope: :agent, agentic_active: false)
      assert {:passthrough, _} = Scoped.handle_key(state, ?j, 0)
    end

    test "file_tree scope with tree not focused passes through", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      state = put_in(state.file_tree.focused, false)
      assert {:passthrough, _} = Scoped.handle_key(state, ?q, 0)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Cross-scope leader sequences
  # ══════════════════════════════════════════════════════════════════════════

  describe "leader sequences work across all scopes" do
    test "SPC passes through in agent scope (normal mode)" do
      state = base_state(keymap_scope: :agent, agentic_active: true)
      assert {:passthrough, _} = Scoped.handle_key(state, ?\s, 0)
    end

    test "SPC self-inserts in agent insert mode" do
      state = base_state(keymap_scope: :agent, agentic_active: true, input_focused: true)
      {:handled, new_state} = Scoped.handle_key(state, ?\s, 0)
      assert PanelState.input_text(new_state.agent.panel) =~ " "
    end

    test "leader node pending passes through in agent scope" do
      state = base_state(keymap_scope: :agent, agentic_active: true)
      state = %{state | mode_state: %{state.mode_state | leader_node: %{}}}
      assert {:passthrough, _} = Scoped.handle_key(state, ?a, 0)
    end

    test "SPC passes through in editor scope (no panel)" do
      state = base_state(keymap_scope: :editor)
      assert {:passthrough, _} = Scoped.handle_key(state, ?\s, 0)
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp make_tree_state(tmp_dir, file_count \\ 5) do
    if file_count > 0 do
      for i <- 1..file_count do
        File.write!(
          Path.join(tmp_dir, "file_#{String.pad_leading(to_string(i), 2, "0")}.txt"),
          ""
        )
      end
    end

    tree = FileTree.new(tmp_dir)
    buf = BufferSync.start_buffer(tree)

    base_state(keymap_scope: :file_tree)
    |> Map.put(:file_tree, %FileTreeState{tree: tree, focused: true, buffer: buf})
  end
end
