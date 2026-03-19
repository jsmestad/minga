defmodule Minga.Input.ScopedTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Agent.DiffReview
  alias Minga.Agent.UIState
  alias Minga.Agent.View.Preview
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.LayoutPreset
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.FileTree
  alias Minga.FileTree.BufferSync
  alias Minga.Input.AgentPanel
  alias Minga.Input.FileTreeHandler
  alias Minga.Input.Scoped
  alias Minga.Mode

  defp base_state(opts) do
    {:ok, buf} = BufferServer.start_link(content: "hello world")
    {:ok, prompt_buf} = BufferServer.start_link(content: "")

    agent = %AgentState{
      session: nil,
      status: :idle,
      error: nil,
      spinner_timer: nil,
      buffer: Keyword.get(opts, :agent_buffer, nil)
    }

    agentic = %UIState{
      visible: Keyword.get(opts, :panel_visible, false),
      input_focused: Keyword.get(opts, :input_focused, false),
      prompt_buffer: prompt_buf,
      active: Keyword.get(opts, :agentic_active, false),
      focus: Keyword.get(opts, :focus, :chat)
    }

    tab_bar =
      if Keyword.get(opts, :agentic_active, false) do
        # Agent mode: tab bar with an agent tab active
        TabBar.new(Tab.new_agent(1, "Agent"))
      else
        TabBar.new(Tab.new_file(1, "[no file]"))
      end

    mode = if(Keyword.get(opts, :input_focused, false), do: :insert, else: :normal)

    %EditorState{
      port_manager: self(),
      viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
      vim: %VimState{mode: mode, mode_state: Mode.initial_state()},
      buffers: %Buffers{active: buf, list: [buf]},
      focus_stack: [],
      keymap_scope: Keyword.get(opts, :keymap_scope, :editor),
      agent: agent,
      agent_ui: agentic,
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

    test "q toggles the agent split", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, ?q, 0)
      # q calls toggle_agent_split which closes the agent pane
      refute is_nil(new_state)
    end

    test "i focuses the input", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, ?i, 0)
      assert AgentAccess.input_focused?(new_state) == true
    end

    test "j delegates to mode FSM with agent buffer", %{state: state, agent_buf: agent_buf} do
      # j should delegate to mode FSM, moving cursor in agent buffer
      {:handled, _new_state} = walk_surface_handlers(state, ?j, 0)
      {line, _col} = BufferServer.cursor(agent_buf)
      assert line >= 1
    end

    test "ESC toggles the agent split", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 27, 0)
      # ESC calls toggle_agent_split which closes the agent pane
      refute is_nil(new_state)
    end

    test "passthrough when panel not visible" do
      state = base_state(keymap_scope: :editor, panel_visible: false)
      assert {:passthrough, _} = AgentPanel.handle_key(state, ?j, 0)
    end

    test "passthrough when no agent buffer" do
      state = base_state(keymap_scope: :editor, panel_visible: true, agent_buffer: nil)
      assert {:passthrough, _} = AgentPanel.handle_key(state, ?j, 0)
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
      {:handled, new_state} = walk_surface_handlers(state, ?x, 0)
      assert UIState.input_text(AgentAccess.panel(new_state)) =~ "x"
    end

    test "ESC switches to input normal mode (editor scope side panel)", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 27, 0)
      assert AgentAccess.input_focused?(new_state)
      assert new_state.vim.mode == :normal
    end

    test "Backspace on empty input is safe", %{state: state} do
      {:handled, _new_state} = walk_surface_handlers(state, 127, 0)
    end

    test "Ctrl+C with empty input is handled", %{state: state} do
      {:handled, _new_state} = walk_surface_handlers(state, ?c, 0x02)
    end

    test "Ctrl+D scrolls chat down", %{state: state} do
      {:handled, _new_state} = walk_surface_handlers(state, ?d, 0x02)
    end

    test "Enter on empty prompt is no-op", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 13, 0)
      assert AgentAccess.input_focused?(new_state) == true
    end

    test "Shift+Enter inserts newline", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 13, 0x01)
      assert length(UIState.input_lines(AgentAccess.panel(new_state))) > 1
    end

    test "Alt+Enter inserts newline", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 13, 0x04)
      assert length(UIState.input_lines(AgentAccess.panel(new_state))) > 1
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Agent scope (full-screen agentic view)
  # ══════════════════════════════════════════════════════════════════════════

  describe "agent scope — normal mode" do
    setup do
      {:ok, state: base_state(keymap_scope: :agent, agentic_active: true)}
    end

    test "j passthrough (handled by AgentNav → Mode FSM)", %{state: state} do
      assert {:passthrough, _} = Scoped.handle_key(state, ?j, 0)
      # Full chain handling (through AgentNav)
      assert {:handled, _} = walk_surface_handlers(state, ?j, 0)
    end

    test "k passthrough (handled by AgentNav → Mode FSM)", %{state: state} do
      assert {:passthrough, _} = Scoped.handle_key(state, ?k, 0)
      # Full chain handling
      assert {:handled, _} = walk_surface_handlers(state, ?k, 0)
    end

    test "G passthrough (handled by AgentNav → Mode FSM)", %{state: state} do
      assert {:passthrough, _} = Scoped.handle_key(state, ?G, 0)
      # Full chain handling
      assert {:handled, _} = walk_surface_handlers(state, ?G, 0)
    end

    test "q closes agentic view", %{state: state} do
      # Set up a proper window tree with agent split pane
      {:ok, agent_buf} = BufferServer.start_link(content: "")

      win = Window.new(1, state.buffers.active, 24, 80)
      windows = %{state.windows | tree: {:leaf, win.id}, map: %{win.id => win}, active: win.id}
      state = %{state | windows: windows}

      state = LayoutPreset.apply(state, :agent_right, agent_buf)
      assert LayoutPreset.has_agent_chat?(state)

      {:handled, new_state} = Scoped.handle_key(state, ?q, 0)
      refute LayoutPreset.has_agent_chat?(new_state)
      assert new_state.keymap_scope == :editor
    end

    test "? toggles help", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ??, 0)
      assert AgentAccess.agent_ui(new_state).help_visible
    end

    test "Tab switches focus", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, 9, 0)
      assert AgentAccess.agent_ui(new_state).focus == :file_viewer
    end

    test "i focuses input", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?i, 0)
      assert AgentAccess.input_focused?(new_state)
    end

    test "SPC passes through for leader key", %{state: state} do
      assert {:passthrough, _} = Scoped.handle_key(state, ?\s, 0)
    end

    test "leader sequence in progress passes through", %{state: state} do
      # Simulate a leader sequence in progress
      leader_state = %{
        state
        | vim: %{state.vim | mode_state: %{state.vim.mode_state | leader_node: %{}}}
      }

      assert {:passthrough, _} = Scoped.handle_key(leader_state, ?f, 0)
    end

    test "g starts a prefix sequence", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?g, 0)
      assert AgentAccess.agent_ui(new_state).pending_prefix != nil
    end

    test "z starts a prefix sequence", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?z, 0)
      assert AgentAccess.agent_ui(new_state).pending_prefix != nil
    end

    test "] starts a prefix sequence", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?], 0)
      assert AgentAccess.agent_ui(new_state).pending_prefix != nil
    end

    test "[ starts a prefix sequence", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?[, 0)
      assert AgentAccess.agent_ui(new_state).pending_prefix != nil
    end

    test "gg scrolls to top via prefix", %{state: state} do
      {:handled, g_state} = Scoped.handle_key(state, ?g, 0)
      assert {:handled, _} = Scoped.handle_key(g_state, ?g, 0)
    end

    test "/ passthrough for standard vim search", %{state: state} do
      # After #631, `/` is no longer bound in the agent scope trie.
      # It passes through to AgentNav → Mode FSM for standard buffer search.
      assert {:passthrough, _} = Scoped.handle_key(state, ?/, 0)
    end

    test "panel resize keys work", %{state: state} do
      {:handled, grow} = Scoped.handle_key(state, ?}, 0)

      assert AgentAccess.agent_ui(grow).chat_width_pct >
               AgentAccess.agent_ui(state).chat_width_pct

      {:handled, shrink} = Scoped.handle_key(state, ?{, 0)

      assert AgentAccess.agent_ui(shrink).chat_width_pct <
               AgentAccess.agent_ui(state).chat_width_pct
    end

    test "= resets panel split", %{state: state} do
      {:handled, resized} = Scoped.handle_key(state, ?}, 0)
      {:handled, reset} = Scoped.handle_key(resized, ?=, 0)

      assert AgentAccess.agent_ui(reset).chat_width_pct ==
               AgentAccess.agent_ui(state).chat_width_pct
    end

    test "Ctrl+D passthrough (handled by AgentNav → Mode FSM)", %{state: state} do
      assert {:passthrough, _} = Scoped.handle_key(state, ?d, 0x02)
      # Full chain handling
      assert {:handled, _} = walk_surface_handlers(state, ?d, 0x02)
    end

    test "Ctrl+U passthrough (handled by AgentNav → Mode FSM)", %{state: state} do
      assert {:passthrough, _} = Scoped.handle_key(state, ?u, 0x02)
      # Full chain handling
      assert {:handled, _} = walk_surface_handlers(state, ?u, 0x02)
    end

    test "ESC dismisses help when visible", %{state: state} do
      state =
        AgentAccess.update_agent_ui(state, fn agentic -> %{agentic | help_visible: true} end)

      {:handled, new_state} = Scoped.handle_key(state, 27, 0)
      refute AgentAccess.agent_ui(new_state).help_visible
    end

    test "unbound key passthrough to Mode FSM", %{state: state} do
      # tilde is not bound in agent scope, passes through to AgentNav → Mode FSM
      assert {:passthrough, _} = Scoped.handle_key(state, ?~, 0)
      # Full chain handling (AgentNav routes to Mode FSM)
      assert {:handled, _} = walk_surface_handlers(state, ?~, 0)
    end
  end

  describe "agent scope — insert mode" do
    setup do
      {:ok,
       state:
         base_state(
           keymap_scope: :agent,
           agentic_active: true,
           input_focused: true,
           panel_visible: true
         )}
    end

    test "ESC switches to input normal mode", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, 27, 0)
      assert AgentAccess.input_focused?(new_state)
      assert new_state.vim.mode == :normal
    end

    test "printable char self-inserts", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?x, 0)
      assert UIState.input_text(AgentAccess.panel(new_state)) =~ "x"
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
      assert UIState.input_text(AgentAccess.panel(new_state)) =~ " "
    end
  end

  describe "agent scope — search (standard vim)" do
    test "/ passes through to standard vim search" do
      # After #631, search is handled by the standard Mode FSM.
      # `/` is no longer bound in the agent scope trie.
      state = base_state(keymap_scope: :agent, agentic_active: true)
      assert {:passthrough, _} = Scoped.handle_key(state, ?/, 0)

      # Full handler chain handles it (AgentNav → Mode FSM enters search mode)
      {:handled, new_state} = walk_surface_handlers(state, ?/, 0)
      assert new_state.vim.mode == :search
    end
  end

  describe "agent scope — toast dismiss" do
    test "any key dismisses toast then processes normally" do
      state = base_state(keymap_scope: :agent, agentic_active: true)

      state =
        AgentAccess.update_agent_ui(state, fn agentic ->
          UIState.push_toast(agentic, "test", :info)
        end)

      assert UIState.toast_visible?(AgentAccess.agent_ui(state))

      # Toast dismissal is still handled by Scoped, but j itself returns passthrough
      {:passthrough, new_state} = Scoped.handle_key(state, ?j, 0)
      # Toast should be dismissed
      refute UIState.toast_visible?(AgentAccess.agent_ui(new_state))
      # Full chain still handles the key (through AgentNav)
      {:handled, _} = walk_surface_handlers(state, ?j, 0)
    end
  end

  describe "agent scope — file viewer focus" do
    test "j passthrough, handled by AgentNav in file_viewer focus" do
      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :file_viewer)
      assert {:passthrough, _} = Scoped.handle_key(state, ?j, 0)
      # Full chain handling through AgentNav
      assert {:handled, _} = walk_surface_handlers(state, ?j, 0)
    end

    test "Tab switches back to chat from viewer" do
      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :file_viewer)
      {:handled, new_state} = Scoped.handle_key(state, 9, 0)
      assert AgentAccess.agent_ui(new_state).focus == :chat
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # File tree scope
  # ══════════════════════════════════════════════════════════════════════════

  describe "file tree scope" do
    test "q closes tree", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      {:handled, new_state} = walk_surface_handlers(state, ?q, 0)
      assert new_state.keymap_scope == :editor
      assert new_state.file_tree.tree == nil
    end

    test "unbound key delegates to mode FSM for vim nav", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      # j is not bound in file_tree scope (handled by mode FSM delegation)
      {:handled, new_state} = walk_surface_handlers(state, ?j, 0)
      assert new_state.file_tree.tree.cursor == 1
    end

    test "leader sequence in progress delegates to mode FSM", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      # Use a real Bindings.Node, not a plain map, because the mode FSM
      # calls Bindings.lookup on leader_node.
      leader_node = %Minga.Keymap.Bindings.Node{children: %{}, command: nil, description: nil}

      leader_state = %{
        state
        | vim: %{state.vim | mode_state: %{state.vim.mode_state | leader_node: leader_node}}
      }

      {:handled, _new_state} = walk_surface_handlers(leader_state, ?f, 0)
    end

    test "h collapses directory (scope binding)", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))
      state = make_tree_state(tmp_dir, 0)

      # h is bound in file_tree scope to :tree_collapse
      {:handled, _new_state} = walk_surface_handlers(state, ?h, 0)
    end

    test "l expands directory (scope binding)", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))
      state = make_tree_state(tmp_dir, 0)

      {:handled, _new_state} = walk_surface_handlers(state, ?l, 0)
    end

    test "r refreshes tree (scope binding)", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir, 3)
      {:handled, _new_state} = walk_surface_handlers(state, ?r, 0)
    end

    test "H toggles hidden files (scope binding)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".hidden"), "")
      state = make_tree_state(tmp_dir, 0)

      entries_before = length(FileTree.visible_entries(state.file_tree.tree))
      {:handled, new_state} = walk_surface_handlers(state, ?H, 0)
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
      assert {:passthrough, _} = FileTreeHandler.handle_key(state, ?q, 0)
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
      state =
        base_state(
          keymap_scope: :agent,
          agentic_active: true,
          input_focused: true,
          panel_visible: true
        )

      {:handled, new_state} = walk_surface_handlers(state, ?\s, 0)
      assert UIState.input_text(AgentAccess.panel(new_state)) =~ " "
    end

    test "leader node pending passes through in agent scope" do
      state = base_state(keymap_scope: :agent, agentic_active: true)

      state = %{
        state
        | vim: %{state.vim | mode_state: %{state.vim.mode_state | leader_node: %{}}}
      }

      assert {:passthrough, _} = Scoped.handle_key(state, ?a, 0)
    end

    test "SPC passes through in editor scope (no panel)" do
      state = base_state(keymap_scope: :editor)
      assert {:passthrough, _} = Scoped.handle_key(state, ?\s, 0)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Agent sub-states (characterization tests for Phase 2)
  # ══════════════════════════════════════════════════════════════════════════

  describe "agent scope — tool approval sub-state" do
    setup do
      state = base_state(keymap_scope: :agent, agentic_active: true)

      approval = %{
        tool_call_id: "tc_123",
        name: "write_file",
        args: %{"path" => "/tmp/test.txt"}
      }

      state =
        AgentAccess.update_agent(state, fn agent -> %{agent | pending_approval: approval} end)

      {:ok, state: state}
    end

    test "y is handled (dispatches approve command)", %{state: state} do
      {:handled, _new_state} = walk_surface_handlers(state, ?y, 0)
      # Without a live session, approve_tool is a no-op (guard fails),
      # but the key IS handled (not passed through)
    end

    test "n is handled (dispatches deny command)", %{state: state} do
      {:handled, _new_state} = walk_surface_handlers(state, ?n, 0)
    end

    test "Y is handled (approve all)", %{state: state} do
      {:handled, _new_state} = walk_surface_handlers(state, ?Y, 0)
    end

    test "unrelated key is swallowed during approval", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, ?x, 0)
      # The key is swallowed, pending_approval stays
      assert AgentAccess.agent(new_state).pending_approval != nil
    end

    test "only triggers when input is not focused", %{state: state} do
      # If input is focused in insert mode, approval keys should not be intercepted
      state =
        AgentAccess.update_agent_ui(state, fn ui ->
          %{ui | input_focused: true, visible: true}
        end)

      state = %{state | vim: %{state.vim | mode: :insert}}
      {:handled, new_state} = walk_surface_handlers(state, ?y, 0)
      # Should have typed 'y' into input, not approved
      assert UIState.input_text(AgentAccess.panel(new_state)) =~ "y"
    end
  end

  describe "agent scope — diff review sub-state" do
    setup do
      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :file_viewer)

      # Set up a diff review preview
      review = DiffReview.new("test.ex", "old line\n", "new line\n")

      state =
        AgentAccess.update_agent_ui(state, fn agentic ->
          %{agentic | preview: %Preview{content: {:diff, review}}}
        end)

      {:ok, state: state}
    end

    test "y accepts hunk", %{state: state} do
      {:handled, _new_state} = walk_surface_handlers(state, ?y, 0)
    end

    test "x rejects hunk", %{state: state} do
      {:handled, _new_state} = walk_surface_handlers(state, ?x, 0)
    end

    test "Y accepts all hunks", %{state: state} do
      {:handled, _new_state} = walk_surface_handlers(state, ?Y, 0)
    end

    test "X rejects all hunks", %{state: state} do
      {:handled, _new_state} = walk_surface_handlers(state, ?X, 0)
    end

    test "navigation keys still work during diff review", %{state: state} do
      {:handled, _new_state} = walk_surface_handlers(state, ?j, 0)
    end

    test "diff review only triggers in file_viewer focus" do
      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :chat)

      review = DiffReview.new("test.ex", "old line\n", "new line\n")

      state =
        AgentAccess.update_agent_ui(state, fn agentic ->
          %{agentic | preview: %Preview{content: {:diff, review}}}
        end)

      # In :chat focus, y should resolve through the scope trie, not diff review
      {:handled, _new_state} = walk_surface_handlers(state, ?y, 0)
    end
  end

  describe "agent scope — mention completion sub-state" do
    setup do
      state = base_state(keymap_scope: :agent, agentic_active: true, input_focused: true)

      completion = %{
        prefix: "@",
        all_files: ["lib/test.ex", "lib/foo.ex"],
        candidates: ["lib/test.ex", "lib/foo.ex"],
        selected: 0,
        anchor_line: 0,
        anchor_col: 0
      }

      state =
        AgentAccess.update_agent_ui(state, fn ui ->
          put_in(ui.mention_completion, completion)
        end)

      {:ok, state: state}
    end

    test "Tab moves to next candidate", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 9, 0)
      assert AgentAccess.panel(new_state).mention_completion.selected == 1
    end

    test "Enter accepts the selected candidate", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 13, 0)
      assert AgentAccess.panel(new_state).mention_completion == nil
    end

    test "Escape cancels mention completion", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 27, 0)
      assert AgentAccess.panel(new_state).mention_completion == nil
    end

    test "printable char narrows candidates", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, ?t, 0)
      comp = AgentAccess.panel(new_state).mention_completion

      if comp != nil do
        assert length(comp.candidates) <=
                 length(AgentAccess.panel(state).mention_completion.candidates)
      end
    end

    test "mention only intercepts in insert mode", %{state: state} do
      state =
        AgentAccess.update_agent_ui(state, fn ui -> put_in(ui.input_focused, false) end)

      {:handled, _new_state} = walk_surface_handlers(state, ?j, 0)
    end
  end

  describe "editor scope — panel mention completion" do
    setup do
      {:ok, agent_buf} = BufferServer.start_link(content: "chat")

      state =
        base_state(
          keymap_scope: :editor,
          panel_visible: true,
          input_focused: true,
          agent_buffer: agent_buf
        )

      completion = %{
        prefix: "@",
        all_files: ["lib/test.ex"],
        candidates: ["lib/test.ex"],
        selected: 0,
        anchor_line: 0,
        anchor_col: 0
      }

      state =
        AgentAccess.update_agent_ui(state, fn ui ->
          put_in(ui.mention_completion, completion)
        end)

      {:ok, state: state}
    end

    test "mention completion intercepts keys in editor panel too", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 27, 0)
      assert AgentAccess.panel(new_state).mention_completion == nil
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Mouse handling
  # ══════════════════════════════════════════════════════════════════════════

  describe "handle_mouse — agentic view" do
    test "routes to AgentViewMouse when agentic is active" do
      state = base_state(keymap_scope: :agent, agentic_active: true)
      result = walk_surface_mouse(state, 5, 5, :left, 0, :press, 1)
      assert elem(result, 0) in [:handled, :passthrough]
    end
  end

  describe "handle_mouse — file tree" do
    test "handles click when file tree exists", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      result = walk_surface_mouse(state, 5, 5, :left, 0, :press, 1)
      assert elem(result, 0) in [:handled, :passthrough]
    end
  end

  describe "handle_mouse — other scopes" do
    test "passes through for editor scope" do
      state = base_state(keymap_scope: :editor)
      result = FileTreeHandler.handle_mouse(state, 5, 5, :left, 0, :press, 1)
      assert {:passthrough, _} = result
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Walks all surface handlers (including the new sub-state handlers)
  # in order, returning the result from the first handler that handles
  # the key.
  defp walk_surface_handlers(state, cp, mods) do
    Enum.reduce_while(Minga.Input.surface_handlers(), {:passthrough, state}, fn handler,
                                                                                {_, acc} ->
      case handler.handle_key(acc, cp, mods) do
        {:handled, new_state} -> {:halt, {:handled, new_state}}
        {:passthrough, new_state} -> {:cont, {:passthrough, new_state}}
      end
    end)
  end

  defp walk_surface_mouse(state, row, col, button, mods, event_type, cc) do
    handlers =
      Minga.Input.surface_handlers()
      |> Enum.filter(&function_exported?(&1, :handle_mouse, 7))

    Enum.reduce_while(handlers, {:passthrough, state}, fn handler, {_, acc} ->
      case handler.handle_mouse(acc, row, col, button, mods, event_type, cc) do
        {:handled, new_state} -> {:halt, {:handled, new_state}}
        {:passthrough, new_state} -> {:cont, {:passthrough, new_state}}
      end
    end)
  end

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
