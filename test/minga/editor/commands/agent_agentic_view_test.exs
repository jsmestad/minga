defmodule Minga.Editor.Commands.AgentAgenticViewTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.BufferSync
  alias Minga.Agent.PanelState
  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.LayoutPreset
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Input
  alias Minga.Mode

  defp base_state(opts \\ []) do
    {:ok, buf} = BufferServer.start_link(content: "hello\nworld")
    {:ok, prompt_buf} = BufferServer.start_link(content: "")

    # Create agent buffer (needed for split pane behavior)
    agent_buf = BufferSync.start_buffer()

    panel = %PanelState{
      visible: false,
      input_focused: false,
      scroll: Minga.Scroll.new(),
      spinner_frame: 0,
      provider_name: "anthropic",
      model_name: "claude-sonnet-4",
      thinking_level: "medium",
      prompt_buffer: prompt_buf
    }

    agent = %AgentState{
      session: Keyword.get(opts, :session, nil),
      status: :idle,
      panel: panel,
      error: nil,
      spinner_timer: nil,
      buffer: agent_buf
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

    # Create a proper window for the buffer
    window = Window.new(1, buf, 24, 80)

    state = %EditorState{
      port_manager: self(),
      viewport: Viewport.new(24, 80),
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      focus_stack: Input.default_stack(),
      agent: agent,
      agentic: agentic,
      tab_bar: tb,
      windows: %Minga.Editor.State.Windows{
        tree: {:leaf, 1},
        map: %{1 => window},
        active: 1,
        next_id: 2
      }
    }

    if active do
      # Build agent tab with keymap scope
      agent_ctx = %{keymap_scope: :agent}

      {tb, at} = TabBar.add(tb, :agent, "Agent")
      tb = TabBar.update_context(tb, at.id, agent_ctx)
      # Switch back to file tab so switch_tab properly snapshots it
      tb = TabBar.switch_to(tb, file_tab.id)

      state = %{state | tab_bar: tb, agentic: %{agentic | active: true, focus: :chat}}
      EditorState.switch_tab(state, at.id)
    else
      # Always store an agent tab so AgentAccess can find it.
      # This ensures the agent buffer is accessible to toggle_agent_split.
      agent_ctx = %{keymap_scope: :agent}
      {tb, at} = TabBar.add(tb, :agent, "Agent")
      tb = TabBar.update_context(tb, at.id, agent_ctx)
      tb = TabBar.switch_to(tb, file_tab.id)
      %{state | tab_bar: tb}
    end
  end

  # Helper: checks whether the buffer view is active (keymap_scope :editor)
  defp buffer_surface_active?(state), do: state.keymap_scope == :editor

  describe "toggle_agentic_view/1 — activating (split pane)" do
    test "creates an agent chat split pane" do
      state = base_state()
      new_state = AgentCommands.toggle_agentic_view(state)

      # Should have an agent chat window in the tree
      assert LayoutPreset.has_agent_chat?(new_state)

      # Should stay on BufferView surface
      assert buffer_surface_active?(new_state)
    end

    test "stays on the current tab (does not switch to agent tab)" do
      state = base_state()
      original_tab_id = state.tab_bar.active_id
      new_state = AgentCommands.toggle_agentic_view(state)

      # Active tab should not change
      assert new_state.tab_bar.active_id == original_tab_id
      assert EditorState.active_tab_kind(new_state) == :file
    end

    test "keymap_scope remains :editor" do
      state = base_state()
      new_state = AgentCommands.toggle_agentic_view(state)

      # File buffer window keeps focus, so keymap_scope stays :editor
      assert new_state.keymap_scope == :editor
    end

    test "adds agent chat window to existing tree" do
      state = base_state()
      # Start with a single leaf window
      assert match?({:leaf, _}, state.windows.tree)

      new_state = AgentCommands.toggle_agentic_view(state)

      # Should now have a split with agent chat
      assert match?({:split, :vertical, _, _, _}, new_state.windows.tree)
      assert LayoutPreset.has_agent_chat?(new_state)

      # Verify agent chat window exists in the map
      agent_chat_exists =
        Enum.any?(new_state.windows.map, fn {_id, window} ->
          Content.agent_chat?(window.content)
        end)

      assert agent_chat_exists
    end

    test "starts a session when none is running" do
      state = base_state(session: nil)
      new_state = AgentCommands.toggle_agentic_view(state)

      # Should have created the split
      assert LayoutPreset.has_agent_chat?(new_state)

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

      # Session should be preserved
      assert AgentAccess.session(new_state) == fake_session

      # Should have created the split
      assert LayoutPreset.has_agent_chat?(new_state)
    end

    test "uses the background agent tab for state storage" do
      state = base_state()

      # base_state always creates a background agent tab for state storage
      agent_tab_before = TabBar.find_by_kind(state.tab_bar, :agent)
      assert agent_tab_before != nil
      assert EditorState.active_tab_kind(state) == :file

      new_state = AgentCommands.toggle_agentic_view(state)

      # Agent tab should still exist with the same ID
      agent_tab_after = TabBar.find_by_kind(new_state.tab_bar, :agent)
      assert agent_tab_after != nil
      assert agent_tab_after.id == agent_tab_before.id

      # Active tab should still be the file tab
      assert EditorState.active_tab_kind(new_state) == :file
    end
  end

  describe "toggle_agentic_view/1 — deactivating" do
    test "switches to editor scope" do
      state = base_state()
      # First activate the agent split
      with_agent = AgentCommands.toggle_agentic_view(state)
      # Then toggle it off
      new_state = AgentCommands.toggle_agentic_view(with_agent)
      assert buffer_surface_active?(new_state)
    end

    test "second toggle removes the split pane" do
      state = base_state()
      # First toggle: add agent split
      with_agent = AgentCommands.toggle_agentic_view(state)
      assert LayoutPreset.has_agent_chat?(with_agent)

      # Second toggle: remove agent split
      without_agent = AgentCommands.toggle_agentic_view(with_agent)
      refute LayoutPreset.has_agent_chat?(without_agent)
    end

    test "removing split resets keymap_scope to :editor" do
      state = base_state()
      with_agent = AgentCommands.toggle_agentic_view(state)
      # Simulate agent window having focus
      with_agent = %{with_agent | keymap_scope: :agent}

      without_agent = AgentCommands.toggle_agentic_view(with_agent)
      assert without_agent.keymap_scope == :editor
    end
  end

  describe "kill_buffer on agent tab" do
    alias Minga.Editor.Commands.BufferManagement

    test "closes agent tab and switches to file tab" do
      state = base_state(active: true)
      assert EditorState.active_tab_kind(state) == :agent

      new_state = BufferManagement.execute(state, :kill_buffer)

      assert EditorState.active_tab_kind(new_state) == :file
      assert new_state.keymap_scope == :editor
    end

    test "restores file tab context after closing agent tab" do
      # Start with agent tab active
      state = base_state(active: true)
      assert EditorState.active_tab_kind(state) == :agent

      # Close agent tab via kill_buffer
      state = BufferManagement.execute(state, :kill_buffer)

      assert EditorState.active_tab_kind(state) == :file
      # Windows should be restored (though they may have different structure)
      assert state.keymap_scope == :editor
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
    test "first toggle adds split, second toggle removes it" do
      state = base_state()
      # Start with single window
      assert match?({:leaf, _}, state.windows.tree)

      # First toggle: add agent split
      with_split = AgentCommands.toggle_agentic_view(state)
      assert LayoutPreset.has_agent_chat?(with_split)
      assert match?({:split, :vertical, _, _, _}, with_split.windows.tree)

      # Second toggle: remove agent split
      restored = AgentCommands.toggle_agentic_view(with_split)
      refute LayoutPreset.has_agent_chat?(restored)
      assert match?({:leaf, _}, restored.windows.tree)

      # Should still be on BufferView
      assert buffer_surface_active?(restored)
    end

    test "agent state is preserved through toggle cycles" do
      state = base_state()

      # First toggle: adds split and creates agent tab
      first_toggle = AgentCommands.toggle_agentic_view(state)
      agent_tab_id = TabBar.find_by_kind(first_toggle.tab_bar, :agent).id
      assert LayoutPreset.has_agent_chat?(first_toggle)

      # Second toggle: removes split (agent tab still exists in background)
      second_toggle = AgentCommands.toggle_agentic_view(first_toggle)
      refute LayoutPreset.has_agent_chat?(second_toggle)
      # Agent tab should still exist
      assert TabBar.get(second_toggle.tab_bar, agent_tab_id) != nil

      # Third toggle: re-adds split, agent state preserved
      third_toggle = AgentCommands.toggle_agentic_view(second_toggle)
      assert LayoutPreset.has_agent_chat?(third_toggle)
      # Agent tab still exists with same ID
      assert TabBar.get(third_toggle.tab_bar, agent_tab_id) != nil
    end
  end
end
