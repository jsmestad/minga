defmodule MingaEditor.UI.Picker.AgentSessionSourceTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  alias MingaAgent.Session
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaAgent.RuntimeState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.UI.Picker.AgentSessionSource

  describe "title/0" do
    test "returns Sessions" do
      assert AgentSessionSource.title() == "Sessions"
    end
  end

  describe "preview?/0" do
    test "returns false" do
      refute AgentSessionSource.preview?()
    end
  end

  describe "candidates/1" do
    test "returns only disk candidates when no agent tabs" do
      tb = TabBar.new(Tab.new_file(1, "main.ex"))

      state = %EditorState{
        port_manager: self(),
        workspace: %MingaEditor.Workspace.State{
          viewport: Viewport.new(24, 80),
          buffers: %Buffers{},
          windows: %Windows{},
          editing: VimState.new()
        },
        shell_state: %MingaEditor.Shell.Traditional.State{
          tab_bar: tb,
          agent: %AgentState{session: nil}
        }
      }

      ctx = Context.from_editor_state(state)
      candidates = AgentSessionSource.candidates(ctx)

      Enum.each(candidates, fn %Item{id: {_, tag}} ->
        assert tag == :disk
      end)
    end

    test "returns tab candidates when agent tabs exist" do
      {:ok, pid} = start_test_session()
      Session.subscribe(pid)

      state = state_with_agent_tab(pid)
      ctx = Context.from_editor_state(state)
      candidates = AgentSessionSource.candidates(ctx)
      tab_entries = Enum.filter(candidates, fn %Item{id: {_, tag}} -> match?({:tab, _}, tag) end)
      assert tab_entries != []

      %Item{id: {_, {:tab, _tab_id}}, label: label, description: desc} = hd(tab_entries)
      assert is_binary(label)
      assert String.contains?(desc, "test-model")

      Session.unsubscribe(pid)
      stop_session(pid)
    end

    test "active agent tab is marked with bullet" do
      {:ok, pid} = start_test_session()
      Session.subscribe(pid)

      state = state_with_agent_tab(pid)
      ctx = Context.from_editor_state(state)
      candidates = AgentSessionSource.candidates(ctx)

      active =
        Enum.find(candidates, fn
          %Item{id: {_, {:tab, _}}, label: label} -> String.contains?(label, "\u{2022}")
          _ -> false
        end)

      assert active != nil

      Session.unsubscribe(pid)
      stop_session(pid)
    end

    test "background agent tab is not marked with bullet" do
      {:ok, pid1} = start_test_session()
      {:ok, pid2} = start_test_session()
      Session.subscribe(pid1)
      Session.subscribe(pid2)

      state = state_with_two_agent_tabs(pid1, pid2)
      ctx = Context.from_editor_state(state)
      candidates = AgentSessionSource.candidates(ctx)

      # Active tab is the first one (pid1). Background tab (pid2) should not have bullet.
      bg_tabs =
        Enum.filter(candidates, fn
          {{_, {:tab, id}}, _, _} -> id != state.shell_state.tab_bar.active_id
          _ -> false
        end)

      Enum.each(bg_tabs, fn %Item{label: label} ->
        refute String.contains?(label, "\u{2022}")
      end)

      Session.unsubscribe(pid1)
      Session.unsubscribe(pid2)
      stop_session(pid1)
      stop_session(pid2)
    end
  end

  describe "on_select/2" do
    test "with tab entry switches to that tab" do
      {:ok, pid} = start_test_session()
      Session.subscribe(pid)

      state = state_with_two_tabs_file_active(pid)
      agent_tab_id = Enum.find(state.shell_state.tab_bar.tabs, &(&1.kind == :agent)).id
      item = %Item{id: {"some-id", {:tab, agent_tab_id}}, label: "label", description: "desc"}
      result = AgentSessionSource.on_select(item, state)
      assert result.shell_state.tab_bar.active_id == agent_tab_id

      Session.unsubscribe(pid)
      stop_session(pid)
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{agent: %AgentState{session: nil}}
      assert AgentSessionSource.on_cancel(state) == state
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp start_test_session do
    MingaAgent.Supervisor.start_session(
      provider: MingaAgent.Providers.Native,
      model_name: "test-model",
      provider_opts: [
        llm_client: fn _req -> {:ok, %{status: 200, body: %{"choices" => []}}} end
      ]
    )
  end

  defp stop_session(pid) do
    MingaAgent.Supervisor.stop_session(pid)
  end

  defp state_with_agent_tab(session_pid) do
    tb = TabBar.new(Tab.new_file(1, "main.ex"))
    {tb, agent_tab} = TabBar.add(tb, :agent, "Agent 1")
    tb = TabBar.update_tab(tb, agent_tab.id, &Tab.set_session(&1, session_pid))
    # Make the agent tab active
    tb = TabBar.switch_to(tb, agent_tab.id)

    agent_ctx = %{
      shell_state: %MingaEditor.Shell.Traditional.State{
        agent: %AgentState{session: session_pid, runtime: %RuntimeState{status: :idle}}
      },
      agent_ui: %UIState{view: %UIState.View{active: true, focus: :chat}},
      windows: %Windows{},
      file_tree: nil,
      editing: VimState.new(),
      keymap_scope: :agent,
      active_buffer: nil,
      active_buffer_index: 0
    }

    tb = TabBar.update_context(tb, agent_tab.id, agent_ctx)

    agent = %AgentState{session: session_pid, runtime: %RuntimeState{status: :idle}}
    agentic = %UIState{view: %UIState.View{active: true, focus: :chat}}

    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{},
        windows: %Windows{},
        editing: VimState.new(),
        keymap_scope: :agent,
        agent_ui: agentic
      },
      shell_state: %MingaEditor.Shell.Traditional.State{tab_bar: tb, agent: agent}
    }
  end

  defp state_with_two_agent_tabs(session1, session2) do
    tb = TabBar.new(Tab.new_file(1, "main.ex"))
    {tb, tab1} = TabBar.add(tb, :agent, "Agent 1")
    tb = TabBar.update_tab(tb, tab1.id, &Tab.set_session(&1, session1))
    {tb, tab2} = TabBar.add(tb, :agent, "Agent 2")
    tb = TabBar.update_tab(tb, tab2.id, &Tab.set_session(&1, session2))
    # First agent tab is active
    tb = TabBar.switch_to(tb, tab1.id)

    agent = %AgentState{session: session1, runtime: %RuntimeState{status: :idle}}
    agentic = %UIState{view: %UIState.View{active: true, focus: :chat}}

    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{},
        windows: %Windows{},
        editing: VimState.new(),
        keymap_scope: :agent,
        agent_ui: agentic
      },
      shell_state: %MingaEditor.Shell.Traditional.State{tab_bar: tb, agent: agent}
    }
  end

  defp state_with_two_tabs_file_active(session_pid) do
    tb = TabBar.new(Tab.new_file(1, "main.ex"))
    {tb, agent_tab} = TabBar.add(tb, :agent, "Agent 1")
    tb = TabBar.update_tab(tb, agent_tab.id, &Tab.set_session(&1, session_pid))

    agent_ctx = %{
      shell_state: %MingaEditor.Shell.Traditional.State{
        agent: %AgentState{session: session_pid, runtime: %RuntimeState{status: :idle}}
      },
      agent_ui: %UIState{view: %UIState.View{active: true, focus: :chat}},
      windows: %Windows{},
      file_tree: nil,
      editing: VimState.new(),
      keymap_scope: :agent,
      active_buffer: nil,
      active_buffer_index: 0
    }

    tb = TabBar.update_context(tb, agent_tab.id, agent_ctx)
    # File tab (1) is active
    tb = TabBar.switch_to(tb, 1)

    agent = %AgentState{}
    agentic = %UIState{}

    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{},
        windows: %Windows{},
        editing: VimState.new(),
        keymap_scope: :editor,
        agent_ui: agentic
      },
      shell_state: %MingaEditor.Shell.Traditional.State{tab_bar: tb, agent: agent}
    }
  end
end
