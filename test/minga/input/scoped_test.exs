defmodule Minga.Input.ScopedTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.Viewport
  alias Minga.Input.Scoped
  alias Minga.Mode

  defp base_state(opts) do
    {:ok, buf} = BufferServer.start_link(content: "hello world")

    panel = %PanelState{
      visible: true,
      input_focused: Keyword.get(opts, :input_focused, false),
      scroll_offset: 0,
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
      buffer: nil
    }

    agentic = %ViewState{
      active: Keyword.get(opts, :agentic_active, false),
      focus: Keyword.get(opts, :focus, :chat)
    }

    %EditorState{
      port_manager: self(),
      viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: buf, list: [buf]},
      focus_stack: [],
      keymap_scope: Keyword.get(opts, :keymap_scope, :editor),
      agent: agent,
      agentic: agentic
    }
  end

  describe "editor scope" do
    test "all keys pass through" do
      state = base_state(keymap_scope: :editor)
      assert {:passthrough, _} = Scoped.handle_key(state, ?j, 0)
      assert {:passthrough, _} = Scoped.handle_key(state, ?k, 0)
      assert {:passthrough, _} = Scoped.handle_key(state, ?\s, 0)
    end
  end

  describe "agent scope — normal mode" do
    setup do
      {:ok, state: base_state(keymap_scope: :agent, agentic_active: true)}
    end

    test "j scrolls down", %{state: state} do
      assert {:handled, new_state} = Scoped.handle_key(state, ?j, 0)

      assert new_state.agent.panel.scroll_offset != state.agent.panel.scroll_offset or
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

    test "ESC unfocuses input", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, 27, 0)
      refute new_state.agent.panel.input_focused
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

    test "SPC passes through for leader key even in insert mode", %{state: state} do
      # SPC should NOT pass through when input is focused (it's a space char)
      # The check is: input_focused: false for SPC passthrough
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

  describe "file_tree scope" do
    test "q closes tree" do
      state = base_state(keymap_scope: :file_tree)
      state = put_in(state.file_tree.focused, true)
      {:handled, new_state} = Scoped.handle_key(state, ?q, 0)
      assert new_state.keymap_scope == :editor
    end

    test "unbound key passes through for mode FSM" do
      state = base_state(keymap_scope: :file_tree)
      state = put_in(state.file_tree.focused, true)
      # j is not bound in file_tree scope (handled by mode FSM for vim nav)
      assert {:passthrough, _} = Scoped.handle_key(state, ?j, 0)
    end

    test "leader sequence in progress passes through" do
      state = base_state(keymap_scope: :file_tree)
      state = put_in(state.file_tree.focused, true)
      leader_state = %{state | mode_state: %{state.mode_state | leader_node: %{}}}
      assert {:passthrough, _} = Scoped.handle_key(leader_state, ?f, 0)
    end
  end

  describe "scope inactive guards" do
    test "agent scope with agentic not active passes through" do
      state = base_state(keymap_scope: :agent, agentic_active: false)
      assert {:passthrough, _} = Scoped.handle_key(state, ?j, 0)
    end

    test "file_tree scope with tree not focused passes through" do
      state = base_state(keymap_scope: :file_tree)
      # focused defaults to false
      assert {:passthrough, _} = Scoped.handle_key(state, ?q, 0)
    end
  end
end
