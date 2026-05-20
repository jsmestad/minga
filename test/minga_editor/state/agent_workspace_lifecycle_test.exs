defmodule MingaEditor.State.AgentWorkspaceLifecycleTest do
  @moduledoc """
  Tests workspace ownership for agent session and UI state.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.State.Workspace
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window

  test "switching file tabs in a workspace preserves workspace agent UI" do
    state = state_with_agent_workspace_tabs()
    state = MingaEditor.State.AgentAccess.update_agent_ui(state, &put_prompt(&1, "draft one"))

    state = EditorState.switch_tab(state, 2)

    assert prompt_text(state.workspace.agent_ui) == "draft one"
    assert prompt_text(TabBar.active_workspace(state.shell_state.tab_bar).agent_ui) == "draft one"
  end

  test "switching to a workspace without agent UI clears the live mirror" do
    state = state_with_tabs()
    ui_two = put_prompt(UIState.new(), "workspace two")
    {tab_bar, workspace_two} = TabBar.add_workspace(state.shell_state.tab_bar, "Agent")

    tab_bar =
      tab_bar
      |> TabBar.move_tab_to_workspace(2, workspace_two.id)
      |> Map.put(:active_id, 2)
      |> TabBar.update_workspace(workspace_two.id, &Workspace.set_agent_ui(&1, ui_two))

    state = %{
      state
      | shell_state: %{state.shell_state | tab_bar: tab_bar},
        workspace: %{state.workspace | agent_ui: ui_two}
    }

    state = EditorState.switch_tab(state, 1)

    assert prompt_text(state.workspace.agent_ui) == ""
  end

  test "closing a workspace clears stale agent UI after tabs migrate to manual" do
    state = state_with_tabs()
    ui_two = put_prompt(UIState.new(), "workspace two")
    {tab_bar, workspace_two} = TabBar.add_workspace(state.shell_state.tab_bar, "Agent")

    tab_bar =
      tab_bar
      |> TabBar.move_tab_to_workspace(2, workspace_two.id)
      |> Map.put(:active_id, 2)
      |> TabBar.update_workspace(workspace_two.id, &Workspace.set_agent_ui(&1, ui_two))

    state = %{
      state
      | shell_state: %{state.shell_state | tab_bar: tab_bar},
        workspace: %{state.workspace | agent_ui: ui_two}
    }

    state = MingaEditor.Commands.Workspace.workspace_close(state)

    assert TabBar.active_workspace_id(state.shell_state.tab_bar) == 0
    assert prompt_text(state.workspace.agent_ui) == ""
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
      TabBar.add_workspace(state.shell_state.tab_bar, "Agent", session_two)

    workspace_one_id = TabBar.active_workspace_id(tab_bar)

    tab_bar =
      tab_bar
      |> TabBar.move_tab_to_workspace(2, workspace_two.id)
      |> TabBar.update_workspace(workspace_one_id, fn workspace ->
        workspace
        |> Workspace.set_session(session_one)
        |> Workspace.set_agent_ui(ui_one)
      end)
      |> TabBar.update_workspace(workspace_two.id, &Workspace.set_agent_ui(&1, ui_two))

    state = %{
      state
      | shell_state: %{state.shell_state | tab_bar: tab_bar},
        workspace: %{state.workspace | agent_ui: ui_one}
    }

    state = EditorState.switch_tab(state, 2)

    assert prompt_text(state.workspace.agent_ui) == "workspace two"
    assert MingaEditor.State.AgentAccess.session(state) == session_two
  end

  defp state_with_agent_workspace_tabs do
    state = state_with_tabs()
    {tab_bar, workspace} = TabBar.add_workspace(state.shell_state.tab_bar, "Agent")

    tab_bar =
      tab_bar
      |> TabBar.move_tab_to_workspace(1, workspace.id)
      |> TabBar.move_tab_to_workspace(2, workspace.id)
      |> TabBar.update_workspace(workspace.id, &Workspace.set_agent_ui(&1, UIState.new()))

    %{state | shell_state: %{state.shell_state | tab_bar: tab_bar}}
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
      port_manager: nil,
      shell: MingaEditor.Shell.Traditional,
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
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
      shell_state: %MingaEditor.Shell.Traditional.State{tab_bar: tab_bar}
    }
  end

  defp put_prompt(%UIState{} = ui, text) do
    ui = UIState.ensure_prompt_buffer(ui)
    BufferProcess.replace_content(ui.panel.prompt_buffer, text)
    ui
  end

  defp prompt_text(%UIState{} = ui), do: UIState.input_text(ui.panel)
end
