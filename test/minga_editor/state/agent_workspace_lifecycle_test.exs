defmodule MingaEditor.State.AgentWorkspaceLifecycleTest do
  @moduledoc """
  Tests workspace ownership for agent session and UI state.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef
  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.SessionManager
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.State.Workspace
  alias MingaEditor.VimState
  alias MingaEditor.Window

  test "switching file tabs in a workspace preserves workspace agent UI" do
    state = state_with_agent_workspace_tabs()

    state =
      MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
        state,
        (&put_prompt(&1, "draft one")).(state.workspace.agent_ui)
      )

    state = MingaEditor.TabWorkflow.switch(state, 2)

    assert prompt_text(state.workspace.agent_ui) == "draft one"

    assert prompt_text(TabBar.active_workspace(state.shell_runtime.state.tab_bar).agent_ui) ==
             "draft one"
  end

  test "switching to a workspace without agent UI clears the live mirror" do
    state = state_with_tabs()
    ui_two = put_prompt(UIState.new(), "workspace two")
    {tab_bar, workspace_two} = TabBar.add_workspace(state.shell_runtime.state.tab_bar, "Agent")

    tab_bar =
      tab_bar
      |> TabBar.move_tab_to_workspace(2, workspace_two.id)
      |> TabBar.switch_to(2)
      |> TabBar.set_workspace_agent_ui(workspace_two.id, ui_two)

    state =
      state
      |> then(fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tab_bar
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)
      |> then(fn state ->
        %{
          state
          | workspace:
              then(state.workspace, fn workspace ->
                MingaEditor.Session.State.set_agent_ui(workspace, ui_two)
              end)
        }
      end)

    state = MingaEditor.TabWorkflow.switch(state, 1)

    assert prompt_text(state.workspace.agent_ui) == ""
  end

  test "closing a workspace clears stale agent UI after tabs migrate to manual" do
    state = state_with_tabs()
    ui_two = put_prompt(UIState.new(), "workspace two")
    {tab_bar, workspace_two} = TabBar.add_workspace(state.shell_runtime.state.tab_bar, "Agent")

    tab_bar =
      tab_bar
      |> TabBar.move_tab_to_workspace(2, workspace_two.id)
      |> TabBar.switch_to(2)
      |> TabBar.set_workspace_agent_ui(workspace_two.id, ui_two)

    state =
      state
      |> then(fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tab_bar
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)
      |> then(fn state ->
        %{
          state
          | workspace:
              then(state.workspace, fn workspace ->
                MingaEditor.Session.State.set_agent_ui(workspace, ui_two)
              end)
        }
      end)

    state = MingaEditor.Commands.Workspace.workspace_close(state)

    assert TabBar.active_workspace_id(state.shell_runtime.state.tab_bar) == 0
    assert prompt_text(state.workspace.agent_ui) == ""
  end

  test "switching to inactive remote workspace drains queued catch-up once" do
    state = state_with_agent_workspace_tabs()
    initial_tab_id = TabBar.active(state.shell_runtime.state.tab_bar).id
    catchup = [EventRecord.new("remote-session", :message_changed, %{})]

    {tab_bar, agent_tab} = TabBar.add(state.shell_runtime.state.tab_bar, :agent, "Remote Agent")
    {tab_bar, remote_workspace} = TabBar.add_workspace(tab_bar, "Remote Agent")

    tab_bar =
      tab_bar
      |> TabBar.move_tab_to_workspace(agent_tab.id, remote_workspace.id)
      |> TabBar.set_workspace_agent_ui(remote_workspace.id, UIState.new())
      |> TabBar.set_workspace_pending_catchup_events(remote_workspace.id, catchup)
      |> TabBar.switch_to(initial_tab_id)

    state =
      then(state, fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tab_bar
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)

    initial_version = panel_message_version(state)

    state = MingaEditor.TabWorkflow.switch(state, agent_tab.id)

    drained_workspace =
      TabBar.get_workspace(state.shell_runtime.state.tab_bar, remote_workspace.id)

    first_version = panel_message_version(state)

    assert first_version == initial_version + 1
    assert drained_workspace.pending_catchup_events == []

    state = MingaEditor.TabWorkflow.switch(state, initial_tab_id)
    state = MingaEditor.TabWorkflow.switch(state, agent_tab.id)

    assert panel_message_version(state) == first_version

    assert TabBar.get_workspace(state.shell_runtime.state.tab_bar, remote_workspace.id).pending_catchup_events ==
             []
  end

  test "switching workspaces restores that workspace's agent UI and session" do
    state = state_with_agent_workspace_tabs()

    session_one =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    session_two =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ui_one = put_prompt(UIState.new(), "workspace one")
    ui_two = put_prompt(UIState.new(), "workspace two")

    {tab_bar, workspace_two} =
      TabBar.add_workspace(state.shell_runtime.state.tab_bar, "Agent", session_two)

    workspace_one_id = TabBar.active_workspace_id(tab_bar)

    tab_bar =
      tab_bar
      |> TabBar.move_tab_to_workspace(2, workspace_two.id)
      |> TabBar.set_workspace_session(workspace_one_id, session_one)
      |> TabBar.set_workspace_agent_ui(workspace_one_id, ui_one)
      |> TabBar.set_workspace_agent_ui(workspace_two.id, ui_two)

    state =
      state
      |> then(fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tab_bar
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)
      |> then(fn state ->
        %{
          state
          | workspace:
              then(state.workspace, fn workspace ->
                MingaEditor.Session.State.set_agent_ui(workspace, ui_one)
              end)
        }
      end)

    state = MingaEditor.TabWorkflow.switch(state, 2)

    assert prompt_text(state.workspace.agent_ui) == "workspace two"

    assert MingaEditor.Shell.Runtime.active_session(state.shell_runtime) ==
             session_two
  end

  test "restarting an active agent workspace reuses the workspace and preserves files and UI" do
    {:ok, _session_id, old_session} = SessionManager.start_session([])
    on_exit(fn -> stop_session(old_session) end)
    old_ref = Process.monitor(old_session)
    {state, workspace_id, file_ref} = state_with_active_agent_workspace(old_session)

    state = AgentSession.restart_session(state, "Restarting agent")
    new_session = MingaEditor.Shell.Runtime.active_session(state.shell_runtime)
    on_exit(fn -> stop_session(new_session) end)

    assert_receive {:DOWN, ^old_ref, :process, ^old_session, _reason}
    assert is_pid(new_session)
    refute new_session == old_session

    tab_bar = state.shell_runtime.state.tab_bar
    assert TabBar.active_workspace_id(tab_bar) == workspace_id
    workspace = TabBar.get_workspace(tab_bar, workspace_id)
    assert workspace.session == new_session
    assert workspace.files == [file_ref]
    assert prompt_text(workspace.agent_ui) == "restart draft"
    assert prompt_text(state.workspace.agent_ui) == "restart draft"
    assert TabBar.active(tab_bar).session == new_session
    assert Enum.count(tab_bar.workspaces, &(&1.kind == :agent)) == 1
  end

  test "restarting from a file tab reuses the active agent workspace" do
    {:ok, _session_id, old_session} = SessionManager.start_session([])
    on_exit(fn -> stop_session(old_session) end)
    old_ref = Process.monitor(old_session)
    {state, workspace_id, file_ref} = state_with_active_agent_workspace(old_session)
    agent_tab_id = TabBar.active(state.shell_runtime.state.tab_bar).id

    state = MingaEditor.TabWorkflow.switch(state, 1)
    assert TabBar.active(state.shell_runtime.state.tab_bar).kind == :file
    assert TabBar.active_workspace_id(state.shell_runtime.state.tab_bar) == workspace_id

    state = AgentSession.restart_session(state, "Restarting agent")
    new_session = MingaEditor.Shell.Runtime.active_session(state.shell_runtime)
    on_exit(fn -> stop_session(new_session) end)

    assert_receive {:DOWN, ^old_ref, :process, ^old_session, _reason}
    assert is_pid(new_session)
    refute new_session == old_session

    tab_bar = state.shell_runtime.state.tab_bar
    workspace = TabBar.get_workspace(tab_bar, workspace_id)
    agent_tab = TabBar.get(tab_bar, agent_tab_id)

    assert TabBar.active(tab_bar).kind == :file
    assert TabBar.active_workspace_id(tab_bar) == workspace_id
    assert workspace.session == new_session
    assert workspace.files == [file_ref]
    assert prompt_text(workspace.agent_ui) == "restart draft"
    assert prompt_text(state.workspace.agent_ui) == "restart draft"
    assert agent_tab.session == new_session
    refute Enum.any?(tab_bar.tabs, &(&1.session == old_session))
    refute Enum.any?(tab_bar.workspaces, &(&1.session == old_session))
    assert Enum.count(tab_bar.workspaces, &(&1.kind == :agent)) == 1
  end

  test "GUI workspace close stops the owned session and refreshes the live mirror" do
    {:ok, _session_id, session} = SessionManager.start_session([])
    on_exit(fn -> stop_session(session) end)
    ref = Process.monitor(session)
    {state, workspace_id, _file_ref} = state_with_active_agent_workspace(session)

    {shell_state, workspace} =
      Traditional.handle_gui_action(
        state.shell_runtime.state,
        state.workspace,
        {:workspace_close, workspace_id}
      )

    assert_receive {:DOWN, ^ref, :process, ^session, _reason}
    assert TabBar.get_workspace(shell_state.tab_bar, workspace_id) == nil
    assert TabBar.active_workspace_id(shell_state.tab_bar) == 0
    assert prompt_text(workspace.agent_ui) == ""
    assert SessionManager.session_id_for_pid(session) == {:error, :not_found}
  end

  test "session-down cleanup clears session and status while preserving draft and file membership" do
    session = self()
    {state, workspace_id, file_ref} = state_with_active_agent_workspace(session)

    state = BufferManagement.handle_agent_session_down(state, session, :shutdown)
    workspace = TabBar.get_workspace(state.shell_runtime.state.tab_bar, workspace_id)

    assert workspace.session == nil
    assert workspace.agent_status == :idle
    assert workspace.files == [file_ref]
    assert prompt_text(workspace.agent_ui) == "restart draft"
    assert prompt_text(state.workspace.agent_ui) == "restart draft"

    state = MingaEditor.TabWorkflow.switch(state, 2)
    assert prompt_text(state.workspace.agent_ui) == ""

    state = MingaEditor.TabWorkflow.switch(state, 3)
    assert prompt_text(state.workspace.agent_ui) == "restart draft"
  end

  test "closing a file tab preserves workspace file membership until workspace close" do
    {:ok, _session_id, session} = SessionManager.start_session([])
    on_exit(fn -> stop_session(session) end)
    {state, workspace_id, file_ref} = state_with_active_agent_workspace(session)
    state = MingaEditor.TabWorkflow.switch(state, 1)

    state = BufferManagement.execute(state, :force_quit)
    tab_bar = state.shell_runtime.state.tab_bar
    workspace = TabBar.get_workspace(tab_bar, workspace_id)

    assert TabBar.get(tab_bar, 1) == nil
    assert workspace.files == [file_ref]

    state = MingaEditor.Commands.Workspace.workspace_close(state)
    workspace = TabBar.get_workspace(state.shell_runtime.state.tab_bar, workspace_id)

    assert workspace.session == session
    assert workspace.files == [file_ref]

    assert state.shell_runtime.state.notice.message ==
             "Stop the agent session before closing this workspace"
  end

  test "closing a remote agent workspace stops the session and scrubs migrated tab projections" do
    {:ok, _session_id, session} = SessionManager.start_session([])
    ref = Process.monitor(session)

    {state, workspace_id, _file_ref, agent_tab_id} =
      state_with_active_remote_agent_workspace(session)

    state = MingaEditor.Commands.Workspace.workspace_close(state)
    assert_receive {:DOWN, ^ref, :process, ^session, _reason}

    tab_bar = state.shell_runtime.state.tab_bar
    agent_tab = TabBar.get(tab_bar, agent_tab_id)

    assert TabBar.get_workspace(tab_bar, workspace_id) == nil
    assert agent_tab.group_id == 0
    assert agent_tab.session == nil
    assert agent_tab.server_name == nil
    assert agent_tab.remote_session_id == nil
    assert agent_tab.connection_status == nil
    assert agent_tab.agent_status == nil
    refute agent_tab.attention
  end

  test "closing the agent tab preserves workspace files draft and remote metadata" do
    {:ok, _session_id, session} = SessionManager.start_session([])
    on_exit(fn -> stop_session(session) end)

    {state, workspace_id, file_ref, agent_tab_id} =
      state_with_active_remote_agent_workspace(session)

    state = BufferManagement.execute(state, :force_quit)
    tab_bar = state.shell_runtime.state.tab_bar
    workspace = TabBar.get_workspace(tab_bar, workspace_id)

    assert TabBar.get(tab_bar, agent_tab_id) == nil
    assert workspace.session == session
    assert workspace.files == [file_ref]
    assert prompt_text(workspace.agent_ui) == "restart draft"
    assert workspace.remote_session.server_name == "home"
    assert workspace.remote_session.session_id == "session-1"
    assert workspace.remote_session.connection_status == :connected
  end

  test "stop_current_session from file tab after closing remote agent tab routes through workspace metadata" do
    {:ok, session_id, session} = SessionManager.start_session([])
    on_exit(fn -> stop_session(session) end)
    ref = Process.monitor(session)

    {state, workspace_id, file_ref, agent_tab_id} =
      state_with_active_remote_agent_workspace(session, session_id)

    state =
      state
      |> BufferManagement.execute(:force_quit)
      |> MingaEditor.TabWorkflow.switch(1)

    tab_bar = state.shell_runtime.state.tab_bar
    workspace = TabBar.get_workspace(tab_bar, workspace_id)

    assert TabBar.get(tab_bar, agent_tab_id) == nil
    assert TabBar.active(tab_bar).kind == :file
    assert TabBar.active_workspace_id(tab_bar) == workspace_id
    assert workspace.session == session
    assert workspace.remote_session.session_id == session_id

    state = AgentSession.stop_current_session(state)
    assert_receive {:DOWN, ^ref, :process, ^session, _reason}

    state = BufferManagement.handle_agent_session_down(state, session, :normal)
    workspace = TabBar.get_workspace(state.shell_runtime.state.tab_bar, workspace_id)

    assert workspace.session == nil
    assert workspace.agent_status == :idle
    assert workspace.files == [file_ref]
    assert prompt_text(workspace.agent_ui) == "restart draft"
    assert workspace.remote_session.server_name == "home"
    assert workspace.remote_session.session_id == session_id
    assert workspace.remote_session.connection_status == :connected
    refute Enum.any?(state.shell_runtime.state.tab_bar.tabs, &(&1.kind == :agent))
  end

  test "stop_current_session from file tab stops workspace session and preserves files and draft after cleanup" do
    {:ok, _session_id, session} = SessionManager.start_session([])
    ref = Process.monitor(session)
    {state, workspace_id, file_ref} = state_with_active_agent_workspace(session)
    state = MingaEditor.TabWorkflow.switch(state, 1)

    state = AgentSession.stop_current_session(state)
    assert_receive {:DOWN, ^ref, :process, ^session, _reason}

    state = BufferManagement.handle_agent_session_down(state, session, :shutdown)
    workspace = TabBar.get_workspace(state.shell_runtime.state.tab_bar, workspace_id)

    assert workspace.session == nil
    assert workspace.files == [file_ref]
    assert prompt_text(workspace.agent_ui) == "restart draft"
  end

  defp state_with_agent_workspace_tabs do
    state = state_with_tabs()
    {tab_bar, workspace} = TabBar.add_workspace(state.shell_runtime.state.tab_bar, "Agent")

    tab_bar =
      tab_bar
      |> TabBar.move_tab_to_workspace(1, workspace.id)
      |> TabBar.move_tab_to_workspace(2, workspace.id)
      |> TabBar.set_workspace_agent_ui(workspace.id, UIState.new())

    then(state, fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.install_tab_bar(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          tab_bar
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
  end

  defp state_with_active_agent_workspace(session) when is_pid(session) do
    state = state_with_tabs()
    file_ref = FileRef.from_buffer(state.workspace.buffers.active)
    ui = UIState.new() |> put_prompt("restart draft") |> show_panel()

    {tab_bar, agent_tab} = TabBar.add(state.shell_runtime.state.tab_bar, :agent, "Agent")
    {tab_bar, workspace} = TabBar.add_workspace(tab_bar, "Agent", session)

    tab_bar =
      tab_bar
      |> TabBar.set_tab_session(agent_tab.id, session)
      |> TabBar.move_tab_to_workspace(1, workspace.id)
      |> TabBar.move_tab_to_workspace(agent_tab.id, workspace.id)
      |> TabBar.add_workspace_file(workspace.id, file_ref)
      |> TabBar.set_workspace_agent_ui(workspace.id, ui)
      |> TabBar.switch_to(agent_tab.id)

    state =
      state
      |> then(fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tab_bar
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)
      |> then(fn state ->
        %{
          state
          | workspace:
              then(state.workspace, fn workspace ->
                MingaEditor.Session.State.set_agent_ui(workspace, ui)
              end)
        }
      end)

    {state, workspace.id, file_ref}
  end

  defp state_with_active_remote_agent_workspace(session, remote_session_id \\ "session-1")
       when is_pid(session) and is_binary(remote_session_id) do
    {state, workspace_id, file_ref} = state_with_active_agent_workspace(session)
    agent_tab_id = TabBar.active(state.shell_runtime.state.tab_bar).id

    tab_bar = state.shell_runtime.state.tab_bar

    workspace =
      tab_bar
      |> TabBar.get_workspace(workspace_id)
      |> Workspace.put_remote_session("home", remote_session_id, :connected)

    tab_bar =
      tab_bar
      |> TabBar.accept_workspace(workspace)
      |> TabBar.sync_workspace_agent_tab_projection(workspace_id)

    state =
      then(state, fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tab_bar
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)

    {state, workspace_id, file_ref, agent_tab_id}
  end

  defp state_with_tabs do
    {:ok, buf_one} = BufferProcess.start_link(content: "one")
    {:ok, buf_two} = BufferProcess.start_link(content: "two")

    tab_one = Tab.new_file(1, "one")
    tab_two = Tab.new_file(2, "two")

    tab_bar = %TabBar{
      tabs: [tab_one, tab_two],
      active_id: 1,
      next_id: 3,
      workspaces: [Workspace.new_manual(nil)],
      next_workspace_id: 1
    }

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %MingaEditor.Session.State{
        editing: VimState.new(),
        buffers: %Buffers{active: buf_one, list: [buf_one, buf_two], active_index: 0},
        windows: %Windows{
          tree: {:leaf, 1},
          map: %{1 => Window.new(1, buf_one, 24, 80)},
          active: 1,
          next_id: 2
        },
        agent_ui: UIState.new()
      },
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          %MingaEditor.Shell.Traditional.State{tab_bar: tab_bar}
        )
    }
  end

  defp put_prompt(%UIState{} = ui, text) do
    ui = MingaEditor.Agent.PromptBuffer.ensure(ui)
    BufferProcess.replace_content(ui.panel.prompt_buffer, text)
    ui
  end

  defp show_panel(%UIState{} = ui) do
    %{ui | panel: %{ui.panel | visible: true}}
  end

  defp panel_message_version(state), do: state.workspace.agent_ui.panel.message_version

  defp stop_session(pid) when is_pid(pid) do
    AgentSession.stop_session_pid(pid)
  end

  defp stop_session(_pid), do: :ok

  defp prompt_text(%UIState{} = ui), do: MingaEditor.Agent.PromptBuffer.input_text(ui.panel)
end
