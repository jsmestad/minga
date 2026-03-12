defmodule Minga.Editor.Commands.AgentCommandsTest do
  @moduledoc """
  Characterization tests for Commands.Agent.

  Tests pure `state -> state` functions for agent-related commands.
  Agent state now lives on EditorState (agent panel, session, status).

  Functions that require a live Agent.Session (submit_prompt, abort_agent,
  clear_chat_display, etc.) are tested via EditorCase integration tests
  in a separate file.
  """

  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Input
  alias Minga.Mode
  alias Minga.Scroll

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp base_state(opts \\ []) do
    {:ok, buf} = BufferServer.start_link(content: Keyword.get(opts, :content, "hello\nworld"))

    {:ok, prompt_buf} = BufferServer.start_link(content: "")

    panel = %PanelState{
      visible: Keyword.get(opts, :panel_visible, false),
      input_focused: Keyword.get(opts, :input_focused, false),
      prompt_buffer: prompt_buf,
      scroll: Scroll.new(),
      spinner_frame: 0,
      provider_name: "anthropic",
      model_name: "claude-sonnet-4",
      thinking_level: "medium"
    }

    agent = %AgentState{
      panel: panel,
      session: Keyword.get(opts, :session, nil),
      buffer: Keyword.get(opts, :agent_buffer, nil)
    }

    agentic = %ViewState{}

    file_tab = Tab.new_file(1, "test.ex")
    tb = TabBar.new(file_tab)

    %EditorState{
      port_manager: nil,
      viewport: Viewport.new(24, 80),
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      windows: %Windows{
        tree: {:leaf, 1},
        map: %{1 => Window.new(1, buf, 24, 80)},
        active: 1,
        next_id: 2
      },
      agent: agent,
      agentic: agentic,
      tab_bar: tb,
      focus_stack: Input.default_stack()
    }
  end

  # ── toggle_panel ─────────────────────────────────────────────────────────

  describe "toggle_panel/1" do
    test "opens the panel when closed" do
      state = base_state(panel_visible: false, active_agent: false)
      new_state = AgentCommands.toggle_panel(state)

      assert AgentAccess.panel(new_state).visible == true
    end

    test "focuses input when opening the panel" do
      state = base_state(panel_visible: false, active_agent: false)
      new_state = AgentCommands.toggle_panel(state)

      assert AgentAccess.input_focused?(new_state) == true
    end

    test "closes the panel when visible and input is focused" do
      state = base_state(panel_visible: true, input_focused: true)
      new_state = AgentCommands.toggle_panel(state)

      assert AgentAccess.panel(new_state).visible == false
    end

    test "focuses input when panel is visible but input is not focused" do
      state = base_state(panel_visible: true, input_focused: false)
      new_state = AgentCommands.toggle_panel(state)

      # Should focus input, not close
      assert AgentAccess.panel(new_state).visible == true
      assert AgentAccess.input_focused?(new_state) == true
    end

    test "invalidates layout when toggling" do
      state = base_state(panel_visible: false, active_agent: false)
      state = %{state | layout: :some_cached_layout}
      new_state = AgentCommands.toggle_panel(state)

      assert new_state.layout == nil
    end
  end

  # ── submit_prompt ────────────────────────────────────────────────────────

  describe "submit_prompt/1" do
    test "no-ops on empty input" do
      state = base_state()
      assert AgentCommands.submit_prompt(state) == state
    end

    test "sets error status when no session exists" do
      state = base_state(session: nil)

      state =
        AgentAccess.update_agent(state, fn agent ->
          panel = PanelState.ensure_prompt_buffer(agent.panel)
          BufferServer.replace_content(panel.prompt_buffer, "hello agent")
          %{agent | panel: panel}
        end)

      new_state = AgentCommands.submit_prompt(state)

      assert new_state.status_msg =~ "No agent session"
    end
  end

  # ── scroll_chat ──────────────────────────────────────────────────────────

  describe "scroll_chat_up/1 and scroll_chat_down/1" do
    test "no-ops when panel is hidden and agentic view is inactive" do
      state = base_state(panel_visible: false, active_agent: false)
      assert AgentCommands.scroll_chat_up(state) == state
      assert AgentCommands.scroll_chat_down(state) == state
    end

    test "scrolls when panel is visible" do
      state = base_state(panel_visible: true)
      new_state = AgentCommands.scroll_chat_up(state)

      # Scroll offset should change (exact value depends on panel height)
      assert AgentAccess.panel(new_state).scroll != AgentAccess.panel(state).scroll
    end
  end

  # ── input_char / input_backspace / input_paste ───────────────────────────

  describe "input_char/2" do
    test "no-ops when panel is hidden and agentic view is inactive" do
      state = base_state(panel_visible: false, active_agent: false)
      assert AgentCommands.input_char(state, "a") == state
    end

    test "inserts character when panel is visible" do
      state = base_state(panel_visible: true, input_focused: true)
      new_state = AgentCommands.input_char(state, "a")

      assert PanelState.input_text(AgentAccess.panel(new_state)) == "a"
    end

    test "inserts multiple characters sequentially" do
      state = base_state(panel_visible: true, input_focused: true)

      state =
        state
        |> AgentCommands.input_char("h")
        |> AgentCommands.input_char("i")

      assert PanelState.input_text(AgentAccess.panel(state)) == "hi"
    end
  end

  describe "input_backspace/1" do
    test "no-ops when panel is hidden and agentic view is inactive" do
      state = base_state(panel_visible: false, active_agent: false)
      assert AgentCommands.input_backspace(state) == state
    end

    test "deletes last character when panel is visible" do
      state = base_state(panel_visible: true, input_focused: true)

      state =
        state
        |> AgentCommands.input_char("a")
        |> AgentCommands.input_char("b")
        |> AgentCommands.input_backspace()

      assert PanelState.input_text(AgentAccess.panel(state)) == "a"
    end
  end

  describe "input_paste/2" do
    test "no-ops when panel is hidden and agentic view is inactive" do
      state = base_state(panel_visible: false, active_agent: false)
      assert AgentCommands.input_paste(state, "pasted text") == state
    end

    test "inserts pasted text when panel is visible" do
      state = base_state(panel_visible: true, input_focused: true)
      new_state = AgentCommands.input_paste(state, "pasted")

      text = PanelState.input_text(AgentAccess.panel(new_state))
      assert text =~ "pasted"
    end
  end

  # ── abort_agent ──────────────────────────────────────────────────────────

  describe "abort_agent/1" do
    test "no-ops when no session exists" do
      state = base_state(session: nil)
      assert AgentCommands.abort_agent(state) == state
    end
  end

  # ── ensure_agent_session ─────────────────────────────────────────────────

  describe "ensure_agent_session/1" do
    test "no-ops when session already exists" do
      fake_pid = spawn(fn -> :timer.sleep(:infinity) end)
      state = base_state(session: fake_pid)
      assert AgentCommands.ensure_agent_session(state) == state
    end
  end

  # ── cycle_thinking_level ─────────────────────────────────────────────────

  describe "cycle_thinking_level/1" do
    test "sets status message when no session exists" do
      state = base_state(session: nil)
      new_state = AgentCommands.cycle_thinking_level(state)

      assert new_state.status_msg =~ "No agent session"
    end
  end

  # ── scope_* guard functions ──────────────────────────────────────────────
  # These functions guard on agentic/panel state. Test the guard behavior.

  describe "scope_focus_input/1" do
    test "focuses the panel input" do
      state = base_state(panel_visible: true, input_focused: false)
      new_state = AgentCommands.scope_focus_input(state)

      assert AgentAccess.input_focused?(new_state) == true
    end
  end

  describe "scope_switch_focus/1" do
    test "switches from chat to file_viewer" do
      state = base_state(panel_visible: true)

      state =
        AgentAccess.update_agentic(state, fn agentic ->
          %{agentic | active: true, focus: :chat}
        end)

      new_state = AgentCommands.scope_switch_focus(state)

      assert AgentAccess.agentic(new_state).focus == :file_viewer
    end

    test "switches from non-chat back to chat" do
      state = base_state(panel_visible: true)

      state =
        AgentAccess.update_agentic(state, fn agentic ->
          %{agentic | active: true, focus: :file_viewer}
        end)

      new_state = AgentCommands.scope_switch_focus(state)

      assert AgentAccess.agentic(new_state).focus == :chat
    end
  end

  # ── toggle_paste_expand ──────────────────────────────────────────────────

  describe "toggle_paste_expand/1" do
    test "does not crash on empty input" do
      state = base_state(panel_visible: true, input_focused: true)
      new_state = AgentCommands.toggle_paste_expand(state)

      # Should not crash, input stays the same
      assert PanelState.input_text(AgentAccess.panel(new_state)) == ""
    end
  end

  # ── new_agent_session ────────────────────────────────────────────────────

  describe "new_agent_session/1" do
    test "resets agent state for a fresh session" do
      state = base_state()
      # Set some agent state
      state = AgentAccess.update_agent(state, fn a -> %{a | error: "old error"} end)

      new_state = AgentCommands.new_agent_session(state)

      # Error should be cleared
      assert AgentAccess.agent(new_state).error == nil
    end

    test "preserves the agent buffer across reset" do
      {:ok, agent_buf} = BufferServer.start_link(content: "old chat")
      state = base_state(agent_buffer: agent_buf)

      new_state = AgentCommands.new_agent_session(state)

      # Buffer should be preserved across session reset
      assert AgentAccess.agent(new_state).buffer == agent_buf
    end
  end

  # ── cycle_agent_tabs ─────────────────────────────────────────────────────

  describe "cycle_agent_tabs/1" do
    test "creates an agent tab when none exist" do
      state = base_state()
      new_state = AgentCommands.cycle_agent_tabs(state)

      agent_tabs = TabBar.filter_by_kind(new_state.tab_bar, :agent)
      assert agent_tabs != []
    end
  end
end
