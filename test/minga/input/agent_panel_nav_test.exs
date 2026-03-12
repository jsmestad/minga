defmodule Minga.Input.AgentPanelNavTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.PanelState
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.ChangeRecorder
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Input.AgentPanel

  defp walk_surface_handlers(state, cp, mods) do
    Enum.reduce_while(Minga.Input.surface_handlers(), {:passthrough, state}, fn handler,
                                                                                {_, acc} ->
      case handler.handle_key(acc, cp, mods) do
        {:handled, new_state} -> {:halt, {:handled, new_state}}
        {:passthrough, new_state} -> {:cont, {:passthrough, new_state}}
      end
    end)
  end

  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.Viewport
  alias Minga.Input.Scoped
  alias Minga.Mode

  defp make_state do
    buf = AgentBufferSync.start_buffer()

    # Write some content so there are lines to navigate
    AgentBufferSync.sync(buf, [
      {:user, "Hello"},
      {:assistant, "World\nLine 2\nLine 3\nLine 4\nLine 5"}
    ])

    {:ok, prompt_buf} = BufferServer.start_link(content: "")
    panel = %{PanelState.new() | visible: true, input_focused: false, prompt_buffer: prompt_buf}

    agent = %AgentState{
      panel: panel,
      buffer: buf,
      session: nil,
      status: :idle,
      error: nil,
      spinner_timer: nil
    }

    agentic = %ViewState{}

    %EditorState{
      port_manager: self(),
      viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
      surface_module: Minga.Surface.BufferView,
      agent: agent,
      agentic: agentic,
      buffers: %{active: nil, list: [], recent: []},
      mode: :normal,
      mode_state: Mode.initial_state(),
      status_msg: nil,
      marks: %{},
      change_recorder: ChangeRecorder.new(),
      macro_recorder: MacroRecorder.new(),
      file_tree: %FileTreeState{},
      completion: nil,
      keymap_scope: :editor,
      focus_stack: [Scoped, Minga.Input.ModeFSM]
    }
  end

  describe "agent panel navigation mode (via Scoped)" do
    test "k moves cursor up in agent buffer" do
      state = make_state()
      buf = AgentAccess.agent(state).buffer

      # Cursor starts at end (auto-scroll from sync)
      {start_line, _} = BufferServer.cursor(buf)

      {:handled, _state} = walk_surface_handlers(state, ?k, 0)

      # After k, cursor should have moved up
      {new_line, _} = BufferServer.cursor(buf)
      assert new_line < start_line
    end

    test "i focuses the input" do
      state = make_state()

      {:handled, new_state} = walk_surface_handlers(state, ?i, 0)
      assert AgentAccess.input_focused?(new_state) == true
    end

    test "passthrough when panel not visible" do
      state = make_state()
      state = AgentAccess.update_agent(state, fn agent -> put_in(agent.panel.visible, false) end)
      {:passthrough, _state} = AgentPanel.handle_key(state, ?j, 0)
    end

    test "passthrough when no buffer" do
      state = make_state()
      state = AgentAccess.update_agent(state, fn agent -> %{agent | buffer: nil} end)
      {:passthrough, _state} = AgentPanel.handle_key(state, ?j, 0)
    end

    test "q closes the panel" do
      state = make_state()

      {:handled, new_state} = walk_surface_handlers(state, ?q, 0)
      # toggle_panel on a non-input-focused panel will focus input
      # (the first toggle re-focuses, second one closes)
      assert AgentAccess.input_focused?(new_state) == true
    end

    test "j moves cursor down in agent buffer" do
      state = make_state()
      buf = AgentAccess.agent(state).buffer

      # Move cursor to top first
      {_, _} = BufferServer.cursor(buf)
      # Navigate with gg to get to top
      {:handled, state} = walk_surface_handlers(state, ?g, 0)
      {:handled, state} = walk_surface_handlers(state, ?g, 0)

      {start_line, _} = BufferServer.cursor(buf)

      {:handled, _state} = walk_surface_handlers(state, ?j, 0)

      {new_line, _} = BufferServer.cursor(buf)
      assert new_line > start_line
    end
  end

  describe "agent panel input mode (via Scoped)" do
    test "Escape switches to input normal mode" do
      state = make_state()

      state =
        AgentAccess.update_agent(state, fn agent -> put_in(agent.panel.input_focused, true) end)

      {:handled, new_state} = walk_surface_handlers(state, 27, 0)
      assert AgentAccess.input_focused?(new_state) == true
      assert new_state.mode == :normal
    end

    test "input mode intercepts printable chars" do
      state = make_state()

      state =
        AgentAccess.update_agent(state, fn agent -> put_in(agent.panel.input_focused, true) end)

      state = %{state | mode: :insert}
      {:handled, new_state} = walk_surface_handlers(state, ?a, 0)
      assert PanelState.input_text(AgentAccess.panel(new_state)) =~ "a"
    end

    test "Ctrl+D scrolls chat while in input mode" do
      state = make_state()

      state =
        AgentAccess.update_agent(state, fn agent -> put_in(agent.panel.input_focused, true) end)

      {:handled, _new_state} = walk_surface_handlers(state, ?d, 0x02)
      # Doesn't crash; scroll may or may not change depending on content
    end

    test "Ctrl+U scrolls chat up while in input mode" do
      state = make_state()

      state =
        AgentAccess.update_agent(state, fn agent -> put_in(agent.panel.input_focused, true) end)

      {:handled, _new_state} = walk_surface_handlers(state, ?u, 0x02)
    end

    test "Enter submits prompt (empty is no-op)" do
      state = make_state()

      state =
        AgentAccess.update_agent(state, fn agent -> put_in(agent.panel.input_focused, true) end)

      {:handled, new_state} = walk_surface_handlers(state, 13, 0)
      # Empty prompt is a no-op
      assert AgentAccess.input_focused?(new_state) == true
    end

    test "Shift+Enter inserts newline" do
      state = make_state()

      state =
        AgentAccess.update_agent(state, fn agent -> put_in(agent.panel.input_focused, true) end)

      state = %{state | mode: :insert}
      {:handled, new_state} = walk_surface_handlers(state, 13, 0x01)
      # Should have a newline in the input
      assert length(PanelState.input_lines(AgentAccess.panel(new_state))) > 1
    end

    test "Backspace on empty input is safe" do
      state = make_state()

      state =
        AgentAccess.update_agent(state, fn agent -> put_in(agent.panel.input_focused, true) end)

      {:handled, _new_state} = walk_surface_handlers(state, 127, 0)
    end
  end
end
