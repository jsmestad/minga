defmodule Minga.Agent.View.MouseTest do
  @moduledoc "Tests for agentic view mouse interactions."
  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Agent.View.Mouse
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Mouse, as: MouseState
  alias Minga.Editor.Viewport

  # Build a minimal editor state that looks like an active agentic view.
  defp agentic_state(opts \\ []) do
    chat_width_pct = Keyword.get(opts, :chat_width_pct, 50)
    input_focused = Keyword.get(opts, :input_focused, false)
    focus = Keyword.get(opts, :focus, :chat)

    %EditorState{
      port_manager: nil,
      mode: :normal,
      mode_state: Minga.Mode.initial_state(),
      viewport: %Viewport{rows: 30, cols: 80, top: 0, left: 0},
      agentic: %ViewState{
        active: true,
        focus: focus,
        chat_width_pct: chat_width_pct
      },
      agent: %AgentState{
        panel: %PanelState{
          visible: false,
          input_lines: [""],
          input_focused: input_focused
        }
      },
      mouse: %MouseState{},
      buffers: %{active: nil, list: [], active_index: 0}
    }
  end

  describe "scroll wheel in chat panel" do
    test "wheel_down in chat region scrolls chat down" do
      state = agentic_state()
      # Chat region is cols 0..39 (50% of 80), rows 1..24 (panel area)
      new_state = Mouse.handle(state, 5, 10, :wheel_down, 0, :press, 1)
      # Agent scroll_offset should increase
      assert new_state != state
    end

    test "wheel_up in chat region scrolls chat up" do
      state = agentic_state()
      # First scroll down, then up
      state = Mouse.handle(state, 5, 10, :wheel_down, 0, :press, 1)
      new_state = Mouse.handle(state, 5, 10, :wheel_up, 0, :press, 1)
      assert new_state != state
    end
  end

  describe "scroll wheel in file viewer" do
    test "wheel_down in file viewer region scrolls viewer down" do
      state = agentic_state()
      # File viewer is at cols 41..79 (right of separator at col 40)
      new_state = Mouse.handle(state, 5, 50, :wheel_down, 0, :press, 1)
      assert new_state != state
    end
  end

  describe "click to focus" do
    test "clicking chat panel focuses it" do
      state = agentic_state(focus: :file_viewer)
      new_state = Mouse.handle(state, 5, 10, :left, 0, :press, 1)
      assert new_state.agentic.focus == :chat
    end

    test "clicking file viewer panel focuses it" do
      state = agentic_state(focus: :chat)
      new_state = Mouse.handle(state, 5, 50, :left, 0, :press, 1)
      assert new_state.agentic.focus == :file_viewer
    end

    test "clicking input area focuses input" do
      state = agentic_state()
      # Input area starts at panel_end. With rows=30, input_height=3,
      # panel_end = 30 - 1 - 1 - 3 = 25, so input_row = 25
      new_state = Mouse.handle(state, 25, 10, :left, 0, :press, 1)
      assert new_state.agent.panel.input_focused == true
    end

    test "clicking chat unfocuses input" do
      state = agentic_state(input_focused: true)
      new_state = Mouse.handle(state, 5, 10, :left, 0, :press, 1)
      assert new_state.agent.panel.input_focused == false
    end
  end

  describe "separator drag" do
    test "clicking separator starts resize drag" do
      state = agentic_state()
      # Separator is at col = 50% of 80 = 40
      new_state = Mouse.handle(state, 5, 40, :left, 0, :press, 1)
      assert new_state.mouse.resize_dragging == {:agent_separator, 40}
    end

    test "dragging separator changes chat_width_pct" do
      state = agentic_state()
      # Start drag at separator
      state = Mouse.handle(state, 5, 40, :left, 0, :press, 1)
      # Drag to col 60 (75% of 80)
      new_state = Mouse.handle(state, 5, 60, :left, 0, :drag, 1)
      assert new_state.agentic.chat_width_pct == 75
    end

    test "separator drag clamps to 30-80% range" do
      state = agentic_state()
      state = Mouse.handle(state, 5, 40, :left, 0, :press, 1)
      # Try to drag to col 5 (6.25%) - should clamp to 30%
      new_state = Mouse.handle(state, 5, 5, :left, 0, :drag, 1)
      assert new_state.agentic.chat_width_pct == 30
    end

    test "releasing after drag stops resize" do
      state = agentic_state()
      state = Mouse.handle(state, 5, 40, :left, 0, :press, 1)
      state = Mouse.handle(state, 5, 50, :left, 0, :drag, 1)
      new_state = Mouse.handle(state, 5, 50, :left, 0, :release, 1)
      assert new_state.mouse.resize_dragging == nil
    end
  end

  describe "edge cases" do
    test "negative row is ignored" do
      state = agentic_state()
      assert Mouse.handle(state, -1, 10, :left, 0, :press, 1) == state
    end

    test "negative col is ignored" do
      state = agentic_state()
      assert Mouse.handle(state, 5, -1, :left, 0, :press, 1) == state
    end

    test "unknown button is ignored" do
      state = agentic_state()
      assert Mouse.handle(state, 5, 10, :right, 0, :press, 1) == state
    end
  end
end
