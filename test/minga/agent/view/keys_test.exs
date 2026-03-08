defmodule Minga.Agent.View.KeysTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Agent.View.Keys
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.Viewport
  alias Minga.Input
  alias Minga.Mode
  alias Minga.Port.Protocol

  @ctrl Protocol.mod_ctrl()

  defp base_state(opts \\ []) do
    {:ok, buf} = BufferServer.start_link(content: "line one\nline two\nline three")

    panel = %PanelState{
      visible: true,
      input_focused: false,
      input_text: "",
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
      active: Keyword.get(opts, :active, true),
      focus: Keyword.get(opts, :focus, :chat),
      file_viewer_scroll: Keyword.get(opts, :viewer_scroll, 0),
      saved_windows: nil,
      pending_prefix: Keyword.get(opts, :pending_prefix, nil),
      saved_file_tree: nil
    }

    %EditorState{
      port_manager: self(),
      viewport: Viewport.new(24, 80),
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      focus_stack: Input.default_stack(),
      agent: agent,
      agentic: agentic
    }
  end

  # ── Passthrough when view is closed ─────────────────────────────────────────

  describe "when agentic view is inactive" do
    test "passes all keys through" do
      state = base_state(active: false)
      assert {:passthrough, _} = Keys.handle_key(state, ?j, 0)
      assert {:passthrough, _} = Keys.handle_key(state, ?i, 0)
      assert {:passthrough, _} = Keys.handle_key(state, 27, 0)
    end
  end

  # ── SPC always delegates to mode FSM ────────────────────────────────────────

  describe "SPC key" do
    test "passes through so leader/which-key sequences work" do
      state = base_state()
      assert {:passthrough, _} = Keys.handle_key(state, ?\s, 0)
    end

    test "ctrl+space is still handled (not a plain space)" do
      state = base_state()
      assert {:handled, _} = Keys.handle_key(state, ?\s, @ctrl)
    end
  end

  # ── Chat navigation mode ─────────────────────────────────────────────────────

  describe "chat navigation (focus: :chat, input_focused: false)" do
    test "j scrolls chat down by 1" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?j, 0)
      assert new_state.agent.panel.scroll_offset == 1
    end

    test "k scrolls chat up (clamped at 0)" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?k, 0)
      assert new_state.agent.panel.scroll_offset == 0
    end

    test "k after j scrolls up" do
      state = base_state(focus: :chat)
      {:handled, state2} = Keys.handle_key(state, ?j, 0)
      {:handled, state2} = Keys.handle_key(state2, ?j, 0)
      {:handled, state3} = Keys.handle_key(state2, ?k, 0)
      assert state3.agent.panel.scroll_offset == 1
    end

    test "Ctrl-d scrolls chat down half page" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?d, @ctrl)
      assert new_state.agent.panel.scroll_offset > 0
    end

    test "Ctrl-u scrolls chat up (clamped at 0 from start)" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?u, @ctrl)
      assert new_state.agent.panel.scroll_offset == 0
    end

    test "g sets pending_prefix to :g" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?g, 0)
      assert new_state.agentic.pending_prefix == :g
    end

    test "gg scrolls chat to top" do
      state = base_state(focus: :chat)
      # Scroll down first
      {:handled, scrolled} = Keys.handle_key(state, ?j, 0)
      {:handled, scrolled} = Keys.handle_key(scrolled, ?j, 0)
      assert scrolled.agent.panel.scroll_offset == 2
      # Now gg
      {:handled, with_g} = Keys.handle_key(scrolled, ?g, 0)
      {:handled, at_top} = Keys.handle_key(with_g, ?g, 0)
      assert at_top.agent.panel.scroll_offset == 0
      assert at_top.agentic.pending_prefix == nil
    end

    test "g then another key cancels pending_prefix and processes the key" do
      state = base_state(focus: :chat)
      {:handled, with_g} = Keys.handle_key(state, ?g, 0)
      assert with_g.agentic.pending_prefix == :g
      {:handled, result} = Keys.handle_key(with_g, ?j, 0)
      assert result.agentic.pending_prefix == nil
      assert result.agent.panel.scroll_offset == 1
    end

    test "G scrolls to bottom (large offset)" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?G, 0)
      assert new_state.agent.panel.scroll_offset > 0
    end

    test "o is handled without crashing (no session)" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?o, 0)
      assert new_state == state
    end

    test "i focuses the input field" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?i, 0)
      assert new_state.agent.panel.input_focused == true
    end

    test "a focuses the input field" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?a, 0)
      assert new_state.agent.panel.input_focused == true
    end

    test "Enter focuses the input field" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, 13, 0)
      assert new_state.agent.panel.input_focused == true
    end

    test "Tab switches focus to the file viewer" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, 9, 0)
      assert new_state.agentic.focus == :file_viewer
    end

    test "q closes the agentic view" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?q, 0)
      assert new_state.agentic.active == false
    end

    test "Escape closes the agentic view" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, 27, 0)
      assert new_state.agentic.active == false
    end

    test "unrecognized keys are swallowed (handled) without state change" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?x, 0)
      assert new_state.agent.panel.scroll_offset == 0
      assert new_state.agentic.focus == :chat
    end
  end

  # ── Chat input mode ──────────────────────────────────────────────────────────

  describe "chat input mode (focus: :chat, input_focused: true)" do
    defp input_state do
      state = base_state(focus: :chat)
      put_in(state.agent.panel.input_focused, true)
    end

    test "printable characters are appended to input_text" do
      state = input_state()
      {:handled, s1} = Keys.handle_key(state, ?h, 0)
      {:handled, s2} = Keys.handle_key(s1, ?i, 0)
      assert s2.agent.panel.input_text == "hi"
    end

    test "Backspace (127) removes the last character" do
      state = input_state()
      {:handled, s1} = Keys.handle_key(state, ?h, 0)
      {:handled, s2} = Keys.handle_key(s1, ?i, 0)
      {:handled, s3} = Keys.handle_key(s2, 127, 0)
      assert s3.agent.panel.input_text == "h"
    end

    test "Backspace on empty input is a no-op" do
      state = input_state()
      {:handled, new_state} = Keys.handle_key(state, 127, 0)
      assert new_state.agent.panel.input_text == ""
    end

    test "Escape unfocuses the input (back to navigation)" do
      state = input_state()
      {:handled, new_state} = Keys.handle_key(state, 27, 0)
      assert new_state.agent.panel.input_focused == false
    end

    test "ctrl+d scrolls chat while in input mode" do
      state = input_state()
      {:handled, new_state} = Keys.handle_key(state, ?d, @ctrl)
      assert new_state.agent.panel.scroll_offset > 0
    end

    test "ctrl modifier prevents printable char from appending" do
      state = input_state()
      {:handled, new_state} = Keys.handle_key(state, ?h, @ctrl)
      assert new_state.agent.panel.input_text == ""
    end
  end

  # ── File viewer navigation ───────────────────────────────────────────────────

  describe "file viewer navigation (focus: :file_viewer)" do
    defp viewer_state(scroll \\ 10) do
      base_state(focus: :file_viewer, viewer_scroll: scroll)
    end

    test "j increments the file viewer scroll by 1" do
      state = viewer_state(10)
      {:handled, new_state} = Keys.handle_key(state, ?j, 0)
      assert new_state.agentic.file_viewer_scroll == 11
    end

    test "k decrements the file viewer scroll by 1" do
      state = viewer_state(10)
      {:handled, new_state} = Keys.handle_key(state, ?k, 0)
      assert new_state.agentic.file_viewer_scroll == 9
    end

    test "k clamps at 0" do
      state = viewer_state(0)
      {:handled, new_state} = Keys.handle_key(state, ?k, 0)
      assert new_state.agentic.file_viewer_scroll == 0
    end

    test "Ctrl-d scrolls down by half page" do
      state = viewer_state(0)
      {:handled, new_state} = Keys.handle_key(state, ?d, @ctrl)
      # viewport is 24 rows, half page = 12
      assert new_state.agentic.file_viewer_scroll == 12
    end

    test "Ctrl-u scrolls up by half page" do
      state = viewer_state(20)
      {:handled, new_state} = Keys.handle_key(state, ?u, @ctrl)
      assert new_state.agentic.file_viewer_scroll == 8
    end

    test "Ctrl-u clamps at 0" do
      state = viewer_state(5)
      {:handled, new_state} = Keys.handle_key(state, ?u, @ctrl)
      assert new_state.agentic.file_viewer_scroll == 0
    end

    test "g sets pending_prefix to :g" do
      state = viewer_state(50)
      {:handled, new_state} = Keys.handle_key(state, ?g, 0)
      assert new_state.agentic.pending_prefix == :g
      assert new_state.agentic.file_viewer_scroll == 50
    end

    test "gg scrolls to top" do
      state = viewer_state(50)
      {:handled, with_g} = Keys.handle_key(state, ?g, 0)
      {:handled, at_top} = Keys.handle_key(with_g, ?g, 0)
      assert at_top.agentic.file_viewer_scroll == 0
      assert at_top.agentic.pending_prefix == nil
    end

    test "g then another key cancels pending_prefix and processes the key" do
      state = viewer_state(50)
      {:handled, with_g} = Keys.handle_key(state, ?g, 0)
      {:handled, result} = Keys.handle_key(with_g, ?j, 0)
      assert result.agentic.pending_prefix == nil
      assert result.agentic.file_viewer_scroll == 51
    end

    test "G scrolls to a large offset (approximate bottom)" do
      state = viewer_state(0)
      {:handled, new_state} = Keys.handle_key(state, ?G, 0)
      assert new_state.agentic.file_viewer_scroll > 0
    end

    test "Tab switches focus back to chat" do
      state = viewer_state()
      {:handled, new_state} = Keys.handle_key(state, 9, 0)
      assert new_state.agentic.focus == :chat
    end

    test "q closes the agentic view" do
      state = viewer_state()
      {:handled, new_state} = Keys.handle_key(state, ?q, 0)
      assert new_state.agentic.active == false
    end

    test "Escape closes the agentic view" do
      state = viewer_state()
      {:handled, new_state} = Keys.handle_key(state, 27, 0)
      assert new_state.agentic.active == false
    end

    test "z sets pending_prefix to :z" do
      state = viewer_state(10)
      {:handled, new_state} = Keys.handle_key(state, ?z, 0)
      assert new_state.agentic.pending_prefix == :z
      assert new_state.agentic.file_viewer_scroll == 10
    end

    test "unrecognized keys are swallowed without changing scroll" do
      state = viewer_state(10)
      {:handled, new_state} = Keys.handle_key(state, ?x, 0)
      assert new_state.agentic.file_viewer_scroll == 10
    end

    test "} grows chat panel" do
      state = viewer_state(10)
      {:handled, new_state} = Keys.handle_key(state, ?}, 0)
      assert new_state.agentic.chat_width_pct == 70
    end

    test "{ shrinks chat panel" do
      state = viewer_state(10)
      {:handled, new_state} = Keys.handle_key(state, ?{, 0)
      assert new_state.agentic.chat_width_pct == 60
    end
  end

  # ── Prefix state machine ────────────────────────────────────────────────────

  describe "z prefix (folds/collapse)" do
    test "z sets pending_prefix to :z in chat nav" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?z, 0)
      assert new_state.agentic.pending_prefix == :z
    end

    test "za toggles collapse (clears prefix)" do
      state = base_state(focus: :chat)
      {:handled, with_z} = Keys.handle_key(state, ?z, 0)
      {:handled, result} = Keys.handle_key(with_z, ?a, 0)
      assert result.agentic.pending_prefix == nil
    end

    test "zA toggles all collapses" do
      state = base_state(focus: :chat)
      {:handled, with_z} = Keys.handle_key(state, ?z, 0)
      {:handled, result} = Keys.handle_key(with_z, ?A, 0)
      assert result.agentic.pending_prefix == nil
    end

    test "z then unrecognized key cancels prefix and processes key" do
      state = base_state(focus: :chat)
      {:handled, with_z} = Keys.handle_key(state, ?z, 0)
      {:handled, result} = Keys.handle_key(with_z, ?j, 0)
      assert result.agentic.pending_prefix == nil
      assert result.agent.panel.scroll_offset == 1
    end
  end

  describe "] prefix (next item)" do
    test "] sets pending_prefix to :bracket_next" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?], 0)
      assert new_state.agentic.pending_prefix == :bracket_next
    end

    test "]m is handled (stubbed, clears prefix)" do
      state = base_state(focus: :chat)
      {:handled, with_bracket} = Keys.handle_key(state, ?], 0)
      {:handled, result} = Keys.handle_key(with_bracket, ?m, 0)
      assert result.agentic.pending_prefix == nil
    end

    test "]c is handled (stubbed)" do
      state = base_state(focus: :chat)
      {:handled, with_bracket} = Keys.handle_key(state, ?], 0)
      {:handled, result} = Keys.handle_key(with_bracket, ?c, 0)
      assert result.agentic.pending_prefix == nil
    end

    test "]t is handled (stubbed)" do
      state = base_state(focus: :chat)
      {:handled, with_bracket} = Keys.handle_key(state, ?], 0)
      {:handled, result} = Keys.handle_key(with_bracket, ?t, 0)
      assert result.agentic.pending_prefix == nil
    end

    test "] then unrecognized key cancels prefix and processes key" do
      state = base_state(focus: :chat)
      {:handled, with_bracket} = Keys.handle_key(state, ?], 0)
      {:handled, result} = Keys.handle_key(with_bracket, ?j, 0)
      assert result.agentic.pending_prefix == nil
      assert result.agent.panel.scroll_offset == 1
    end
  end

  describe "[ prefix (prev item)" do
    test "[ sets pending_prefix to :bracket_prev" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?[, 0)
      assert new_state.agentic.pending_prefix == :bracket_prev
    end

    test "[m is handled (stubbed)" do
      state = base_state(focus: :chat)
      {:handled, with_bracket} = Keys.handle_key(state, ?[, 0)
      {:handled, result} = Keys.handle_key(with_bracket, ?m, 0)
      assert result.agentic.pending_prefix == nil
    end
  end

  describe "g prefix extensions" do
    test "gf is handled (stubbed, clears prefix)" do
      state = base_state(focus: :chat)
      {:handled, with_g} = Keys.handle_key(state, ?g, 0)
      {:handled, result} = Keys.handle_key(with_g, ?f, 0)
      assert result.agentic.pending_prefix == nil
    end
  end

  describe "panel resize" do
    test "} grows the chat panel" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?}, 0)
      assert new_state.agentic.chat_width_pct == 70
    end

    test "{ shrinks the chat panel" do
      state = base_state(focus: :chat)
      {:handled, new_state} = Keys.handle_key(state, ?{, 0)
      assert new_state.agentic.chat_width_pct == 60
    end

    test "= resets the panel split" do
      state = base_state(focus: :chat)
      {:handled, grown} = Keys.handle_key(state, ?}, 0)
      {:handled, reset} = Keys.handle_key(grown, ?=, 0)
      assert reset.agentic.chat_width_pct == 65
    end
  end

  describe "sacred vim keys are not repurposed" do
    test "SPC passes through in nav mode" do
      state = base_state(focus: :chat)
      assert {:passthrough, _} = Keys.handle_key(state, ?\s, 0)
    end

    test "SPC is handled (typed) when input is focused" do
      state = base_state(focus: :chat)
      state = put_in(state.agent.panel.input_focused, true)
      {:handled, new_state} = Keys.handle_key(state, ?\s, 0)
      assert new_state.agent.panel.input_text == " "
    end
  end
end
