defmodule MingaEditor.Shell.Traditional.TasksDrawerOpenTest do
  @moduledoc """
  Where the drawer's ↩ and i take you: a task's conversation comes to the front and the drawer lets go of the keyboard; a done task opens its pending reviews.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Agent.TaskWorkflow
  alias MingaEditor.Shell.Traditional.Drawers
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.TasksDrawerWorkflow
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Picker.PendingReviewsSource
  alias Minga.Test.ScopedInputHelpers

  # A file workspace in front and an agent workspace whose session has a task in `events`' state.
  defp state_with_task(events) do
    {state, session, _file} = ScopedInputHelpers.activated_agent_state()
    agent_id = TabBar.active_workspace(state.shell_runtime.state.tab_bar).id
    state = MingaEditor.Commands.Workspace.workspace_goto_by_id(state, 0)

    state =
      Enum.reduce(
        [{:title_changed, "Add tests"} | events],
        TaskWorkflow.follow(state, session),
        &TaskWorkflow.observe(&2, session, &1)
      )

    {TasksDrawerWorkflow.open(state), agent_id}
  end

  defp active_workspace_id(state),
    do: TabBar.active_workspace(state.shell_runtime.state.tab_bar).id

  defp drawers(state), do: TraditionalState.drawers(state.shell_runtime.state)

  test "↩ on a working task brings its conversation to the front and closes the drawer" do
    {state, agent_id} = state_with_task([{:status_changed, :thinking}])
    refute active_workspace_id(state) == agent_id

    state = TasksDrawerWorkflow.run(state, :tasks_open)

    assert active_workspace_id(state) == agent_id
    refute Drawers.showing?(drawers(state), :tasks)
    refute TasksDrawerWorkflow.focused?(state)
  end

  test "i inspects a task by opening its conversation" do
    {state, agent_id} = state_with_task([{:status_changed, :thinking}])

    state = TasksDrawerWorkflow.run(state, :tasks_inspect)

    assert active_workspace_id(state) == agent_id
    refute Drawers.showing?(drawers(state), :tasks)
  end

  test "↩ on a done task opens its conversation with the pending reviews" do
    {state, agent_id} = state_with_task([{:status_changed, :thinking}, {:status_changed, :idle}])

    state = TasksDrawerWorkflow.run(state, :tasks_open)

    assert active_workspace_id(state) == agent_id

    assert {:picker, %{picker_ui: %{source: PendingReviewsSource}}} =
             state.shell_runtime.state.modal
  end
end
