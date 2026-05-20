defmodule MingaEditor.RemoteNodeEventsTest do
  use Minga.Test.EditorCase, async: true

  alias Minga.Distribution.Events.NodeConnectedEvent
  alias Minga.Distribution.Events.NodeDisconnectedEvent
  alias MingaAgent.SessionManager
  alias MingaAgent.SessionStore
  alias MingaAgent.TurnUsage
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
    assert AgentAccess.session(state) == new_session
  end

  test "node_connected unavailable remote restore clears stale workspace session" do
    {:ok, _old_session_id, old_session} = SessionManager.start_session([])

    on_exit(fn -> SessionManager.stop_session_by_pid(old_session) end)

    ctx = start_editor("initial")
    missing_session_id = "missing-#{System.unique_integer([:positive])}"
    workspace_id = seed_remote_agent_workspace(ctx.editor, missing_session_id, old_session)

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
    workspace_id = seed_remote_agent_workspace(ctx.editor, ended_session_id, old_session)

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
    parent = self()

    :sys.replace_state(editor, fn state ->
      {tab_bar, agent_tab} = TabBar.add(state.shell_state.tab_bar, :agent, "Remote Agent")
      {tab_bar, workspace} = TabBar.add_workspace(tab_bar, "Remote Agent", old_session)

      tab_bar =
        tab_bar
        |> TabBar.update_tab(agent_tab.id, fn tab ->
          Tab.set_remote_session(tab, "home", remote_session_id, old_session)
        end)
        |> TabBar.move_tab_to_workspace(agent_tab.id, workspace.id)
        |> TabBar.update_workspace(workspace.id, &Workspace.set_session(&1, old_session))
        |> TabBar.switch_to(agent_tab.id)

      send(parent, {:workspace_id, workspace.id})
      EditorState.set_tab_bar(state, tab_bar)
    end)

    assert_receive {:workspace_id, workspace_id}
    workspace_id
  end
end
