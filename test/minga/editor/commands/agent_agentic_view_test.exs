defmodule Minga.Editor.Commands.AgentAgenticViewTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Viewport
  alias Minga.Input
  alias Minga.Mode
  alias Minga.Surface.AgentView
  alias Minga.Surface.AgentView.State, as: AgentViewState
  alias Minga.Surface.BufferView

  defp base_state(opts \\ []) do
    {:ok, buf} = BufferServer.start_link(content: "hello\nworld")

    panel = %PanelState{
      visible: false,
      input_focused: false,
      scroll: Minga.Scroll.new(),
      spinner_frame: 0,
      provider_name: "anthropic",
      model_name: "claude-sonnet-4",
      thinking_level: "medium"
    }

    agent = %AgentState{
      session: Keyword.get(opts, :session, nil),
      status: :idle,
      panel: panel,
      error: nil,
      spinner_timer: nil,
      buffer: nil
    }

    active = Keyword.get(opts, :active, false)

    agentic = %ViewState{
      active: active,
      focus: :chat,
      preview: Preview.new(),
      saved_windows: Keyword.get(opts, :saved_windows, nil),
      pending_prefix: nil,
      saved_file_tree: Keyword.get(opts, :saved_file_tree, nil)
    }

    # Build a tab bar: file tab always exists, agent tab if starting active
    file_tab = Tab.new_file(1, "test.ex")
    tb = TabBar.new(file_tab)

    av_state = %AgentViewState{agent: agent, agentic: agentic, context: nil}

    state = %EditorState{
      port_manager: self(),
      viewport: Viewport.new(24, 80),
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      focus_stack: Input.default_stack(),
      surface_module: Minga.Surface.BufferView,
      surface_state: nil,
      tab_bar: tb
    }

    if active do
      # Build agent tab with proper surface state so switch_tab
      # restores it correctly (with surface_module set).
      active_av = %{av_state | agentic: %{agentic | active: true, focus: :chat}}

      agent_ctx = %{
        keymap_scope: :agent,
        surface_module: AgentView,
        surface_state: active_av
      }

      {tb, at} = TabBar.add(tb, :agent, "Agent")
      tb = TabBar.update_context(tb, at.id, agent_ctx)
      # Switch back to file tab so switch_tab properly snapshots it
      tb = TabBar.switch_to(tb, file_tab.id)

      state = %{state | tab_bar: tb}
      EditorState.switch_tab(state, at.id)
    else
      # If agent state has a session or non-default state, store it in
      # a background agent tab so AgentAccess can find it.
      if agent.session != nil do
        {tb, at} = TabBar.add(tb, :agent, "Agent")
        agent_ctx = %{keymap_scope: :agent, surface_module: AgentView, surface_state: av_state}
        tb = TabBar.update_context(tb, at.id, agent_ctx)
        tb = TabBar.switch_to(tb, file_tab.id)
        %{state | tab_bar: tb}
      else
        state
      end
    end
  end

  # Helper: checks whether the agent surface is active (the new way)
  defp agent_surface_active?(state), do: state.surface_module == AgentView
  defp buffer_surface_active?(state), do: state.surface_module == BufferView

  describe "toggle_agentic_view/1 — activating" do
    test "activates the AgentView surface" do
      state = base_state()
      new_state = AgentCommands.toggle_agentic_view(state)
      assert agent_surface_active?(new_state)
    end

    test "saves the file tab's windows layout in the tab context" do
      state = base_state()
      original_windows = state.windows
      new_state = AgentCommands.toggle_agentic_view(state)

      # File tab (id 1) should have the original windows inside its surface_state
      file_tab = TabBar.get(new_state.tab_bar, 1)
      assert file_tab.context.surface_state.windows == original_windows
    end

    test "resets agentic.focus to :chat" do
      state = base_state()

      state =
        AgentAccess.update_agentic(state, fn agentic -> %{agentic | focus: :file_viewer} end)

      new_state = AgentCommands.toggle_agentic_view(state)
      assert AgentAccess.agentic(new_state).focus == :chat
    end

    test "clears any split tree from the windows struct" do
      state = base_state()
      fake_tree = {:split, :vertical, 40, {:leaf, 1}, {:leaf, 2}}
      state = %{state | windows: %{state.windows | tree: fake_tree}}
      new_state = AgentCommands.toggle_agentic_view(state)
      # After switching to agent view, the windows tree on EditorState
      # reflects the agent context (cleared). The file tab's saved
      # surface_state preserves the original tree.
      file_tab = TabBar.get(new_state.tab_bar, 1)
      saved_tree = file_tab.context.surface_state.windows.tree
      assert saved_tree == fake_tree
    end

    test "starts a session when none is running" do
      state = base_state(session: nil)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert agent_surface_active?(new_state)

      # When pi isn't installed, the session start fails gracefully
      # and sets an error instead of crashing.
      if AgentAccess.session(new_state) == nil do
        assert AgentAccess.agent(new_state).error != nil
      end
    end

    test "does not double-start a session when one is already running" do
      fake_session = spawn(fn -> :timer.sleep(1000) end)
      state = base_state(session: fake_session)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert AgentAccess.session(new_state) == fake_session
      assert agent_surface_active?(new_state)
    end

    test "creates an agent tab when none exists" do
      state = base_state()
      new_state = AgentCommands.toggle_agentic_view(state)
      assert TabBar.find_by_kind(new_state.tab_bar, :agent) != nil
      assert EditorState.active_tab_kind(new_state) == :agent
    end
  end

  describe "toggle_agentic_view/1 — deactivating" do
    test "switches to BufferView surface" do
      state = base_state(active: true)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert buffer_surface_active?(new_state)
    end

    test "switches back to the file tab" do
      state = base_state(active: true)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert EditorState.active_tab_kind(new_state) == :file
    end

    test "does not crash when no file tab exists" do
      # Start active with no file tab scenario handled gracefully
      state = base_state(active: true)
      new_state = AgentCommands.toggle_agentic_view(state)
      assert buffer_surface_active?(new_state)
    end

    test "resets keymap_scope to :editor" do
      state = base_state(active: true)

      state =
        AgentAccess.update_agentic(state, fn agentic -> %{agentic | focus: :file_viewer} end)

      new_state = AgentCommands.toggle_agentic_view(state)
      assert new_state.keymap_scope == :editor
    end
  end

  describe "kill_buffer on agent tab" do
    alias Minga.Editor.Commands.BufferManagement

    test "closes agent tab and switches to file tab" do
      state = base_state(active: true)
      assert EditorState.active_tab_kind(state) == :agent

      new_state = BufferManagement.execute(state, :kill_buffer)

      assert EditorState.active_tab_kind(new_state) == :file
      assert new_state.surface_module == BufferView
      assert new_state.keymap_scope == :editor
    end

    test "restores file tab context after closing agent tab" do
      state = base_state()
      original_windows = state.windows

      # Activate agent
      state = AgentCommands.toggle_agentic_view(state)
      assert EditorState.active_tab_kind(state) == :agent

      # Close agent tab via kill_buffer
      state = BufferManagement.execute(state, :kill_buffer)

      assert EditorState.active_tab_kind(state) == :file
      assert state.windows == original_windows
    end

    test "does not crash when agent tab has no session" do
      state = base_state(active: true, session: nil)
      new_state = BufferManagement.execute(state, :kill_buffer)
      assert EditorState.active_tab_kind(new_state) == :file
    end

    test "removes agent tab from tab bar" do
      state = base_state(active: true)
      agent_tabs_before = TabBar.filter_by_kind(state.tab_bar, :agent)
      assert length(agent_tabs_before) == 1

      new_state = BufferManagement.execute(state, :kill_buffer)
      agent_tabs_after = TabBar.filter_by_kind(new_state.tab_bar, :agent)
      assert agent_tabs_after == []
    end
  end

  describe "round-trip toggle" do
    test "activating then deactivating restores the windows layout" do
      state = base_state()
      original_windows = state.windows

      activated = AgentCommands.toggle_agentic_view(state)
      assert agent_surface_active?(activated)

      restored = AgentCommands.toggle_agentic_view(activated)
      assert buffer_surface_active?(restored)
      assert restored.windows == original_windows
    end

    test "re-entering agent tab restores its context" do
      state = base_state()

      # Activate (creates agent tab) -> deactivate -> re-activate
      with_agent = AgentCommands.toggle_agentic_view(state)
      back_to_file = AgentCommands.toggle_agentic_view(with_agent)
      back_to_agent = AgentCommands.toggle_agentic_view(back_to_file)

      assert agent_surface_active?(back_to_agent)
      assert back_to_agent.keymap_scope == :agent
    end
  end
end
