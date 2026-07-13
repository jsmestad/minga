defmodule MingaEditor.Commands.AgentSplitToggleTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.Input
  alias Minga.Test.StubServer

  defp fake_session do
    {:ok, pid} = StubServer.start_link()
    pid
  end

  defp base_state(opts \\ []) do
    {:ok, buf} = BufferProcess.start_link(content: "hello\nworld")
    {:ok, prompt_buf} = BufferProcess.start_link(content: "")

    session_pid = Keyword.get(opts, :session, fake_session())

    agent = %AgentState{
      error: nil,
      spinner_timer: nil
    }

    active = Keyword.get(opts, :active, false)

    agentic = %UIState{
      panel: %UIState.Panel{
        visible: false,
        input_focused: false,
        prompt_buffer: prompt_buf
      }
    }

    agentic =
      if active do
        UIState.activate(
          agentic,
          Keyword.get(opts, :saved_windows),
          Keyword.get(opts, :saved_file_tree)
        )
      else
        agentic
      end

    file_tab = Tab.new_file(1, "test.ex")
    tb = TabBar.new(file_tab)
    window = Window.new(1, buf, 24, 80)

    state = %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        buffers: %Buffers{active: buf, list: [buf], active_index: 0},
        agent_ui: agentic,
        windows: %MingaEditor.State.Windows{
          tree: {:leaf, 1},
          map: %{1 => window},
          active: 1,
          next_id: 2
        }
      },
      focus_stack: Input.default_stack(),
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          MingaEditor.Shell.Traditional.State.set_tab_bar(
            MingaEditor.Shell.Traditional.State.replace_agent(
              %MingaEditor.Shell.Traditional.State{},
              agent
            ),
            tb
          )
        )
    }

    if active do
      agent_win = Window.new_agent_chat(1, 24, 80)

      agent_ctx = %{
        keymap_scope: :agent,
        windows: %MingaEditor.State.Windows{
          tree: {:leaf, 1},
          map: %{1 => agent_win},
          active: 1,
          next_id: 2
        }
      }

      {tb, at} = TabBar.add(tb, :agent, "Agent")
      {tb, agent_workspace} = TabBar.add_workspace(tb, "Agent", session_pid)

      tb =
        tb
        |> TabBar.update_tab(at.id, &Tab.set_session(&1, session_pid))
        |> TabBar.move_tab_to_workspace(at.id, agent_workspace.id)
        |> TabBar.update_workspace(agent_workspace.id, &Workspace.set_agent_ui(&1, agentic))
        |> TabBar.update_context(at.id, agent_ctx)
        |> TabBar.switch_to(file_tab.id)

      state = put_in(state.workspace.agent_ui, agentic)

      state = MingaEditor.State.set_tab_bar(state, tb)

      EditorState.switch_tab(state, at.id)
    else
      # Create background agent tab with agent context
      agent_win = Window.new_agent_chat(1, 24, 80)

      agent_ctx = %{
        keymap_scope: :agent,
        windows: %MingaEditor.State.Windows{
          tree: {:leaf, 1},
          map: %{1 => agent_win},
          active: 1,
          next_id: 2
        }
      }

      {tb, at} = TabBar.add(tb, :agent, "Agent")
      {tb, agent_workspace} = TabBar.add_workspace(tb, "Agent", session_pid)

      tb =
        tb
        |> TabBar.update_tab(at.id, &Tab.set_session(&1, session_pid))
        |> TabBar.move_tab_to_workspace(at.id, agent_workspace.id)
        |> TabBar.update_workspace(agent_workspace.id, &Workspace.set_agent_ui(&1, agentic))
        |> TabBar.update_context(at.id, agent_ctx)
        |> TabBar.switch_to(file_tab.id)

      MingaEditor.State.set_tab_bar(state, tb)
    end
  end

  describe "toggle_agent_split/1 — activating (tab switch)" do
    test "switches to agent tab" do
      state = base_state()
      assert EditorState.active_tab_kind(state) == :file

      new_state = AgentCommands.toggle_agentic_view(state)

      assert EditorState.active_tab_kind(new_state) == :agent
    end

    test "keymap_scope becomes :agent" do
      state = base_state()
      new_state = AgentCommands.toggle_agentic_view(state)

      assert new_state.workspace.keymap_scope == :agent
    end

    test "agent tab has agent_chat window in context" do
      state = base_state()
      new_state = AgentCommands.toggle_agentic_view(state)

      agent_chat_exists =
        Enum.any?(new_state.workspace.windows.map, fn {_id, window} ->
          Content.agent_chat?(window.content)
        end)

      assert agent_chat_exists
    end

    test "does not double-start a session when one is already running" do
      fake_session = fake_session()
      state = base_state(session: fake_session)
      new_state = AgentCommands.toggle_agentic_view(state)

      assert AgentAccess.session(new_state) == fake_session
    end

    test "agent tab exists after toggle" do
      state = base_state()
      agent_tab_before = TabBar.find_by_kind(MingaEditor.State.tab_bar(state), :agent)
      assert agent_tab_before != nil

      new_state = AgentCommands.toggle_agentic_view(state)

      agent_tab_after = TabBar.find_by_kind(new_state.shell_runtime.state.tab_bar, :agent)
      assert agent_tab_after != nil
      assert agent_tab_after.id == agent_tab_before.id
    end
  end

  describe "toggle_agent_split/1 — deactivating (back to file)" do
    test "switches back to file tab" do
      state = base_state()
      with_agent = AgentCommands.toggle_agentic_view(state)
      assert EditorState.active_tab_kind(with_agent) == :agent

      without_agent = AgentCommands.toggle_agentic_view(with_agent)
      assert EditorState.active_tab_kind(without_agent) == :file
    end

    test "restores :editor keymap_scope" do
      state = base_state()
      with_agent = AgentCommands.toggle_agentic_view(state)
      without_agent = AgentCommands.toggle_agentic_view(with_agent)

      assert without_agent.workspace.keymap_scope == :editor
    end

    test "agent scope close returns to file without stopping the session" do
      session = fake_session()
      state = base_state(active: true, session: session)

      without_agent = AgentCommands.scope_close(state)

      assert EditorState.active_tab_kind(without_agent) == :file
      assert without_agent.workspace.keymap_scope == :editor
      refute_process_down(session)
      assert TabBar.find_by_session(without_agent.shell_runtime.state.tab_bar, session) != nil
    end

    test "agent ESC behavior returns to file without stopping the session" do
      session = fake_session()
      state = base_state(active: true, session: session)

      without_agent = AgentCommands.scope_dismiss_or_noop(state)

      assert EditorState.active_tab_kind(without_agent) == :file
      assert without_agent.workspace.keymap_scope == :editor
      refute_process_down(session)
      assert TabBar.find_by_session(without_agent.shell_runtime.state.tab_bar, session) != nil
    end
  end

  describe "kill_buffer on agent tab" do
    alias MingaEditor.Commands.BufferManagement

    test "closes agent tab and switches to file tab" do
      state = base_state(active: true)
      assert EditorState.active_tab_kind(state) == :agent

      new_state = BufferManagement.execute(state, :kill_buffer)

      assert EditorState.active_tab_kind(new_state) == :file
      assert new_state.workspace.keymap_scope == :editor
    end

    test "does not crash when agent tab has no session" do
      state = base_state(active: true, session: nil)
      new_state = BufferManagement.execute(state, :kill_buffer)
      assert EditorState.active_tab_kind(new_state) == :file
    end

    test "removes agent tab from tab bar" do
      state = base_state(active: true)
      assert Enum.count(TabBar.filter_by_kind(MingaEditor.State.tab_bar(state), :agent)) == 1

      new_state = BufferManagement.execute(state, :kill_buffer)
      assert TabBar.filter_by_kind(new_state.shell_runtime.state.tab_bar, :agent) == []
    end
  end

  defp refute_process_down(pid) do
    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}
    Process.demonitor(ref, [:flush])
  end

  describe "open_session/2" do
    test "opens the agent view and resumes the requested session" do
      {:ok, session} = StubServer.start_link(notify: self())
      state = base_state(session: session)
      assert EditorState.active_tab_kind(state) == :file

      new_state = AgentCommands.open_session(state, "sess-42")

      assert EditorState.active_tab_kind(new_state) == :agent
      assert_receive {:stub_loaded_session, "sess-42"}
    end

    test "does not crash when the session pid is dead" do
      # Unlinked so killing it does not propagate to the test process.
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}

      state = base_state(session: dead)
      new_state = AgentCommands.open_session(state, "sess-1")

      assert %EditorState{} = new_state
    end

    test "with a tool_call_id, arms a provenance jump to the turn's opening message" do
      messages = [
        {:user, "add auth"},
        {:thinking, "use middleware", false},
        {:tool_call, MingaAgent.ToolCall.new("tc_auth", "apply_diff")}
      ]

      {:ok, session} = StubServer.start_link(notify: self(), messages: messages)
      state = base_state(session: session)

      new_state = AgentCommands.open_session(state, "sess-42", "tc_auth")

      jump = AgentAccess.panel(new_state).provenance_jump
      assert jump != nil
      # default ids zip with index+1, so the :user message is id 1.
      assert jump.target_message_id == 1
      refute jump.landed?
      assert_receive {:stub_loaded_session, "sess-42"}
    end

    test "without a tool_call_id, arms no jump (plain resume)" do
      {:ok, session} = StubServer.start_link(notify: self(), messages: [{:user, "hi"}])
      state = base_state(session: session)

      new_state = AgentCommands.open_session(state, "sess-1")

      assert AgentAccess.panel(new_state).provenance_jump == nil
    end
  end

  describe "scope_provenance_return/1" do
    alias MingaEditor.Agent.ProvenanceJump

    test "returns to the editor and clears the jump" do
      session = fake_session()
      state = base_state(active: true, session: session)

      jump =
        ProvenanceJump.request(1, {"/tmp/no_such_file.ex", 5}) |> ProvenanceJump.mark_landed()

      state = AgentAccess.update_panel(state, &Panel.set_provenance_jump(&1, jump))
      assert EditorState.active_tab_kind(state) == :agent

      new_state = AgentCommands.scope_provenance_return(state)

      assert EditorState.active_tab_kind(new_state) == :file
      assert AgentAccess.panel(new_state).provenance_jump == nil
    end

    test "is a no-op with a status message when there is no active jump" do
      state = base_state(active: true)
      assert AgentAccess.panel(state).provenance_jump == nil

      new_state = AgentCommands.scope_provenance_return(state)

      assert %EditorState{} = new_state
      assert EditorState.active_tab_kind(new_state) == :agent
    end
  end

  describe "agent scope binding" do
    alias Minga.Keymap.Bindings
    alias Minga.Keymap.Scope.Agent, as: AgentScope

    test "g b returns to the provenance source" do
      trie = AgentScope.keymap(:normal, %{})
      {:prefix, g_node} = Bindings.lookup(trie, {?g, 0})
      assert {:command, :agent_provenance_return} = Bindings.lookup(g_node, {?b, 0})
    end
  end

  describe "round-trip toggle" do
    test "toggle cycle returns to file tab" do
      state = base_state()
      assert EditorState.active_tab_kind(state) == :file

      with_agent = AgentCommands.toggle_agentic_view(state)
      assert EditorState.active_tab_kind(with_agent) == :agent

      restored = AgentCommands.toggle_agentic_view(with_agent)
      assert EditorState.active_tab_kind(restored) == :file
      assert restored.workspace.keymap_scope == :editor
    end

    test "agent tab persists through toggle cycles" do
      state = base_state()
      agent_tab_id = TabBar.find_by_kind(MingaEditor.State.tab_bar(state), :agent).id

      first = AgentCommands.toggle_agentic_view(state)
      assert TabBar.get(first.shell_runtime.state.tab_bar, agent_tab_id) != nil

      second = AgentCommands.toggle_agentic_view(first)
      assert TabBar.get(second.shell_runtime.state.tab_bar, agent_tab_id) != nil

      third = AgentCommands.toggle_agentic_view(second)
      assert TabBar.get(third.shell_runtime.state.tab_bar, agent_tab_id) != nil
    end
  end
end
