defmodule MingaEditor.Agent.EditPublicationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Test.StubServer
  alias MingaAgent.ProjectView
  alias MingaEditor.Agent.EditPublication
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.NotificationCenter
  alias MingaEditor.Window

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "notes.md")
    File.write!(path, "one\ntwo\n")
    buffer = start_supervised!({BufferProcess, content: File.read!(path), file_path: path})
    session = start_supervised!({StubServer, []})
    {:ok, view} = ProjectView.overlay(dir)

    file_tab = Tab.new_file(1, "notes.md")
    agent_tab = %{Tab.new_agent(2, "Agent") | group_id: 1}
    tb = %{TabBar.new(file_tab, dir) | tabs: [file_tab, agent_tab], active_id: 2, next_id: 3}
    {tb, workspace} = TabBar.add_workspace(tb, "Agent", session)
    tb = TabBar.set_workspace_project_view(tb, workspace.id, view)

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %SessionState{
        buffers: %Buffers{active: buffer, list: [buffer]},
        windows: %Windows{
          tree: {:leaf, 1},
          map: %{1 => Window.new(1, buffer, 24, 80)},
          active: 1,
          next_id: 2
        }
      },
      shell_runtime: Runtime.new(Runtime.default_entry(), %TraditionalState{tab_bar: tb})
    }

    %{state: state, session: session, view: view, path: path, workspace_id: workspace.id}
  end

  defp workspace(state, id), do: TabBar.get_workspace(state.shell_runtime.state.tab_bar, id)

  defp stage_edit(view) do
    {:ok, source} = ProjectView.resolve_source(view, "notes.md")
    {:ok, content} = ProjectView.read_file(view, "notes.md")
    token = Minga.Buffer.FileMutation.revision(content, nil, {:project_view, source.source_id})
    {:ok, _} = ProjectView.conditional_mutate(view, "notes.md", token, {:edit, [{"two", "TWO"}]})
    :ok
  end

  defp notification(state, id),
    do: NotificationCenter.find(state.feedback.notifications, "agent:unpublished_edits:#{id}")

  test "an agent edit drafts the session's workspace and the finished turn offers Publish and Discard",
       %{state: state, session: session, path: path, workspace_id: id} do
    state = EditPublication.record_edit(state, session, path)

    assert %{state: :draft, changed_files: [%{relative_path: "notes.md"}]} =
             workspace(state, id).review

    assert notification(state, id) == nil

    state = EditPublication.turn_finished(state, session)
    assert workspace(state, id).review.state == :needs_review

    card = notification(state, id)
    assert card.title == "1 agent-edited file is not on disk"
    assert card.dismissable

    assert [
             %{
               id: "publish",
               label: "Publish",
               dispatch: {:command, {:agent_edits_publish, ^id}}
             },
             %{id: "discard", label: "Discard", dispatch: {:command, {:agent_edits_discard, ^id}}}
           ] = card.actions

    # Idle events repeat; only the drafting-to-review transition notifies.
    dismissed = %{
      state
      | feedback:
          MingaEditor.State.Feedback.dismiss_notification(
            state.feedback,
            "agent:unpublished_edits:#{id}"
          )
    }

    assert notification(EditPublication.turn_finished(dismissed, session), id) == nil
  end

  test "edits from a session without an editor-owned view are not tracked",
       %{state: state, path: path, workspace_id: id} do
    other_session = start_supervised!(Supervisor.child_spec({StubServer, []}, id: :other))

    assert EditPublication.record_edit(state, other_session, path) == state
    assert EditPublication.record_edit(state, nil, path) == state
    assert workspace(state, id).review.state == :clean
  end

  test "clicking the notification's Publish action publishes that workspace",
       %{state: state, session: session, view: view, path: path, workspace_id: id} do
    :ok = stage_edit(view)

    state =
      state
      |> EditPublication.record_edit(session, path)
      |> EditPublication.turn_finished(session)

    result =
      GuiActionHandler.dispatch(
        state,
        {:notification_action, "agent:unpublished_edits:#{id}", "publish"}
      )

    assert File.read!(path) == "one\nTWO\n"
    assert NoticeWorkflow.message(result) == "Published agent edits in 1 file to disk"
    assert notification(result, id) == nil
    assert workspace(result, id).review.state == :clean
  end

  test "clicking the notification's Discard action drops the staged edit",
       %{state: state, session: session, view: view, path: path, workspace_id: id} do
    :ok = stage_edit(view)

    state =
      state
      |> EditPublication.record_edit(session, path)
      |> EditPublication.turn_finished(session)

    result =
      GuiActionHandler.dispatch(
        state,
        {:notification_action, "agent:unpublished_edits:#{id}", "discard"}
      )

    assert File.read!(path) == "one\ntwo\n"
    assert NoticeWorkflow.message(result) == "Discarded agent edits in 1 file"
    assert workspace(result, id).review.state == :clean
  end

  test "before_quit passes with nothing staged and blocks with staged edits",
       %{state: state, view: view, workspace_id: id} do
    assert {:ok, ^state} = EditPublication.before_quit(state)

    :ok = stage_edit(view)
    assert {:blocked, blocked} = EditPublication.before_quit(state)

    assert NoticeWorkflow.message(blocked) ==
             "1 agent-edited file is not on disk. Publish (SPC a p) or discard (SPC a P) them before quitting, or use :qa! to discard them."

    assert notification(blocked, id).title == "1 agent-edited file is not on disk"
    assert workspace(blocked, id).review.state == :needs_review
  end
end
