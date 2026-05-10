defmodule MingaEditor.StatusBar.DataTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Subagent.Handle
  alias MingaEditor.StatusBar.Data
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Viewport
  alias MingaEditor.Workspace.State, as: WorkspaceState

  test "projects running background subagent count and active label" do
    handle1 = handle("session-2", "tests")
    handle2 = handle("session-3", "docs")

    tb = TabBar.new(Tab.new_file(1, "main.ex"))
    {tb, tab1} = TabBar.add(tb, :agent, "subagent tests")

    tb =
      TabBar.update_tab(tb, tab1.id, fn tab ->
        tab
        |> Tab.set_session(handle1.pid)
        |> Tab.set_agent_status(:thinking)
        |> Tab.mark_background_subagent(handle1)
      end)

    {tb, tab2} = TabBar.add(tb, :agent, "subagent docs")

    tb =
      TabBar.update_tab(tb, tab2.id, fn tab ->
        tab
        |> Tab.set_session(handle2.pid)
        |> Tab.set_agent_status(:idle)
        |> Tab.mark_background_subagent(handle2)
      end)

    state = state_with_tab_bar(TabBar.switch_to(tb, tab1.id))
    data = Data.from_state(state) |> Data.to_modeline_data()

    assert data.background_subagent_count == 1
    assert data.active_background_subagent_label == "session-2: tests"
  end

  defp state_with_tab_bar(tab_bar) do
    %EditorState{
      port_manager: self(),
      workspace: %WorkspaceState{viewport: Viewport.new(24, 80)},
      shell_state: %MingaEditor.Shell.Traditional.State{tab_bar: tab_bar}
    }
  end

  defp handle(session_id, task) do
    Handle.new(session_id: session_id, pid: self(), task: task, started_at: DateTime.utc_now())
  end
end
