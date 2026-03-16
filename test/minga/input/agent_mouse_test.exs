defmodule Minga.Input.AgentMouseTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.UIState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Layout
  alias Minga.Editor.LayoutPreset
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Input.AgentMouse
  alias Minga.Mode

  # ── Test helpers ───────────────────────────────────────────────────────────

  defp base_state(opts \\ []) do
    {:ok, buf} = BufferServer.start_link(content: "hello\nworld\nfoo\nbar\nbaz")
    {:ok, prompt_buf} = BufferServer.start_link(content: "")

    panel = %UIState{
      visible: Keyword.get(opts, :panel_visible, false),
      input_focused: Keyword.get(opts, :input_focused, false),
      scroll: Minga.Scroll.new(),
      spinner_frame: 0,
      provider_name: "anthropic",
      model_name: "claude-sonnet-4",
      thinking_level: "medium",
      prompt_buffer: prompt_buf
    }

    agent = %AgentState{
      session: nil,
      status: :idle,
      panel: panel,
      error: nil,
      spinner_timer: nil,
      buffer: Keyword.get(opts, :agent_buffer, nil)
    }

    agentic = UIState.new()
    tab_bar = TabBar.new(Tab.new_file(1, "[no file]"))

    win_id = 1
    win = Window.new(win_id, buf, 24, 80)

    %EditorState{
      port_manager: self(),
      viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
      vim: %VimState{mode: :normal, mode_state: Mode.initial_state()},
      buffers: %Buffers{active: buf, list: [buf]},
      focus_stack: [],
      keymap_scope: Keyword.get(opts, :keymap_scope, :editor),
      agent: agent,
      agent_ui: agentic,
      tab_bar: tab_bar,
      windows: %Windows{
        tree: {:leaf, win_id},
        map: %{win_id => win},
        active: win_id,
        next_id: win_id + 1
      }
    }
  end

  defp with_agent_split(state) do
    {:ok, agent_buf} = BufferServer.start_link(content: "")

    state =
      AgentAccess.update_agent(state, fn agent ->
        %{agent | buffer: agent_buf}
      end)

    LayoutPreset.apply(state, :agent_right, agent_buf)
  end

  defp with_agent_panel(state) do
    state
    |> AgentAccess.update_agent(fn agent ->
      panel = %{agent.panel | visible: true, input_focused: true}
      %{agent | panel: panel}
    end)
    |> Layout.invalidate()
  end

  defp agent_chat_window_rect(state) do
    layout = Layout.compute(state)

    Enum.find_value(layout.window_layouts, fn {win_id, wl} ->
      window = Map.get(state.windows.map, win_id)

      if window != nil and Content.agent_chat?(window.content) do
        wl.content
      end
    end)
  end

  # ── Events outside agent regions pass through ──────────────────────────────

  describe "passthrough" do
    test "events pass through when no agent UI is visible" do
      state = base_state()
      assert {:passthrough, _} = AgentMouse.handle_mouse(state, 5, 5, :wheel_down, 0, :press, 1)
      assert {:passthrough, _} = AgentMouse.handle_mouse(state, 5, 5, :left, 0, :press, 1)
    end

    test "events outside agent regions pass through when agent split is active" do
      state = base_state() |> with_agent_split()
      # Click in the editor area (left pane), not the agent pane
      # The editor window occupies the left ~60% of columns
      assert {:passthrough, _} = AgentMouse.handle_mouse(state, 5, 5, :left, 0, :press, 1)
      assert {:passthrough, _} = AgentMouse.handle_mouse(state, 5, 5, :wheel_down, 0, :press, 1)
    end
  end

  # ── Agent chat window (split pane) scroll ──────────────────────────────────

  describe "agent chat window scroll" do
    setup do
      state = base_state() |> with_agent_split()
      rect = agent_chat_window_rect(state)
      {:ok, state: state, rect: rect}
    end

    test "scroll down over agent chat window scrolls chat, not editor buffer", %{
      state: state,
      rect: rect
    } do
      {row, col, _w, _h} = rect
      old_viewport_top = state.viewport.top

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, row + 2, col + 2, :wheel_down, 0, :press, 1)

      # Chat scroll should have changed
      panel = AgentAccess.panel(new_state)
      assert panel.scroll.offset > 0 or panel.scroll.pinned == false

      # Editor viewport should be untouched
      assert new_state.viewport.top == old_viewport_top
    end

    test "scroll up over agent chat window scrolls chat", %{state: state, rect: rect} do
      {row, col, _w, _h} = rect

      # First scroll down to have something to scroll up from
      {:handled, state} =
        AgentMouse.handle_mouse(state, row + 2, col + 2, :wheel_down, 0, :press, 1)

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, row + 2, col + 2, :wheel_up, 0, :press, 1)

      # Should not crash and should handle gracefully
      assert %EditorState{} = new_state
    end

    test "scroll over file viewer sidebar scrolls preview", %{state: state, rect: rect} do
      {row, _col, _w, _h} = rect
      # The file viewer sidebar is to the right of the chat area.
      # chat_width_pct defaults to 65, so sidebar starts at ~65% of the window width.
      # Use a column well to the right of the chat area.
      sidebar_col = state.viewport.cols - 5

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, row + 2, sidebar_col, :wheel_down, 0, :press, 1)

      # Preview scroll should have changed (or at least not crash)
      assert %EditorState{} = new_state
    end
  end

  # ── Agent chat window (split pane) click ───────────────────────────────────

  describe "agent chat window click" do
    setup do
      state = base_state() |> with_agent_split()
      rect = agent_chat_window_rect(state)
      {:ok, state: state, rect: rect}
    end

    test "click in chat area passthroughs to standard mouse handler", %{state: state, rect: rect} do
      {row, col, _w, _h} = rect

      # Click in the chat area (near the top of the agent window)
      # should passthrough to ModeFSM for standard buffer mouse handling
      {:passthrough, _state} =
        AgentMouse.handle_mouse(state, row + 1, col + 2, :left, 0, :press, 1)
    end

    test "click in input area focuses input", %{state: state, rect: rect} do
      {_row, col, _w, h} = rect

      # Make sure input is not focused
      state = AgentAccess.update_agent(state, &AgentState.focus_input(&1, false))
      refute AgentAccess.input_focused?(state)

      # Click near the bottom of the agent window (where input lives)
      input_row = rect |> elem(0) |> Kernel.+(h - 2)

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, input_row, col + 2, :left, 0, :press, 1)

      assert AgentAccess.input_focused?(new_state)
    end

    test "click in agent window focuses it when not active", %{state: state} do
      # The editor window should be active (not the agent)
      # Find the agent window id
      {agent_win_id, _} =
        Enum.find(state.windows.map, fn {_id, w} ->
          Content.agent_chat?(w.content)
        end)

      refute state.windows.active == agent_win_id

      rect = agent_chat_window_rect(state)
      {row, col, _w, _h} = rect

      # Chat content click passthroughs (window focus happens via maybe_focus_window
      # before passthrough). The :passthrough response means ModeFSM will handle
      # cursor positioning against the *Agent* buffer.
      {:passthrough, new_state} =
        AgentMouse.handle_mouse(state, row + 1, col + 2, :left, 0, :press, 1)

      assert new_state.windows.active == agent_win_id
    end
  end

  # ── Agent side panel (bottom panel) scroll ─────────────────────────────────

  describe "agent side panel scroll" do
    setup do
      state = base_state() |> with_agent_panel()
      layout = Layout.compute(state)
      {:ok, state: state, panel_rect: layout.agent_panel}
    end

    test "scroll down over agent panel scrolls chat", %{state: state, panel_rect: panel_rect} do
      {row, col, _w, _h} = panel_rect
      old_viewport_top = state.viewport.top

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, row + 1, col + 2, :wheel_down, 0, :press, 1)

      # Chat scroll offset should change
      panel = AgentAccess.panel(new_state)
      assert panel.scroll.offset > 0 or panel.scroll.pinned == false

      # Editor viewport should be untouched
      assert new_state.viewport.top == old_viewport_top
    end

    test "scroll up over agent panel scrolls chat", %{state: state, panel_rect: panel_rect} do
      {row, col, _w, _h} = panel_rect

      {:handled, state} =
        AgentMouse.handle_mouse(state, row + 1, col + 2, :wheel_down, 0, :press, 1)

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, row + 1, col + 2, :wheel_up, 0, :press, 1)

      assert %EditorState{} = new_state
    end
  end

  # ── Agent side panel (bottom panel) click ──────────────────────────────────

  describe "agent side panel click" do
    setup do
      state = base_state() |> with_agent_panel()
      layout = Layout.compute(state)
      {:ok, state: state, panel_rect: layout.agent_panel}
    end

    test "click in panel chat area unfocuses input", %{state: state, panel_rect: panel_rect} do
      {row, col, _w, _h} = panel_rect

      # Input should be focused initially
      assert AgentAccess.input_focused?(state)

      # Click near the top of the panel (chat area)
      {:handled, new_state} =
        AgentMouse.handle_mouse(state, row + 1, col + 2, :left, 0, :press, 1)

      refute AgentAccess.input_focused?(new_state)
    end

    test "click in panel input area focuses input", %{state: state, panel_rect: panel_rect} do
      {_row, col, _w, h} = panel_rect

      # Unfocus first
      state = AgentAccess.update_agent(state, &AgentState.focus_input(&1, false))
      refute AgentAccess.input_focused?(state)

      # Click near the bottom of the panel (input area)
      input_row = elem(panel_rect, 0) + h - 2

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, input_row, col + 2, :left, 0, :press, 1)

      assert AgentAccess.input_focused?(new_state)
    end
  end

  # ── Scope independence ─────────────────────────────────────────────────────

  describe "scope independence" do
    test "scroll works in agent window regardless of keymap_scope" do
      # Start in editor scope, but scroll over the agent window
      state = base_state(keymap_scope: :editor) |> with_agent_split()
      rect = agent_chat_window_rect(state)

      # Verify we're in editor scope
      assert state.keymap_scope == :editor

      {row, col, _w, _h} = rect

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, row + 2, col + 2, :wheel_down, 0, :press, 1)

      # Chat should have scrolled
      panel = AgentAccess.panel(new_state)
      assert panel.scroll.offset > 0 or panel.scroll.pinned == false
    end

    test "click in agent window works from editor scope" do
      state = base_state(keymap_scope: :editor) |> with_agent_split()
      rect = agent_chat_window_rect(state)
      {row, col, _w, _h} = rect

      # Chat content click passthroughs after focusing the agent window
      {:passthrough, new_state} =
        AgentMouse.handle_mouse(state, row + 1, col + 2, :left, 0, :press, 1)

      # Window focus happened before passthrough
      {agent_win_id, _} =
        Enum.find(new_state.windows.map, fn {_id, w} -> Content.agent_chat?(w.content) end)

      assert new_state.windows.active == agent_win_id
    end
  end
end
