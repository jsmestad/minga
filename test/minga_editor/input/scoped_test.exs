defmodule MingaEditor.Input.ScopedTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias Minga.Buffer.Process, as: BufferProcess

  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.State, as: EditorState
  alias MingaAgent.RuntimeState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Input.AgentPanel
  alias MingaEditor.Input.FileTreeHandler
  alias MingaEditor.Input.Scoped
  alias Minga.Mode
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync

  defp base_state(opts) do
    opts = Keyword.put_new_lazy(opts, :sidebar_registry, fn -> private_sidebar_registry() end)
    {:ok, buf} = BufferProcess.start_link(content: "hello world")
    {:ok, prompt_buf} = BufferProcess.start_link(content: "")

    agent = %AgentState{
      runtime: %RuntimeState{status: :idle},
      buffer: Keyword.get(opts, :agent_buffer, nil)
    }

    agentic = %UIState{
      panel: %UIState.Panel{
        visible: Keyword.get(opts, :panel_visible, false),
        input_focused: Keyword.get(opts, :input_focused, false),
        prompt_buffer: prompt_buf
      },
      view: %UIState.View{
        active: Keyword.get(opts, :agentic_active, false),
        focus: Keyword.get(opts, :focus, :chat)
      }
    }

    tab_bar =
      if Keyword.get(opts, :agentic_active, false) do
        # Agent mode: file tab + agent tab, agent tab active
        tb = TabBar.new(Tab.new_file(1, "[no file]"))
        {tb, _} = TabBar.add(tb, :agent, "Agent")
        tb
      else
        TabBar.new(Tab.new_file(1, "[no file]"))
      end

    mode = if(Keyword.get(opts, :input_focused, false), do: :insert, else: :normal)

    %EditorState{
      port_manager: self(),
      sidebar_registry: Keyword.fetch!(opts, :sidebar_registry),
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: %VimState{mode: mode, mode_state: Mode.initial_state()},
        buffers: %Buffers{active: buf, list: [buf]},
        keymap_scope: Keyword.get(opts, :keymap_scope, :editor),
        agent_ui: agentic
      },
      shell_state: %MingaEditor.Shell.Traditional.State{agent: agent, tab_bar: tab_bar}
    }
  end

  defp activated_agent_state do
    state = base_state(keymap_scope: :editor, agentic_active: false)
    file_buffer = state.workspace.buffers.active
    state = AgentCommands.toggle_agentic_view(state)
    session = AgentAccess.session(state)
    agent_buffer = AgentAccess.agent(state).buffer

    {state, session, file_buffer, agent_buffer}
  end

  defp focus_prompt(state, text) do
    AgentAccess.update_agent_ui(state, fn ui ->
      ui
      |> UIState.set_input_focused(true)
      |> UIState.set_prompt_text(text)
    end)
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
      {:ok, agent_buf} = BufferProcess.start_link(content: "line1\nline2\nline3\nline4")

      state =
        base_state(
          keymap_scope: :editor,
          panel_visible: true,
          agent_buffer: agent_buf
        )

      {:ok, state: state, agent_buf: agent_buf}
    end

    test "q and ESC toggle the agent split", %{state: state} do
      for key <- [?q, 27] do
        {:handled, new_state} = walk_surface_handlers(state, key, 0)
        refute is_nil(new_state)
      end
    end

    test "i focuses the input", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, ?i, 0)
      assert AgentAccess.input_focused?(new_state) == true
    end

    test "j delegates to mode FSM with agent buffer", %{state: state, agent_buf: agent_buf} do
      # j should delegate to mode FSM, moving cursor in agent buffer
      {:handled, _new_state} = walk_surface_handlers(state, ?j, 0)
      {line, _col} = BufferProcess.cursor(agent_buf)
      assert line >= 1
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
      {:ok, agent_buf} = BufferProcess.start_link(content: "chat content")

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
      assert new_state.workspace.editing.mode == :normal
    end

    test "safe control keys are handled", %{state: state} do
      for {key, mods} <- [{127, 0}, {?c, 0x02}, {?d, 0x02}] do
        assert {:handled, _new_state} = walk_surface_handlers(state, key, mods)
      end
    end

    test "Enter on empty prompt is no-op", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 13, 0)
      assert AgentAccess.input_focused?(new_state) == true
    end

    test "modified Enter inserts newline", %{state: state} do
      for mods <- [0x01, 0x04] do
        {:handled, new_state} = walk_surface_handlers(state, 13, mods)
        assert length(UIState.input_lines(AgentAccess.panel(new_state))) > 1
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Agent scope (full-screen agentic view)
  # ══════════════════════════════════════════════════════════════════════════

  describe "agent scope — normal mode" do
    setup do
      {state, session, file_buffer, agent_buffer} = activated_agent_state()
      {:ok, state: state, session: session, file_buffer: file_buffer, agent_buffer: agent_buffer}
    end

    test "navigation keys pass through Scoped and are handled by AgentNav", %{state: state} do
      for {key, mods} <- [{?j, 0}, {?k, 0}, {?G, 0}, {?d, 0x02}, {?u, 0x02}, {?~, 0}] do
        assert_passthrough_then_handled(state, key, mods)
      end
    end

    test "q returns to the recorded file tab and keeps the agent session", %{
      state: state,
      session: session,
      file_buffer: file_buffer
    } do
      assert state.workspace.keymap_scope == :agent
      assert AgentAccess.view(state).return_target.active_tab_id == 1
      assert AgentAccess.view(state).return_target.active_buffer == file_buffer

      {:handled, new_state} = Scoped.handle_key(state, ?q, 0)
      assert new_state.workspace.keymap_scope == :editor
      assert new_state.shell_state.tab_bar.active_id == 1
      assert TabBar.filter_by_kind(new_state.shell_state.tab_bar, :agent) != []

      assert Enum.any?(
               new_state.shell_state.tab_bar.tabs,
               &(&1.kind == :agent and &1.session == session)
             )
    end

    test "ESC returns to the recorded file tab when nothing transient is open", %{state: state} do
      assert state.workspace.keymap_scope == :agent
      assert AgentAccess.view(state).return_target.active_tab_id == 1

      {:handled, new_state} = Scoped.handle_key(state, 27, 0)
      assert new_state.workspace.keymap_scope == :editor
      assert new_state.shell_state.tab_bar.active_id == 1
      assert TabBar.filter_by_kind(new_state.shell_state.tab_bar, :agent) != []
    end

    test "return falls back to the most recent remaining file tab when the target closed", %{
      state: state
    } do
      {tb, fallback_tab} = TabBar.insert(state.shell_state.tab_bar, :file, "fallback.ex")
      {:ok, tb} = TabBar.remove(tb, 1)
      state = put_in(state.shell_state.tab_bar, tb)

      {:handled, new_state} = Scoped.handle_key(state, ?q, 0)
      assert new_state.workspace.keymap_scope == :editor
      assert new_state.shell_state.tab_bar.active_id == fallback_tab.id
    end

    test "return without file tabs does not create an untitled fallback", %{
      state: state,
      file_buffer: file_buffer,
      agent_buffer: agent_buffer
    } do
      {:ok, tb} = TabBar.remove(state.shell_state.tab_bar, 1)
      state = put_in(state.shell_state.tab_bar, tb)

      {:handled, new_state} = Scoped.handle_key(state, ?q, 0)
      assert new_state.workspace.keymap_scope == :editor
      assert TabBar.filter_by_kind(new_state.shell_state.tab_bar, :file) == []
      assert new_state.workspace.buffers.active == file_buffer
      assert hd(new_state.workspace.buffers.list) == file_buffer
      refute new_state.workspace.buffers.active == agent_buffer
      assert new_state.shell_state.status_msg == "No file tabs in this workspace"
    end

    test "? toggles help", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ??, 0)
      assert AgentAccess.view(new_state).help_visible
    end

    test "Tab switches focus", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, 9, 0)
      assert AgentAccess.view(new_state).focus == :file_viewer
    end

    test "i focuses input", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?i, 0)
      assert AgentAccess.input_focused?(new_state)
    end

    test "prefix keys start a prefix sequence", %{state: state} do
      for key <- [?g, ?z, 93, 91] do
        {:handled, new_state} = Scoped.handle_key(state, key, 0)
        assert AgentAccess.view(new_state).pending_prefix != nil
      end
    end

    test "gg scrolls to top via prefix", %{state: state} do
      {:handled, g_state} = Scoped.handle_key(state, ?g, 0)
      assert {:handled, _} = Scoped.handle_key(g_state, ?g, 0)
    end

    test "panel resize keys work", %{state: state} do
      {:handled, grow} = Scoped.handle_key(state, ?}, 0)

      assert AgentAccess.view(grow).chat_width_pct >
               AgentAccess.view(state).chat_width_pct

      {:handled, shrink} = Scoped.handle_key(state, ?{, 0)

      assert AgentAccess.view(shrink).chat_width_pct <
               AgentAccess.view(state).chat_width_pct
    end

    test "= resets panel split", %{state: state} do
      {:handled, resized} = Scoped.handle_key(state, ?}, 0)
      {:handled, reset} = Scoped.handle_key(resized, ?=, 0)

      assert AgentAccess.view(reset).chat_width_pct ==
               AgentAccess.view(state).chat_width_pct
    end

    test "ESC dismisses help before returning to the editor", %{state: state} do
      state = AgentAccess.update_view(state, fn v -> %{v | help_visible: true} end)

      {:handled, new_state} = Scoped.handle_key(state, 27, 0)
      refute AgentAccess.view(new_state).help_visible
      assert new_state.workspace.keymap_scope == :agent
      assert new_state.shell_state.tab_bar.active_id == state.shell_state.tab_bar.active_id
    end

    test "ESC leaves prompt focus without clearing prompt text before returning", %{state: state} do
      state = focus_prompt(state, "keep this")
      agent_tab_id = TabBar.find_by_kind(state.shell_state.tab_bar, :agent).id

      {:handled, unfocused_state} = Scoped.handle_key(state, 27, 0)
      refute AgentAccess.input_focused?(unfocused_state)
      assert UIState.prompt_text(AgentAccess.agent_ui(unfocused_state)) == "keep this"
      assert unfocused_state.workspace.keymap_scope == :agent

      {:handled, returned_state} = Scoped.handle_key(unfocused_state, 27, 0)
      assert returned_state.workspace.keymap_scope == :editor
      assert returned_state.shell_state.tab_bar.active_id == 1

      reopened_state = EditorState.switch_tab(returned_state, agent_tab_id)
      assert UIState.prompt_text(AgentAccess.agent_ui(reopened_state)) == "keep this"
    end

    test "ESC keeps prompt focus when cancelling visual and operator-pending prompt states", %{
      state: state
    } do
      for {enter_key, mode} <- [{?v, :visual}, {?d, :operator_pending}] do
        state = state |> focus_prompt("#{mode} draft")

        {:handled, mode_state} = Scoped.handle_key(state, enter_key, 0)
        assert AgentAccess.input_focused?(mode_state)
        assert Minga.Editing.mode(mode_state) == mode

        {:handled, new_state} = Scoped.handle_key(mode_state, 27, 0)
        assert AgentAccess.input_focused?(new_state)
        assert new_state.workspace.editing.mode == :normal
        assert UIState.prompt_text(AgentAccess.agent_ui(new_state)) == "#{mode} draft"
      end
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
      assert new_state.workspace.editing.mode == :normal
    end

    test "printable char self-inserts", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?x, 0)
      assert UIState.input_text(AgentAccess.panel(new_state)) =~ "x"
    end

    test "editing control keys are handled", %{state: state} do
      {:handled, with_char} = Scoped.handle_key(state, ?a, 0)
      assert {:handled, _} = Scoped.handle_key(with_char, 127, 0)
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
      assert new_state.workspace.editing.mode == :search
    end
  end

  describe "agent scope — toast dismiss" do
    test "any key dismisses toast then processes normally" do
      state = base_state(keymap_scope: :agent, agentic_active: true)

      state =
        AgentAccess.update_agent_ui(state, fn ui ->
          UIState.push_toast(ui, "test", :info)
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
      assert AgentAccess.view(new_state).focus == :chat
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # File tree scope
  # ══════════════════════════════════════════════════════════════════════════

  describe "file tree scope" do
    test "q closes tree", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      {:handled, new_state} = FileTreeHandler.handle_key(state, ?q, 0)
      assert new_state.workspace.keymap_scope == :editor
      assert ft(new_state).tree == nil
    end

    test "unbound key delegates to mode FSM for vim nav", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      # j is not bound in file_tree scope (handled by mode FSM delegation)
      {:handled, new_state} = FileTreeHandler.handle_key(state, ?j, 0)
      assert ft(new_state).tree.cursor == 1
    end

    test "leader sequence in progress delegates to mode FSM", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      # Use a real Bindings.Node, not a plain map, because the mode FSM
      # calls Bindings.lookup on leader_node.
      leader_node = %Minga.Keymap.Bindings.Node{children: %{}, command: nil, description: nil}

      leader_state = put_in(state.workspace.editing.mode_state.leader_node, leader_node)

      {:handled, _new_state} = FileTreeHandler.handle_key(leader_state, ?f, 0)
    end

    test "tree scope bindings are handled", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))

      for {key, file_count} <- [{?h, 0}, {?l, 0}, {?r, 3}] do
        state = make_tree_state(tmp_dir, file_count)
        assert {:handled, _new_state} = FileTreeHandler.handle_key(state, key, 0)
      end
    end

    test "H toggles hidden files (scope binding)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".hidden"), "")
      state = make_tree_state(tmp_dir, 0)

      entries_before = length(FileTree.visible_entries(ft(state).tree))
      {:handled, new_state} = FileTreeHandler.handle_key(state, ?H, 0)
      entries_after = length(FileTree.visible_entries(ft(new_state).tree))

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
      state = EditorState.set_file_tree(state, %{ft(state) | focused: false})
      assert {:passthrough, _} = FileTreeHandler.handle_key(state, ?q, 0)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Cross-scope leader sequences
  # ══════════════════════════════════════════════════════════════════════════

  describe "leader sequences work across all scopes" do
    test "SPC and pending leader pass through in non-input scopes" do
      agent_state = base_state(keymap_scope: :agent, agentic_active: true)
      leader_state = put_in(agent_state.workspace.editing.mode_state.leader_node, %{})

      for {state, key} <- [
            {agent_state, ?\s},
            {base_state(keymap_scope: :editor), ?\s},
            {leader_state, ?a}
          ] do
        assert {:passthrough, _} = Scoped.handle_key(state, key, 0)
      end
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

    test "approval decision keys are handled", %{state: state} do
      for key <- [?y, ?a, ?t, ?n] do
        assert {:handled, _new_state} = walk_surface_handlers(state, key, 0)
      end
    end

    test "unrelated key is swallowed during approval", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, ?x, 0)
      # The key is swallowed, pending_approval stays
      assert AgentAccess.agent(new_state).pending_approval != nil
    end

    test "only triggers when input is not focused", %{state: state} do
      # If input is focused in insert mode, approval keys should not be intercepted
      state =
        AgentAccess.update_panel(state, fn p ->
          %{p | input_focused: true, visible: true}
        end)

      state = %{
        state
        | workspace: %{state.workspace | editing: %{state.workspace.editing | mode: :insert}}
      }

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
        AgentAccess.update_view(state, fn v ->
          %{v | preview: %Preview{content: {:diff, review}}}
        end)

      {:ok, state: state}
    end

    test "diff review action and navigation keys are handled", %{state: state} do
      for key <- [?y, ?x, ?Y, ?X, ?j] do
        assert {:handled, _new_state} = walk_surface_handlers(state, key, 0)
      end
    end

    test "diff review only triggers in file_viewer focus" do
      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :chat)

      review = DiffReview.new("test.ex", "old line\n", "new line\n")

      state =
        AgentAccess.update_view(state, fn v ->
          %{v | preview: %Preview{content: {:diff, review}}}
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
        AgentAccess.update_panel(state, fn p -> %{p | mention_completion: completion} end)

      {:ok, state: state}
    end

    test "Tab moves to next candidate", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 9, 0)
      assert AgentAccess.panel(new_state).mention_completion.selected == 1
    end

    test "Enter and Escape clear mention completion", %{state: state} do
      for key <- [13, 27] do
        {:handled, new_state} = walk_surface_handlers(state, key, 0)
        assert AgentAccess.panel(new_state).mention_completion == nil
      end
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
        AgentAccess.update_panel(state, fn p -> %{p | input_focused: false} end)

      {:handled, _new_state} = walk_surface_handlers(state, ?j, 0)
    end
  end

  describe "editor panel — slash command completion sub-state" do
    test "filters commands and accepts without inserting an @ mention" do
      state = base_state(keymap_scope: :editor, panel_visible: true, input_focused: true)

      {:handled, state} = walk_surface_handlers(state, ?/, 0)
      {:handled, state} = walk_surface_handlers(state, ?m, 0)
      {:handled, state} = walk_surface_handlers(state, ?o, 0)
      comp = AgentAccess.panel(state).mention_completion
      assert comp.slash_candidates == [{"model", "Set the model: /model <name>"}]

      {:handled, state} = walk_surface_handlers(state, 13, 0)
      assert Minga.Buffer.content(AgentAccess.panel(state).prompt_buffer) == "/model "
      assert AgentAccess.panel(state).mention_completion == nil
    end
  end

  describe "editor scope — panel mention completion" do
    setup do
      {:ok, agent_buf} = BufferProcess.start_link(content: "chat")

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
        AgentAccess.update_panel(state, fn p -> %{p | mention_completion: completion} end)

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

  describe "handle_mouse" do
    test "routes or passes through by active surface", %{tmp_dir: tmp_dir} do
      for state <- [
            base_state(keymap_scope: :agent, agentic_active: true),
            make_tree_state(tmp_dir)
          ] do
        result = walk_surface_mouse(state, 5, 5, :left, 0, :press, 1)
        assert elem(result, 0) in [:handled, :passthrough]
      end

      state = base_state(keymap_scope: :editor)
      assert {:passthrough, _} = FileTreeHandler.handle_mouse(state, 5, 5, :left, 0, :press, 1)
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp assert_passthrough_then_handled(state, cp, mods) do
    assert {:passthrough, _} = Scoped.handle_key(state, cp, mods)
    assert {:handled, _} = walk_surface_handlers(state, cp, mods)
  end

  # Walks all surface handlers (including the new sub-state handlers)
  # in order, returning the result from the first handler that handles
  # the key.
  defp walk_surface_handlers(state, cp, mods) do
    Enum.reduce_while(MingaEditor.Input.surface_handlers(), {:passthrough, state}, fn handler,
                                                                                      {_, acc} ->
      case handler.handle_key(acc, cp, mods) do
        {:handled, new_state} -> {:halt, {:handled, new_state}}
        {:passthrough, new_state} -> {:cont, {:passthrough, new_state}}
      end
    end)
  end

  defp ft(state), do: EditorState.file_tree_state(state)

  defp walk_surface_mouse(state, row, col, button, mods, event_type, cc) do
    handlers =
      MingaEditor.Input.surface_handlers()
      |> Enum.filter(&function_exported?(&1, :handle_mouse, 7))

    Enum.reduce_while(handlers, {:passthrough, state}, fn handler, {_, acc} ->
      case handler.handle_mouse(acc, row, col, button, mods, event_type, cc) do
        {:handled, new_state} -> {:halt, {:handled, new_state}}
        {:passthrough, new_state} -> {:cont, {:passthrough, new_state}}
      end
    end)
  end

  defp private_sidebar_registry do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({MingaEditor.Extension.Sidebar, name: table, notify: false})
    table
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

    state = base_state(keymap_scope: :file_tree)
    EditorState.set_file_tree(state, %FileTreeState{tree: tree, focused: true, buffer: buf})
  end
end
