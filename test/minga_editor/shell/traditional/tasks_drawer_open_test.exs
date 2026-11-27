defmodule MingaEditor.Shell.Traditional.TasksDrawerOpenTest do
  @moduledoc """
  Where the drawer's ↩ and i take you: the exact conversation comes to the front and the drawer lets go of the keyboard.
  """

  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.TasksDrawerEncoder
  alias Minga.Protocol.Opcodes
  alias MingaAgent.Event.ToolStart
  alias MingaAgent.Session.{ConnectionSnapshot, ConnectionTarget}
  alias MingaEditor.Agent.TaskWorkflow
  alias MingaEditor.Frontend.Protocol.GUI
  alias MingaEditor.RenderModel.UI.TasksDrawerBuilder
  alias MingaEditor.Shell.Traditional.Drawers
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.TasksDrawerWorkflow
  alias MingaEditor.State.TabBar
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

  test "Inspect reports a missing parent conversation without leaving the drawer" do
    state = unplaced_child()
    row = child_row(state, "Audit the previous draft")
    next = TasksDrawerWorkflow.click(state, row, "i")

    assert TasksDrawerWorkflow.focused?(next)
    assert active_workspace_id(next) == active_workspace_id(state)
    assert NoticeWorkflow.message(next) =~ "parent conversation in this window"
  end

  test "a delayed Inspect click cannot act on a new child after the old row disappears" do
    state = unplaced_child()
    vanished = child_row(state, "Audit the previous draft")

    state =
      state
      |> connect("new-record")
      |> observe_child("Audit the previous draft")

    replacement = child_row(state, "Audit the previous draft")
    assert replacement != vanished
    state = TasksDrawerWorkflow.select(state, replacement)

    next = TasksDrawerWorkflow.click(state, vanished, "i")
    assert TasksDrawerWorkflow.focused?(next)
    assert NoticeWorkflow.message(next) == NoticeWorkflow.message(state)
    assert drawers(next).selected == replacement
  end

  test "the drawer and click wire preserve a child whose provider call id is too long for a row id" do
    call = String.duplicate("x", 512)
    state = unplaced_child(call)

    model =
      TasksDrawerBuilder.build(
        state.agent_connection.tasks,
        drawers(state),
        System.os_time(:millisecond)
      )

    [%{depth: 0}, %{depth: 1, id: row, actions: [{"i", "Inspect"}]}] = model.rows
    size = byte_size(row)
    assert size <= 255

    assert :binary.match(TasksDrawerEncoder.encode_command(model), <<size, row::binary>>) !=
             :nomatch

    assert {:ok, {:tasks_drawer_action, ^row, "i"}} =
             GUI.decode_gui_action(
               Opcodes.gui_action_tasks_drawer_action(),
               <<size, row::binary, 1, "i">>
             )

    assert {pid, {"old-record", {"request", "checkpoint", ^call}}} =
             TasksDrawerBuilder.inspect_target(state.agent_connection.tasks, row)

    assert pid == self()
  end

  defp unplaced_child(call \\ "Audit the previous draft") do
    ScopedInputHelpers.base_state(keymap_scope: :editor, agentic_active: false)
    |> TaskWorkflow.follow(self(), title: "Review the draft")
    |> connect("old-record")
    |> observe_child(call)
    |> TasksDrawerWorkflow.open()
  end

  defp connect(state, record, session \\ self()) do
    facts = %ConnectionSnapshot{
      target: ConnectionTarget.new(session, record, nil, make_ref()),
      credential_readiness: :configured,
      provider_phase: :running,
      model_selection: nil,
      operation: :idle,
      problem: nil
    }

    TaskWorkflow.observe(state, session, {:connection_changed, facts})
  end

  defp observe_child(state, title) do
    event = %ToolStart{
      name: "subagent",
      tool_call_id: title,
      invocation_key: {"request", "checkpoint", title},
      args: %{"task" => title}
    }

    TaskWorkflow.observe(state, self(), {:tool_started, event})
  end

  defp child_row(state, title) do
    model =
      TasksDrawerBuilder.build(
        state.agent_connection.tasks,
        drawers(state),
        System.os_time(:millisecond)
      )

    Enum.find(model.rows, &(&1.title == title)).id
  end

  test "↩ on a done task with no live connection does not review another task" do
    {state, agent_id} = state_with_task([{:status_changed, :thinking}, {:status_changed, :idle}])

    state = TasksDrawerWorkflow.run(state, :tasks_open)

    assert active_workspace_id(state) == agent_id

    assert NoticeWorkflow.message(state) == "That task's review is not connected"
  end

  test "stale Review activation leaves the drawer open after its session loads another conversation" do
    {state, agent_id} = state_with_task([{:status_changed, :thinking}, {:status_changed, :idle}])
    [row] = TasksDrawerBuilder.row_ids(state.agent_connection.tasks)
    %{pid: session} = TasksDrawerBuilder.entry_for(state.agent_connection.tasks, row)
    before = connect(state, "first-record", session)
    [displayed] = TasksDrawerBuilder.row_ids(before.agent_connection.tasks)

    after_rebind =
      before
      |> TasksDrawerWorkflow.select(displayed)
      |> connect("second-record", session)

    for ignored <- [
          TasksDrawerWorkflow.click(after_rebind, displayed, "↩"),
          TasksDrawerWorkflow.run(after_rebind, :tasks_open)
        ] do
      assert TasksDrawerWorkflow.focused?(ignored)
      refute active_workspace_id(ignored) == agent_id
    end

    [current] = TasksDrawerBuilder.row_ids(after_rebind.agent_connection.tasks)

    opened =
      after_rebind
      |> TasksDrawerWorkflow.select(current)
      |> TasksDrawerWorkflow.run(:tasks_open)

    assert active_workspace_id(opened) == agent_id
    refute TasksDrawerWorkflow.focused?(opened)
  end
end
