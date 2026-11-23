defmodule MingaEditor.Commands.AgentSplitToggleTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias Minga.Test.StubServer

  defp fake_session do
    {:ok, pid} = StubServer.start_link()
    pid
  end

  defp base_state(opts \\ []) do
    {:ok, buf} = BufferProcess.start_link(content: "hello\nworld")

    prompt_buf =
      if Keyword.get(opts, :cold_composer, false) do
        nil
      else
        {:ok, pid} = BufferProcess.start_link(content: "")
        pid
      end

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
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %MingaEditor.Session.State{
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
      interaction: %MingaEditor.State.Interaction{},
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          TraditionalState.install_tab_bar(
            TraditionalState.replace_agent(
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
        |> TabBar.move_tab_to_workspace(at.id, agent_workspace.id)
        |> TabBar.set_workspace_session(agent_workspace.id, session_pid)
        |> TabBar.set_workspace_agent_ui(agent_workspace.id, agentic)
        |> TabBar.update_context(at.id, agent_ctx)
        |> TabBar.switch_to(file_tab.id)

      state = %{state | workspace: SessionState.set_agent_ui(state.workspace, agentic)}

      state =
        then(state, fn root ->
          shell_state =
            TraditionalState.install_tab_bar(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              tb
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      MingaEditor.TabWorkflow.switch(state, at.id)
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
        |> TabBar.move_tab_to_workspace(at.id, agent_workspace.id)
        |> TabBar.set_workspace_session(agent_workspace.id, session_pid)
        |> TabBar.set_workspace_agent_ui(agent_workspace.id, agentic)
        |> TabBar.update_context(at.id, agent_ctx)
        |> TabBar.switch_to(file_tab.id)

      then(state, fn root ->
        shell_state =
          TraditionalState.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tb
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)
    end
  end

  test "cold toggle renders an empty composer in Normal mode without focusing it" do
    state = AgentCommands.toggle_agent_split(base_state(cold_composer: true))
    assert_cold_composer(state)
  end

  test "a failed first Agent startup keeps the same composer and draft when returning to the file" do
    _providers = LLMDB.providers()
    manager = spawn_link(fn -> reply_once({:error, :boom}) end)

    state =
      base_state(cold_composer: true)
      |> MingaEditor.WorkspaceWorkflow.install_tab_bar(TabBar.new(Tab.new_file(1, "test.ex")))

    state = %{state | agent_connection: %{state.agent_connection | session_manager: manager}}

    opened = AgentCommands.toggle_agent_split(state)
    composer = opened.workspace.agent_ui.panel.prompt_buffer
    assert is_pid(composer)
    :ok = BufferProcess.insert_text(composer, "draft after failed start")

    opened = Minga.Test.AgentSessionStart.settle(opened)
    assert Runtime.active_session(opened.shell_runtime) == nil
    assert TraditionalState.agent(opened.shell_runtime.state).error =~ ":boom"
    assert {:failed, _reason} = opened.workspace.agent_ui.chat_lifecycle

    returned = AgentCommands.toggle_agent_split(opened)
    assert Runtime.active_tab_kind(returned.shell_runtime) == :file

    reopened = AgentCommands.toggle_agent_split(returned)
    assert reopened.workspace.agent_ui.panel.prompt_buffer == composer
    assert BufferProcess.content(composer) == "draft after failed start"
  end

  @spec reply_once(term()) :: :ok
  defp reply_once(reply) do
    receive do
      {:"$gen_call", from, {:start_session, _opts}} -> GenServer.reply(from, reply)
    end

    :ok
  end

  test "arriving at a background Agent tab renders its composer before further input" do
    state = base_state(cold_composer: true)
    %Tab{id: id} = TabBar.find_by_kind(state.shell_runtime.state.tab_bar, :agent)
    assert_cold_composer(MingaEditor.TabWorkflow.switch(state, id))
  end

  test "reactivating the current Agent tab replaces a stopped composer without focusing it" do
    state = base_state(active: true)
    %Tab{id: id} = Runtime.active_tab(state.shell_runtime)
    previous = state.workspace.agent_ui.panel.prompt_buffer
    GenServer.stop(previous)

    restored = MingaEditor.TabWorkflow.switch(state, id)

    refute restored.workspace.agent_ui.panel.prompt_buffer == previous
    assert_cold_composer(restored)
  end

  @tag :tmp_dir
  test "a brokered Agent tab renders its own composer without borrowing the previous draft",
       %{tmp_dir: dir} do
    state = base_state(active: true)
    original_tab = Runtime.active_tab(state.shell_runtime)

    state =
      MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
        state,
        MingaEditor.Agent.PromptBuffer.set_prompt_text(state.workspace.agent_ui, "previous draft")
      )

    assert {:ok, %{session_id: record, pid: session, token: token}} =
             MingaAgent.RemoteAPI.start_session(
               provider: Minga.Test.StubProvider,
               session_store_dir: dir
             )

    on_exit(fn -> MingaAgent.SessionManager.stop_session(record) end)

    connected = AgentCommands.connect_remote_session(state, "test host", record, session, token)
    assert Runtime.active_session(connected.shell_runtime) == session
    assert_cold_composer(connected)

    assert %{visible?: true, lifecycle: :conversation, prompt: ""} =
             Minga.Test.AgentWorkflowDriver.chat_model(connected)

    returned = MingaEditor.TabWorkflow.switch(connected, original_tab.id)

    assert MingaEditor.Agent.PromptBuffer.prompt_text(returned.workspace.agent_ui) ==
             "previous draft"
  end

  defp assert_cold_composer(state) do
    panel = state.workspace.agent_ui.panel
    assert is_pid(panel.prompt_buffer)
    assert Minga.Buffer.content(panel.prompt_buffer) == ""
    refute panel.input_focused
    assert state.workspace.editing.mode == :normal

    intent = MingaEditor.RenderPipeline.Intent.from_editor_state(state)

    renderer =
      MingaEditor.Renderer.State.new(editor_pid: nil, pipeline: &MingaEditor.RenderPipeline.run/1)

    {_renderer, input} = MingaEditor.Renderer.BufferChanges.prepare(renderer, intent)
    layout = MingaEditor.Layout.put(input) |> MingaEditor.Layout.get()

    assert {[%{models: [_prompt]}], _cursor, _state} =
             MingaEditor.RenderPipeline.Content.build_agent_chat_content(input, layout)
  end

  describe "toggle_agent_split/1 — activating (tab switch)" do
    test "switches to agent tab" do
      state = base_state()
      assert MingaEditor.Shell.Runtime.active_tab_kind(state.shell_runtime) == :file

      new_state = AgentCommands.toggle_agentic_view(state)

      assert MingaEditor.Shell.Runtime.active_tab_kind(new_state.shell_runtime) == :agent
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

      assert MingaEditor.Shell.Runtime.active_session(new_state.shell_runtime) == fake_session
    end

    test "agent tab exists after toggle" do
      state = base_state()
      agent_tab_before = TabBar.find_by_kind(state.shell_runtime.state.tab_bar, :agent)
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
      assert MingaEditor.Shell.Runtime.active_tab_kind(with_agent.shell_runtime) == :agent

      without_agent = AgentCommands.toggle_agentic_view(with_agent)
      assert MingaEditor.Shell.Runtime.active_tab_kind(without_agent.shell_runtime) == :file
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

      assert MingaEditor.Shell.Runtime.active_tab_kind(without_agent.shell_runtime) == :file
      assert without_agent.workspace.keymap_scope == :editor
      refute_process_down(session)
      assert TabBar.find_by_session(without_agent.shell_runtime.state.tab_bar, session) != nil
    end

    test "agent ESC behavior returns to file without stopping the session" do
      session = fake_session()
      state = base_state(active: true, session: session)

      without_agent = AgentCommands.scope_dismiss_or_noop(state)

      assert MingaEditor.Shell.Runtime.active_tab_kind(without_agent.shell_runtime) == :file
      assert without_agent.workspace.keymap_scope == :editor
      refute_process_down(session)
      assert TabBar.find_by_session(without_agent.shell_runtime.state.tab_bar, session) != nil
    end
  end

  describe "kill_buffer on agent tab" do
    alias MingaEditor.Commands.BufferManagement

    test "closes agent tab and switches to file tab" do
      state = base_state(active: true)
      assert MingaEditor.Shell.Runtime.active_tab_kind(state.shell_runtime) == :agent

      new_state = BufferManagement.execute(state, :kill_buffer)

      assert MingaEditor.Shell.Runtime.active_tab_kind(new_state.shell_runtime) == :file
      assert new_state.workspace.keymap_scope == :editor
    end

    test "does not crash when agent tab has no session" do
      state = base_state(active: true, session: nil)
      new_state = BufferManagement.execute(state, :kill_buffer)
      assert MingaEditor.Shell.Runtime.active_tab_kind(new_state.shell_runtime) == :file
    end

    test "removes agent tab from tab bar" do
      state = base_state(active: true)
      assert Enum.count(TabBar.filter_by_kind(state.shell_runtime.state.tab_bar, :agent)) == 1

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
      assert MingaEditor.Shell.Runtime.active_tab_kind(state.shell_runtime) == :file

      new_state = AgentCommands.open_session(state, "sess-42")

      assert MingaEditor.Shell.Runtime.active_tab_kind(new_state.shell_runtime) == :agent
      assert_receive {:stub_loaded_session, "sess-42"}
    end

    test "does not arm provenance or activate after a legacy session restore is refused" do
      {:ok, session} = StubServer.start_link(load_result: {:error, :legacy_import_required})
      state = base_state(session: session)

      new_state = AgentCommands.open_session(state, "sess-legacy", "tc1")

      assert new_state.workspace.agent_ui.panel.transcript.provenance_jump == nil
      refute new_state.workspace.agent_ui.panel.visible
      assert MingaEditor.Shell.Runtime.active_tab_kind(new_state.shell_runtime) == :agent
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

    test "defers resolving the provenance target until the restored transcript arrives" do
      messages = [
        {:user, "add auth"},
        {:thinking, "use middleware", false},
        {:tool_call, MingaAgent.ToolCall.new("tc_auth", "apply_diff")}
      ]

      {:ok, session} = StubServer.start_link(notify: self(), messages: messages)
      state = base_state(session: session)

      new_state = AgentCommands.open_session(state, "sess-42", "tc_auth")

      jump = new_state.workspace.agent_ui.panel.transcript.provenance_jump
      assert jump != nil
      assert jump.target == {:tool_call_id, "tc_auth"}
      refute jump.landed?
      assert_receive {:stub_loaded_session, "sess-42"}
    end

    test "without a tool_call_id, arms no jump (plain resume)" do
      {:ok, session} = StubServer.start_link(notify: self(), messages: [{:user, "hi"}])
      state = base_state(session: session)

      new_state = AgentCommands.open_session(state, "sess-1")

      assert new_state.workspace.agent_ui.panel.transcript.provenance_jump == nil
    end
  end

  describe "scope_provenance_return/1" do
    alias MingaEditor.Agent.ProvenanceJump

    test "returns to the editor and clears the jump" do
      session = fake_session()
      state = base_state(active: true, session: session)

      jump =
        ProvenanceJump.request({:message_id, 1}, {"/tmp/no_such_file.ex", 5})
        |> ProvenanceJump.mark_landed()

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
          state,
          (&Panel.set_provenance_jump(&1, jump)).(state.workspace.agent_ui.panel)
        )

      assert MingaEditor.Shell.Runtime.active_tab_kind(state.shell_runtime) == :agent

      new_state = AgentCommands.scope_provenance_return(state)

      assert MingaEditor.Shell.Runtime.active_tab_kind(new_state.shell_runtime) == :file
      assert new_state.workspace.agent_ui.panel.transcript.provenance_jump == nil
    end

    test "is a no-op with a status message when there is no active jump" do
      state = base_state(active: true)
      assert state.workspace.agent_ui.panel.transcript.provenance_jump == nil

      new_state = AgentCommands.scope_provenance_return(state)

      assert %EditorState{} = new_state
      assert MingaEditor.Shell.Runtime.active_tab_kind(new_state.shell_runtime) == :agent
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
      assert MingaEditor.Shell.Runtime.active_tab_kind(state.shell_runtime) == :file

      with_agent = AgentCommands.toggle_agentic_view(state)
      assert MingaEditor.Shell.Runtime.active_tab_kind(with_agent.shell_runtime) == :agent

      restored = AgentCommands.toggle_agentic_view(with_agent)
      assert MingaEditor.Shell.Runtime.active_tab_kind(restored.shell_runtime) == :file
      assert restored.workspace.keymap_scope == :editor
    end

    test "agent tab persists through toggle cycles" do
      state = base_state()
      agent_tab_id = TabBar.find_by_kind(state.shell_runtime.state.tab_bar, :agent).id

      first = AgentCommands.toggle_agentic_view(state)
      assert TabBar.get(first.shell_runtime.state.tab_bar, agent_tab_id) != nil

      second = AgentCommands.toggle_agentic_view(first)
      assert TabBar.get(second.shell_runtime.state.tab_bar, agent_tab_id) != nil

      third = AgentCommands.toggle_agentic_view(second)
      assert TabBar.get(third.shell_runtime.state.tab_bar, agent_tab_id) != nil
    end
  end
end
