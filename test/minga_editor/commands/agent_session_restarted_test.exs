defmodule MingaEditor.Commands.AgentSessionRestartedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Minga.Test.StubProvider
  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaAgent.SessionManager.SessionRestartedEvent
  alias MingaAgent.Subagent.Handle
  alias MingaEditor.Handlers.EventDispatcher
  alias MingaEditor.Session.State, as: WorkspaceState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace, as: WorkspaceModel
  alias MingaEditor.Viewport

  defp build_state(old_pid, child_pid) do
    state = %EditorState{
      port_manager: nil,
      workspace: %WorkspaceState{viewport: Viewport.new(80, 24)}
    }

    {tb, workspace} =
      TabBar.add_workspace(TabBar.new(Tab.new_file(1, "scratch")), "Agent", old_pid)

    {tb, agent_tab} = TabBar.add(tb, :agent, "Agent")

    handle =
      Handle.new(
        session_id: "bg-session",
        pid: child_pid,
        parent_session_id: "parent-session",
        parent_pid: old_pid,
        task: "child task",
        started_at: DateTime.utc_now()
      )

    tb =
      tb
      |> TabBar.update_tab(agent_tab.id, &Tab.set_session(&1, old_pid))
      |> TabBar.update_tab(agent_tab.id, &Tab.set_agent_status(&1, :thinking))
      |> TabBar.update_tab(agent_tab.id, &Tab.set_group(&1, workspace.id))
      |> TabBar.update_tab(agent_tab.id, &Tab.mark_background_subagent(&1, handle))
      |> TabBar.update_workspace(workspace.id, fn workspace ->
        workspace
        |> WorkspaceModel.set_session(old_pid)
        |> WorkspaceModel.set_agent_status(:thinking)
      end)

    EditorState.set_tab_bar(state, tb)
  end

  test "restarts re-subscribe, refreshes session refs, and updates background handles" do
    old_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    child_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      Process.exit(old_pid, :kill)
      Process.exit(child_pid, :kill)
    end)

    session_id = "session-#{System.unique_integer([:positive])}"

    {:ok, ^session_id, new_pid} =
      SessionManager.start_session(
        session_id: session_id,
        provider: StubProvider,
        provider_opts: []
      )

    state = build_state(old_pid, child_pid)

    payload = %SessionRestartedEvent{
      session_id: session_id,
      old_pid: old_pid,
      new_pid: new_pid,
      reason: :killed
    }

    assert Session.subscriber_role(new_pid, self()) == nil

    updated = EventDispatcher.dispatch(state, :agent_session_restarted, payload, :message)

    assert Session.subscriber_role(new_pid, self()) == :driver

    active_tab = TabBar.active(updated.shell_state.tab_bar)
    assert active_tab.session == new_pid
    assert active_tab.agent_status == :idle
    assert active_tab.background_subagent.pid == child_pid
    assert active_tab.background_subagent.parent_pid == new_pid

    workspace = TabBar.find_workspace_by_session(updated.shell_state.tab_bar, new_pid)
    assert workspace.session == new_pid
    assert workspace.agent_status == :idle
    refute TabBar.find_workspace_by_session(updated.shell_state.tab_bar, old_pid)
    refute_receive {:minga_event, :agent_session_stopped, _}, 50
  end

  test "ignores stale restart events when SessionManager points to a different live pid" do
    owned_old_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    child_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      Process.exit(owned_old_pid, :kill)
      Process.exit(child_pid, :kill)
    end)

    session_id = "session-#{System.unique_integer([:positive])}"

    {:ok, ^session_id, live_pid_b} =
      SessionManager.start_session(
        session_id: session_id,
        provider: StubProvider,
        provider_opts: []
      )

    {:ok, _other_session_id, live_pid_a} =
      SessionManager.start_session(
        session_id: "other-live-#{System.unique_integer([:positive])}",
        provider: StubProvider,
        provider_opts: []
      )

    on_exit(fn ->
      Process.exit(live_pid_a, :kill)
      Process.exit(live_pid_b, :kill)
    end)

    state = build_state(owned_old_pid, child_pid)

    payload = %SessionRestartedEvent{
      session_id: session_id,
      old_pid: owned_old_pid,
      new_pid: live_pid_a,
      reason: :killed
    }

    log =
      capture_log(fn ->
        updated = EventDispatcher.dispatch(state, :agent_session_restarted, payload, :message)
        assert updated == state
      end)

    assert Session.subscriber_role(live_pid_a, self()) == nil
    assert Session.subscriber_role(live_pid_b, self()) == nil
    assert log =~ session_id
    assert log =~ inspect(owned_old_pid)
    assert log =~ inspect(live_pid_a)
    assert log =~ "current_pid"
  end

  test "ignores unowned restart events without subscribing the new pid" do
    owned_old_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    child_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    unowned_old_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      Process.exit(owned_old_pid, :kill)
      Process.exit(child_pid, :kill)
      Process.exit(unowned_old_pid, :kill)
    end)

    session_id = "session-#{System.unique_integer([:positive])}"

    {:ok, ^session_id, new_pid} =
      SessionManager.start_session(
        session_id: session_id,
        provider: StubProvider,
        provider_opts: []
      )

    state = build_state(owned_old_pid, child_pid)

    payload = %SessionRestartedEvent{
      session_id: session_id,
      old_pid: unowned_old_pid,
      new_pid: new_pid,
      reason: :killed
    }

    log =
      capture_log(fn ->
        updated = EventDispatcher.dispatch(state, :agent_session_restarted, payload, :message)
        assert updated == state
      end)

    assert Session.subscriber_role(new_pid, self()) == nil
    assert log =~ inspect(unowned_old_pid)
    assert log =~ inspect(new_pid)
    assert log =~ "unowned_old_pid"
  end

  test "ignores stale restart events when the replacement pid is already dead" do
    old_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    child_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      Process.exit(old_pid, :kill)
      Process.exit(child_pid, :kill)
    end)

    dead_new_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(dead_new_pid)
    send(dead_new_pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^dead_new_pid, :normal}

    state = build_state(old_pid, child_pid)
    session_id = "session-#{System.unique_integer([:positive])}"

    payload = %SessionRestartedEvent{
      session_id: session_id,
      old_pid: old_pid,
      new_pid: dead_new_pid,
      reason: :killed
    }

    log =
      capture_log(fn ->
        updated = EventDispatcher.dispatch(state, :agent_session_restarted, payload, :message)
        assert updated == state
      end)

    assert log =~ session_id
    assert log =~ inspect(old_pid)
    assert log =~ inspect(dead_new_pid)
    assert log =~ "not_found"
  end
end
