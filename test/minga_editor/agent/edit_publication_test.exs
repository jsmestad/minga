defmodule MingaEditor.Agent.EditPublicationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Test.StubServer
  alias MingaAgent.ProjectView
  alias MingaAgent.ProjectView.Overlay
  alias MingaAgent.StagedDraftKeeper
  alias MingaAgent.StagedDraftKeeper.Recovery
  alias MingaEditor.Agent.EditPublication
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree
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
        file_tree: FileTree.set_project_root(%FileTree{}, dir),
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

    %{
      state: state,
      session: session,
      view: view,
      path: path,
      workspace_id: workspace.id,
      root: Path.expand(dir)
    }
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

  test "publishing an edit to a file open through a symlink updates that buffer and leaves it saved",
       %{state: state, session: session, view: view, root: root, workspace_id: id} do
    real = Path.join(root, "real.md")
    File.write!(real, "one\ntwo\n")
    File.ln_s!("real.md", Path.join(root, "link.md"))
    linked = start_supervised!({BufferProcess, file_path: Path.join(root, "link.md")}, id: :link)

    {:ok, source} = ProjectView.resolve_source(view, "real.md")

    token =
      Minga.Buffer.FileMutation.revision("one\ntwo\n", nil, {:project_view, source.source_id})

    {:ok, _} = ProjectView.conditional_mutate(view, "real.md", token, {:edit, [{"two", "TWO"}]})

    state =
      state
      |> EditPublication.record_edit(session, real)
      |> EditPublication.turn_finished(session)

    GuiActionHandler.dispatch(
      state,
      {:notification_action, "agent:unpublished_edits:#{id}", "publish"}
    )

    assert File.read!(real) == "one\nTWO\n"
    assert BufferProcess.content(linked) == "one\nTWO\n"
    refute BufferProcess.dirty?(linked)
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
             "1 agent-edited file is not on disk. Publish (SPC a p) or discard (SPC a P) them before quitting. :qa!, :q! and :cq quit and discard them."

    assert notification(blocked, id).title == "1 agent-edited file is not on disk"
    assert workspace(blocked, id).review.state == :needs_review
  end

  describe "staged edits after a restart" do
    # A restarted Editor restores its workspaces from disk without a staging
    # area or session.
    defp restarted(state, id) do
      tb =
        state.shell_runtime.state.tab_bar
        |> TabBar.set_workspace_project_view(id, nil)
        |> TabBar.clear_workspace_session(id)

      %{
        state
        | shell_runtime: Runtime.new(Runtime.default_entry(), %TraditionalState{tab_bar: tb})
      }
    end

    test "after an Editor restart the surviving view returns to its workspace and publishes",
         %{state: state, view: view, path: path, workspace_id: id, root: root} do
      :ok = stage_edit(view)
      {:ok, changes} = ProjectView.diff(view)
      state = restarted(state, id)

      assert EditPublication.publish(state, id) |> NoticeWorkflow.message() ==
               "No unpublished agent edits"

      state = EditPublication.recovered(state, root, [Recovery.live(id, view, changes)])

      assert workspace(state, id).review.state == :needs_review
      assert notification(state, id).title == "1 agent-edited file is not on disk"

      published = EditPublication.publish(state, id)
      assert File.read!(path) == "one\nTWO\n"
      assert NoticeWorkflow.message(published) == "Published agent edits in 1 file to disk"
    end

    test "after a full restart the saved drafts are offered and can be discarded",
         %{state: state, workspace_id: id, root: root, tmp_dir: dir} do
      scope = :"publication_views_#{System.unique_integer([:positive])}"
      start_supervised!(%{id: scope, start: {:pg, :start_link, [scope]}})
      # One simulated Minga instance: finding the real identity runs `ps`.
      instance = %{os_pid: 101, started: "Sun Nov 22 09:00:00 2026"}

      store = [
        staged_drafts_dir: Path.join(dir, "store"),
        scope: scope,
        instance: instance,
        instance_alive?: fn _owner -> false end
      ]

      File.write!(Path.join(root, "todo.md"), "a\nb\n")
      keeper = start_supervised!({StagedDraftKeeper, [name: nil] ++ store}, id: :before)

      {:ok, view} = ProjectView.overlay(root)
      :ok = ProjectView.write_file(view, "todo.md", "a\nB\n")
      StagedDraftKeeper.persist(keeper, view, id)
      :sys.get_state(keeper)

      # Shutdown order: the keeper stops first, then the agent supervisor.
      changeset = Overlay.changeset_pid(view)
      ref = Process.monitor(changeset)
      stop_supervised!(:before)
      Process.exit(changeset, :shutdown)
      assert_receive {:DOWN, ^ref, :process, _, :shutdown}

      keeper = start_supervised!({StagedDraftKeeper, [name: nil] ++ store}, id: :after)
      :ok = StagedDraftKeeper.recover(keeper, root, self())
      assert_receive {:staged_drafts_recovered, ^root, recoveries}, 2_000

      state = EditPublication.recovered(restarted(state, id), root, recoveries)

      assert [%{relative_path: "todo.md"}] = workspace(state, id).review.changed_files
      assert notification(state, id).title == "1 agent-edited file is not on disk"

      discarded =
        GuiActionHandler.dispatch(
          state,
          {:notification_action, "agent:unpublished_edits:#{id}", "discard"}
        )

      assert NoticeWorkflow.message(discarded) == "Discarded agent edits in 1 file"
      assert File.read!(Path.join(root, "todo.md")) == "a\nb\n"
    end

    test "edits for a workspace that already has a staging area get their own workspace",
         %{state: state, workspace_id: id, root: root} do
      {:ok, other} = ProjectView.overlay(root)
      :ok = ProjectView.write_file(other, "other.md", "x")
      {:ok, changes} = ProjectView.diff(other)

      state = EditPublication.recovered(state, root, [Recovery.live(id, other, changes)])

      assert %{label: "Recovered agent edits", id: new_id} =
               Enum.find(
                 state.shell_runtime.state.tab_bar.workspaces,
                 &(&1.label == "Recovered agent edits")
               )

      assert new_id != id
      assert notification(state, new_id).title == "1 agent-edited file is not on disk"
      assert workspace(state, id).payload.project_view.id != other.id
    end

    test "edits for another project are ignored", %{state: state, view: view, workspace_id: id} do
      assert EditPublication.recovered(state, "/elsewhere", [Recovery.live(id, view, [])]) ==
               state
    end

    test "the Messages lines name the workspace, each changed base, and each lost draft",
         %{state: state, workspace_id: id} do
      ws = workspace(state, id)
      review = MingaEditor.State.WorkspaceReview.set_changed_files(ws.review, [:a, :b])
      ws = MingaEditor.State.Workspace.set_review(ws, review)

      recovery =
        Recovery.restored(id, nil,
          base_changed: ["lib/a.ex"],
          lost: [{"lib/gone.ex", :invalid_format}],
          retained: [{"lib/later.ex", :enospc}]
        )

      assert EditPublication.recovery_messages(recovery, ws) == [
               "Agent: restored staged agent edits in 2 files from the previous run. Publish (SPC a p) or discard (SPC a P) them.",
               "Staged agent edit for lib/a.ex was made against an older version of the file. Publishing merges it with the file on disk, or keeps it staged and reports a conflict.",
               "Staged agent edit for lib/gone.ex from the previous run was lost: :invalid_format",
               "Staged agent edit for lib/later.ex from the previous run could not be restored (:enospc). It stays saved and is offered again at the next start."
             ]

      assert [
               "Agent: staged agent edits in 2 files survived the editor restart." <> _
             ] =
               EditPublication.recovery_messages(
                 %{recovery | source: :live, base_changed: [], lost: [], retained: []},
                 ws
               )

      assert EditPublication.recovery_messages(recovery, nil) |> length() == 3
    end

    test "a restore failure message never carries the draft's content",
         %{state: state, workspace_id: id} do
      secret = "api_key = \"TOP-SECRET\""
      draft = Minga.Session.StagedDraft.new("lib/a.ex", "base #{secret}", secret)
      # The shape of a GenServer.call exit: the call's arguments, the draft included.
      exit_reason = {:noproc, {GenServer, :call, [self(), {:restore_draft, draft}, 5000]}}

      assert Overlay.exit_kind(exit_reason) == :noproc

      recovery =
        Recovery.restored(id, nil,
          lost: [{"lib/a.ex", {:changeset_unavailable, exit_reason}}],
          retained: [{"lib/a.ex", {:changeset_unavailable, exit_reason}}, {"lib/b.ex", draft}]
        )

      messages = EditPublication.recovery_messages(recovery, workspace(state, id))
      assert [_headline, _lost, _retained, _other] = messages
      refute Enum.any?(messages, &String.contains?(&1, "TOP-SECRET"))
      refute Enum.any?(messages, &String.contains?(&1, "base "))
    end
  end
end
