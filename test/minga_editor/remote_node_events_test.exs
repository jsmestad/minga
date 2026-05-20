defmodule MingaEditor.RemoteNodeEventsTest do
  use Minga.Test.EditorCase, async: true

  alias Minga.Distribution.Events.NodeConnectedEvent
  alias Minga.Distribution.Events.NodeDisconnectedEvent
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef
  alias MingaAgent.SessionManager
  alias MingaAgent.SessionStore
  alias MingaAgent.TurnUsage
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Remote
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace

  test "node_connected marks the remote server connected" do
    ctx = start_editor("initial")

    send(ctx.editor, {
      :minga_event,
      :node_connected,
      %NodeConnectedEvent{
        server_name: "home",
        node: node(),
        connected_at: DateTime.utc_now()
      }
    })

    state = editor_state(ctx)

    assert Remote.server_status(state.remote, "home") == :connected
    assert state.shell_state.status_msg =~ "Connected to home"
  end

  test "node_disconnected marks the remote server disconnected" do
    ctx = start_editor("initial")

    send(ctx.editor, {
      :minga_event,
      :node_disconnected,
      %NodeDisconnectedEvent{
        server_name: "home",
        node: :"missing@127.0.0.1",
        reason: :nodedown,
        disconnected_at: DateTime.utc_now()
      }
    })

    state = editor_state(ctx)

    assert Remote.server_status(state.remote, "home") == :disconnected
    assert state.shell_state.status_msg == "[home] disconnected, reconnecting..."
  end

  test "node_disconnected marks active remote workspace when a file tab is active" do
    {:ok, remote_session_id, session} = SessionManager.start_session([])
    on_exit(fn -> SessionManager.stop_session_by_pid(session) end)

    ctx = start_editor("initial")

    %{workspace_id: workspace_id, agent_tab_id: agent_tab_id} =
      seed_remote_workspace(ctx.editor, remote_session_id, session, active: :file)

    send(ctx.editor, {
      :minga_event,
      :node_disconnected,
      %NodeDisconnectedEvent{
        server_name: "home",
        node: :"missing@127.0.0.1",
        reason: :nodedown,
        disconnected_at: DateTime.utc_now()
      }
    })

    state = editor_state(ctx)
    workspace = TabBar.get_workspace(state.shell_state.tab_bar, workspace_id)
    agent_tab = TabBar.get(state.shell_state.tab_bar, agent_tab_id)

    assert TabBar.active(state.shell_state.tab_bar).kind == :file
    assert Remote.server_status(state.remote, "home") == :disconnected
    assert workspace.remote_session.connection_status == :disconnected
    assert agent_tab.connection_status == :disconnected
    assert state.shell_state.agent.error == "[home] disconnected, reconnecting..."
    assert state.shell_state.status_msg == "[home] disconnected, reconnecting..."
  end

  test "node_connected remote reconnect syncs the owning workspace session" do
    {:ok, _old_session_id, old_session} = SessionManager.start_session([])
    {:ok, new_session_id, new_session} = SessionManager.start_session([])

    on_exit(fn ->
      SessionManager.stop_session_by_pid(old_session)
      SessionManager.stop_session_by_pid(new_session)
    end)

    ctx = start_editor("initial")
    workspace_id = seed_remote_agent_workspace(ctx.editor, new_session_id, old_session)

    send(ctx.editor, {
      :minga_event,
      :node_connected,
      %NodeConnectedEvent{
        server_name: "home",
        node: node(),
        connected_at: DateTime.utc_now()
      }
    })

    state = editor_state(ctx)
    tab = TabBar.active(state.shell_state.tab_bar)
    workspace = TabBar.get_workspace(state.shell_state.tab_bar, workspace_id)

    assert tab.session == new_session
    assert tab.connection_status == :connected
    assert workspace.session == new_session
    assert workspace.remote_session.session_id == new_session_id
    assert workspace.remote_session.connection_status == :connected
    assert AgentAccess.session(state) == new_session
  end

  test "node_connected reconnects when a file tab is active in the remote workspace" do
    {:ok, _old_session_id, old_session} = SessionManager.start_session([])
    {:ok, new_session_id, new_session} = SessionManager.start_session([])

    on_exit(fn ->
      SessionManager.stop_session_by_pid(old_session)
      SessionManager.stop_session_by_pid(new_session)
    end)

    ctx = start_editor("initial")

    %{workspace_id: workspace_id, agent_tab_id: agent_tab_id} =
      seed_remote_workspace(ctx.editor, new_session_id, old_session, active: :file)

    send(ctx.editor, {
      :minga_event,
      :node_connected,
      %NodeConnectedEvent{
        server_name: "home",
        node: node(),
        connected_at: DateTime.utc_now()
      }
    })

    state = editor_state(ctx)
    tab = TabBar.active(state.shell_state.tab_bar)
    agent_tab = TabBar.get(state.shell_state.tab_bar, agent_tab_id)
    workspace = TabBar.get_workspace(state.shell_state.tab_bar, workspace_id)

    assert tab.kind == :file
    assert TabBar.active_workspace_id(state.shell_state.tab_bar) == workspace_id
    assert agent_tab.session == new_session
    assert agent_tab.connection_status == :connected
    assert workspace.session == new_session
    assert workspace.remote_session.connection_status == :connected
    assert AgentAccess.session(state) == new_session
  end

  test "node_connected reconnects when only workspace remote metadata remains" do
    {:ok, _old_session_id, old_session} = SessionManager.start_session([])
    {:ok, new_session_id, new_session} = SessionManager.start_session([])

    on_exit(fn ->
      SessionManager.stop_session_by_pid(old_session)
      SessionManager.stop_session_by_pid(new_session)
    end)

    ctx = start_editor("initial")

    %{workspace_id: workspace_id} =
      seed_remote_workspace(ctx.editor, new_session_id, old_session,
        active: :file,
        close_agent?: true
      )

    send(ctx.editor, {
      :minga_event,
      :node_connected,
      %NodeConnectedEvent{
        server_name: "home",
        node: node(),
        connected_at: DateTime.utc_now()
      }
    })

    state = editor_state(ctx)
    workspace = TabBar.get_workspace(state.shell_state.tab_bar, workspace_id)

    assert TabBar.active(state.shell_state.tab_bar).kind == :file
    assert workspace.session == new_session
    assert workspace.remote_session.connection_status == :connected
    assert AgentAccess.session(state) == new_session
    refute Enum.any?(state.shell_state.tab_bar.tabs, &(&1.kind == :agent))
  end

  test "node_connected unavailable remote restore clears stale workspace session" do
    {:ok, _old_session_id, old_session} = SessionManager.start_session([])

    on_exit(fn -> SessionManager.stop_session_by_pid(old_session) end)

    ctx = start_editor("initial")
    missing_session_id = "missing-#{System.unique_integer([:positive])}"

    %{workspace_id: workspace_id, file_ref: file_ref} =
      seed_remote_workspace(ctx.editor, missing_session_id, old_session,
        agent_status: :tool_executing
      )

    send(ctx.editor, {
      :minga_event,
      :node_connected,
      %NodeConnectedEvent{
        server_name: "home",
        node: node(),
        connected_at: DateTime.utc_now()
      }
    })

    state = editor_state(ctx)
    tab = TabBar.active(state.shell_state.tab_bar)
    workspace = TabBar.get_workspace(state.shell_state.tab_bar, workspace_id)

    assert tab.session == nil
    assert tab.connection_status == :unavailable
    assert workspace.session == nil
    assert workspace.agent_status == :idle
    assert workspace.remote_session.session_id == missing_session_id
    assert workspace.remote_session.connection_status == :unavailable
    assert workspace.files == [file_ref]
    assert prompt_text(workspace.agent_ui) == "remote draft"
    assert AgentAccess.session(state) == nil
  end

  test "node_connected ended remote restore clears stale workspace session" do
    {:ok, _old_session_id, old_session} = SessionManager.start_session([])
    ended_session_id = "ended-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      SessionManager.stop_session_by_pid(old_session)
      SessionStore.delete(ended_session_id)
    end)

    assert :ok = SessionStore.save(ended_session_data(ended_session_id))

    ctx = start_editor("initial")

    %{workspace_id: workspace_id, file_ref: file_ref} =
      seed_remote_workspace(ctx.editor, ended_session_id, old_session, agent_status: :thinking)

    send(ctx.editor, {
      :minga_event,
      :node_connected,
      %NodeConnectedEvent{
        server_name: "home",
        node: node(),
        connected_at: DateTime.utc_now()
      }
    })

    state = editor_state(ctx)
    tab = TabBar.active(state.shell_state.tab_bar)
    workspace = TabBar.get_workspace(state.shell_state.tab_bar, workspace_id)

    assert tab.session == nil
    assert tab.connection_status == :ended
    assert workspace.session == nil
    assert workspace.agent_status == :idle
    assert workspace.remote_session.session_id == ended_session_id
    assert workspace.remote_session.connection_status == :ended
    assert workspace.files == [file_ref]
    assert prompt_text(workspace.agent_ui) == "remote draft"
    assert AgentAccess.session(state) == nil
  end

  defp ended_session_data(session_id) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    %{
      id: session_id,
      timestamp: now,
      last_message_at: now,
      title: "Ended remote session",
      model_name: "test-model",
      provider_name: "test-provider",
      messages: [{:assistant, "Session finished"}],
      usage: %TurnUsage{}
    }
  end

  defp seed_remote_agent_workspace(editor, remote_session_id, old_session) do
    %{workspace_id: workspace_id} = seed_remote_workspace(editor, remote_session_id, old_session)
    workspace_id
  end

  defp seed_remote_workspace(editor, remote_session_id, old_session, opts \\ []) do
    parent = self()

    :sys.replace_state(editor, fn state ->
      file_ref = FileRef.from_buffer(state.workspace.buffers.active)
      ui = UIState.new() |> put_prompt("remote draft")
      agent_status = Keyword.get(opts, :agent_status, :idle)
      {tab_bar, agent_tab} = TabBar.add(state.shell_state.tab_bar, :agent, "Remote Agent")
      {tab_bar, workspace} = TabBar.add_workspace(tab_bar, "Remote Agent", old_session)

      tab_bar =
        tab_bar
        |> TabBar.update_tab(agent_tab.id, fn tab ->
          Tab.set_remote_session(tab, "home", remote_session_id, old_session)
        end)
        |> TabBar.move_tab_to_workspace(1, workspace.id)
        |> TabBar.move_tab_to_workspace(agent_tab.id, workspace.id)
        |> TabBar.update_workspace(workspace.id, fn workspace ->
          workspace
          |> Workspace.set_session(old_session)
          |> Workspace.put_remote_session("home", remote_session_id, :disconnected)
          |> Workspace.set_agent_status(agent_status)
          |> Workspace.add_file(file_ref)
          |> Workspace.set_agent_ui(ui)
        end)
        |> maybe_remove_agent_tab(agent_tab.id, Keyword.get(opts, :close_agent?, false))
        |> switch_seed_active_tab(agent_tab.id, Keyword.get(opts, :active, :agent))

      send(
        parent,
        {:workspace_info,
         %{workspace_id: workspace.id, agent_tab_id: agent_tab.id, file_ref: file_ref}}
      )

      EditorState.set_tab_bar(state, tab_bar)
    end)

    assert_receive {:workspace_info, info}
    info
  end

  defp maybe_remove_agent_tab(%TabBar{} = tab_bar, _agent_tab_id, false), do: tab_bar

  defp maybe_remove_agent_tab(%TabBar{} = tab_bar, agent_tab_id, true) do
    case TabBar.remove(tab_bar, agent_tab_id) do
      {:ok, tab_bar} -> tab_bar
      :last_tab -> tab_bar
    end
  end

  defp switch_seed_active_tab(%TabBar{} = tab_bar, _agent_tab_id, :file),
    do: TabBar.switch_to(tab_bar, 1)

  defp switch_seed_active_tab(%TabBar{} = tab_bar, agent_tab_id, :agent) do
    if TabBar.get(tab_bar, agent_tab_id),
      do: TabBar.switch_to(tab_bar, agent_tab_id),
      else: TabBar.switch_to(tab_bar, 1)
  end

  defp put_prompt(%UIState{} = ui, text) do
    ui = UIState.ensure_prompt_buffer(ui)
    BufferProcess.replace_content(ui.panel.prompt_buffer, text)
    ui
  end

  defp prompt_text(%UIState{} = ui), do: UIState.input_text(ui.panel)
end
