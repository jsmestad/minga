defmodule MingaEditor.Input.ScopedEditorAgentTest do
  use ExUnit.Case, async: true

  @moduledoc false
  @moduletag :tmp_dir

  import Minga.Test.ScopedInputHelpers

  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.TabBar
  alias MingaEditor.Input.AgentPanel
  alias MingaEditor.Input.Scoped

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
      state =
        base_state(
          keymap_scope: :editor,
          panel_visible: true
        )

      {:ok, state: state}
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

    test "j scrolls the semantic transcript", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, ?j, 0)
      assert AgentAccess.panel(new_state).scroll.offset == 1
    end

    test "passthrough when panel not visible" do
      state = base_state(keymap_scope: :editor, panel_visible: false)
      assert {:passthrough, _} = AgentPanel.handle_key(state, ?j, 0)
    end
  end

  describe "editor scope — agent side panel input" do
    setup do
      state =
        base_state(
          keymap_scope: :editor,
          panel_visible: true,
          input_focused: true
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
        assert Enum.count(UIState.input_lines(AgentAccess.panel(new_state))) > 1
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Agent scope (full-screen agentic view)
  # ══════════════════════════════════════════════════════════════════════════

  describe "agent scope — normal mode" do
    setup do
      {state, session, file_buffer} = activated_agent_state()
      {:ok, state: state, session: session, file_buffer: file_buffer}
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
      assert EditorState.tab_bar(new_state).active_id == 1
      assert TabBar.filter_by_kind(EditorState.tab_bar(new_state), :agent) != []

      assert Enum.any?(
               EditorState.tab_bar(new_state).tabs,
               &(&1.kind == :agent and &1.session == session)
             )
    end

    test "ESC returns to the recorded file tab when nothing transient is open", %{state: state} do
      assert state.workspace.keymap_scope == :agent
      assert AgentAccess.view(state).return_target.active_tab_id == 1

      {:handled, new_state} = Scoped.handle_key(state, 27, 0)
      assert new_state.workspace.keymap_scope == :editor
      assert EditorState.tab_bar(new_state).active_id == 1
      assert TabBar.filter_by_kind(EditorState.tab_bar(new_state), :agent) != []
    end

    test "return falls back to the most recent remaining file tab when the target closed", %{
      state: state
    } do
      {tb, fallback_tab} = TabBar.insert(EditorState.tab_bar(state), :file, "fallback.ex")
      {:ok, tb} = TabBar.remove(tb, 1)
      state = EditorState.set_tab_bar(state, tb)

      {:handled, new_state} = Scoped.handle_key(state, ?q, 0)
      assert new_state.workspace.keymap_scope == :editor
      assert EditorState.tab_bar(new_state).active_id == fallback_tab.id
    end

    test "return without file tabs does not create an untitled fallback", %{
      state: state,
      file_buffer: file_buffer
    } do
      {:ok, tb} = TabBar.remove(EditorState.tab_bar(state), 1)
      state = EditorState.set_tab_bar(state, tb)

      {:handled, new_state} = Scoped.handle_key(state, ?q, 0)
      assert new_state.workspace.keymap_scope == :editor
      assert TabBar.filter_by_kind(EditorState.tab_bar(new_state), :file) == []
      assert new_state.workspace.buffers.active == file_buffer
      assert hd(new_state.workspace.buffers.list) == file_buffer
      assert new_state.shell_runtime.state.notice.message == "No file tabs in this workspace"
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
      assert EditorState.tab_bar(new_state).active_id == EditorState.tab_bar(state).active_id
    end

    test "ESC leaves prompt focus without clearing prompt text before returning", %{state: state} do
      state = focus_prompt(state, "keep this")
      agent_tab_id = TabBar.find_by_kind(EditorState.tab_bar(state), :agent).id

      {:handled, unfocused_state} = Scoped.handle_key(state, 27, 0)
      refute AgentAccess.input_focused?(unfocused_state)
      assert UIState.prompt_text(AgentAccess.agent_ui(unfocused_state)) == "keep this"
      assert unfocused_state.workspace.keymap_scope == :agent

      {:handled, returned_state} = Scoped.handle_key(unfocused_state, 27, 0)
      assert returned_state.workspace.keymap_scope == :editor
      assert EditorState.tab_bar(returned_state).active_id == 1

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
end
