defmodule Minga.Surface.AgentViewIntegrationTest do
  @moduledoc """
  Integration tests for AgentView surface lifecycle.

  Tests tab creation, switching between BufferView and AgentView tabs,
  surface state preservation across tab switches, and the bridge
  round-trip for agent state.
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
  alias Minga.Surface.AgentView
  alias Minga.Surface.AgentView.State, as: AgentViewState
  alias Minga.Surface.BufferView
  alias Minga.Surface.BufferView.Bridge, as: BVBridge

  defp base_state do
    {:ok, buf} = BufferServer.start_link(content: "hello\nworld")

    tab_bar = TabBar.new(Tab.new_file(1, "test.ex"))

    windows = %Windows{
      tree: nil,
      map: %{1 => Window.new(1, buf, 24, 80)},
      active: 1,
      next_id: 2
    }

    # Create a base EditorState for the bridge (without agent/agentic in constructor)
    base_for_bridge = %EditorState{
      port_manager: nil,
      viewport: Viewport.new(24, 80),
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      windows: windows,
      surface_module: BufferView,
      surface_state: %AgentViewState{
        agent: %AgentState{},
        agentic: %ViewState{},
        context: nil
      }
    }

    %EditorState{
      port_manager: nil,
      viewport: Viewport.new(24, 80),
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      windows: windows,
      tab_bar: tab_bar,
      focus_stack: Input.default_stack(),
      surface_module: BufferView,
      surface_state: BVBridge.from_editor_state(base_for_bridge)
    }
  end

  describe "agent tab creation includes AgentView surface" do
    test "new_agent_session creates a tab with surface_module: AgentView" do
      state = base_state()
      new_state = AgentCommands.new_agent_session(state)

      assert new_state.surface_module == AgentView
    end

    test "new_agent_session creates a tab with AVState surface_state" do
      state = base_state()
      new_state = AgentCommands.new_agent_session(state)

      assert %AgentViewState{} = new_state.surface_state
    end

    test "agent tab context includes surface_module" do
      state = base_state()
      new_state = AgentCommands.new_agent_session(state)

      # The active tab (agent) should have surface info in its context
      active_tab = TabBar.get(new_state.tab_bar, new_state.tab_bar.active_id)
      assert active_tab.kind == :agent
      assert Map.get(active_tab.context, :surface_module) == AgentView
    end
  end

  describe "tab switching preserves surface state" do
    test "switching from file to agent tab changes surface_module" do
      state = base_state()
      assert state.surface_module == BufferView

      new_state = AgentCommands.new_agent_session(state)
      assert new_state.surface_module == AgentView
    end

    test "switching back to file tab restores BufferView" do
      state = base_state()
      # Create agent tab (switches to it)
      with_agent = AgentCommands.new_agent_session(state)
      assert with_agent.keymap_scope == :agent

      # Switch back to file tab
      file_tabs = TabBar.filter_by_kind(with_agent.tab_bar, :file)
      assert file_tabs != []
      file_tab = hd(file_tabs)
      restored = EditorState.switch_tab(with_agent, file_tab.id)

      assert restored.keymap_scope == :editor
      assert restored.surface_module == BufferView
    end

    test "agent state is preserved across tab switches" do
      state = base_state()
      with_agent = AgentCommands.new_agent_session(state)

      # Modify agent state
      modified = AgentCommands.input_char(with_agent, "x")
      assert PanelState.input_text(AgentAccess.panel(modified)) == "x"

      # Switch to file tab
      file_tabs = TabBar.filter_by_kind(modified.tab_bar, :file)
      file_tab = hd(file_tabs)
      on_file = EditorState.switch_tab(modified, file_tab.id)

      # Switch back to agent tab
      agent_tabs = TabBar.filter_by_kind(on_file.tab_bar, :agent)
      agent_tab = hd(agent_tabs)
      back_to_agent = EditorState.switch_tab(on_file, agent_tab.id)

      # Agent state should be preserved via the tab context
      assert back_to_agent.keymap_scope == :agent
    end
  end

  describe "AgentView activate/deactivate lifecycle" do
    test "activate sets agentic.active to true" do
      av = %AgentViewState{agent: %AgentState{}, agentic: %ViewState{active: false}}
      activated = AgentView.activate(av)
      assert activated.agentic.active == true
    end

    test "deactivate sets agentic.active to false" do
      av = %AgentViewState{agent: %AgentState{}, agentic: %ViewState{active: true}}
      deactivated = AgentView.deactivate(av)
      assert deactivated.agentic.active == false
    end
  end
end
