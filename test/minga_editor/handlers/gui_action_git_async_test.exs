defmodule MingaEditor.Handlers.GuiActionGitAsyncTest do
  @moduledoc "Git GUI actions scheduled as typed, repository-keyed FIFO effects."

  use ExUnit.Case, async: true

  alias Minga.Git.StatusEntry
  alias Minga.Git.Stub
  alias Minga.Test.GitRepositoryResolver
  alias Minga.Test.RecordingFrontend
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.GitMutation
  alias MingaEditor.Effects.GitMutationAdmission
  alias MingaEditor.Extension.EventEffect
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.GitStatus.Panel
  alias MingaEditor.GitStatus.TUIState
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Input.GitStatus
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.OperationQueue

  @effect_timeout 2_000

  setup do
    git_root = Path.join(System.tmp_dir!(), "stub_git_#{System.unique_integer([:positive])}")
    Stub.set_root(git_root, git_root)
    Stub.set_commit_notify(git_root, self())

    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})

    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec(
          {EffectScheduler, task_supervisor: task_supervisor, observer: self()},
          id: make_ref()
        )
      )

    :ok = EffectScheduler.attach(scheduler, self())

    on_exit(fn -> Stub.clear(git_root) end)

    frontend =
      start_supervised!(
        {RecordingFrontend, owner: self()},
        id: {:git_async_frontend, System.unique_integer([:positive])}
      )

    state =
      TestHelpers.base_state(
        sidebar_registry: table,
        effect_scheduler: scheduler,
        port_manager: frontend
      )

    %{state: state, scheduler: scheduler, git_root: git_root}
  end

  test "commit success and failure flow through typed domain outcomes", context do
    %{state: state, scheduler: scheduler, git_root: git_root} = context
    {state, panel_id} = install_panel(state, git_root, [])

    state = GuiActionHandler.dispatch(state, {:git_commit, panel_id, "fix the thing", false})
    assert feedback(state).message == "Committing…"
    assert feedback(state).status in [:pending, :running]
    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(state) == nil

    {state, request} = receive_resolved_mutation(state, scheduler, :commit, :running)
    assert request.resource == {:git_repository, Path.expand(git_root)}
    assert %GitMutation{message: "fix the thing", amend?: false} = request.effect
    assert_receive {:stub_git_commit, ^git_root, "fix the thing", []}

    {state, success} = receive_result(state, scheduler, request.id)
    assert match?({:completed, _result}, success.value)
    assert feedback(state).message == "Committed stub000"
    assert feedback(state).status == :success

    Stub.set_commit_result(git_root, {:error, "boom commit"})
    state = GuiActionHandler.dispatch(state, {:git_commit, panel_id, "fail commit", true})
    {state, request} = receive_resolved_mutation(state, scheduler, :commit, :running)
    assert %GitMutation{message: "fail commit", amend?: true} = request.effect
    assert_receive {:stub_git_commit, ^git_root, "fail commit", [amend: true]}

    {state, failure} = receive_result(state, scheduler, request.id)
    assert match?({:failed, _reason}, failure.value)
    assert feedback_for(state, request.operation_id).message == "Amend failed: boom commit"
    assert feedback_for(state, request.operation_id).status == :error
  end

  test "same-repository mutations are bounded FIFO and keep frontend activity visible", context do
    %{state: state, scheduler: scheduler, git_root: git_root} = context
    Stub.set_stage_blocker(git_root, self())
    {state, panel_id} = install_panel(state, git_root, ["lib/a.ex"])
    state = GuiActionHandler.dispatch(state, {:git_stage_file, panel_id, "lib/a.ex", 1})
    {state, stage_request} = receive_resolved_mutation(state, scheduler, :stage, :running)
    assert_receive {:stub_stage_blocked, stage_worker}

    state = GuiActionHandler.dispatch(state, {:git_commit, panel_id, "after stage", false})
    {state, commit_request} = receive_resolved_mutation(state, scheduler, :commit, :queued)

    assert EffectScheduler.stats(scheduler) == %{
             resources: 1,
             running: 1,
             queued: 1,
             pending: 0,
             admitted: 2,
             capacity: 64
           }

    assert EffectScheduler.active?(scheduler, GitMutation)
    assert Context.from_editor_state(state).intent.frame.git_syncing
    refute_received {:stub_git_commit, ^git_root, "after stage", []}

    send(stage_worker, :unblock_stub_stage)
    {state, stage_outcome} = receive_result(state, scheduler, stage_request.id)
    assert match?({:completed, _result}, stage_outcome.value)
    assert Stub.staged_paths(git_root) == ["lib/a.ex"]

    {state, running_commit} = receive_running_lifecycle(state, :commit)
    assert running_commit.id == commit_request.id
    assert feedback(state).message == "Committing…"
    assert feedback(state).status in [:pending, :running]
    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(state) == nil
    assert_receive {:stub_git_commit, ^git_root, "after stage", []}

    {state, commit_outcome} = receive_result(state, scheduler, commit_request.id)
    assert match?({:completed, _result}, commit_outcome.value)
    assert feedback(state).message == "Committed stub000"
    assert feedback(state).status == :success
    refute EffectScheduler.active?(scheduler, GitMutation)
    refute Context.from_editor_state(state).intent.frame.git_syncing
  end

  test "dispatch returns before a blocked repository resolver is released", context do
    %{state: state, scheduler: scheduler, git_root: git_root} = context
    tag = make_ref()
    {state, panel_id} = install_panel(state, git_root, [])

    opts = [
      git_root_resolver: {GitRepositoryResolver, {:block, self(), tag, git_root, git_root}}
    ]

    state = GuiActionHandler.dispatch(state, {:git_commit, panel_id, "nonblocking", false}, opts)
    assert feedback(state).message == "Committing…"
    assert feedback(state).status == :pending
    assert_receive {:git_resolver_blocked, ^tag, resolver_worker}, @effect_timeout
    assert feedback(state).status == :pending

    send(resolver_worker, {:release_git_resolver, tag})
    {state, request} = receive_resolved_mutation(state, scheduler, :commit, :running)
    assert request.resource == {:git_repository, Path.expand(git_root)}

    {state, outcome} = receive_result(state, scheduler, request.id)
    assert match?({:completed, _result}, outcome.value)
    assert feedback_for(state, request.operation_id).message == "Committed stub000"
    assert feedback_for(state, request.operation_id).status == :success
  end

  test "queue overflow and missing repository have explicit feedback", context do
    %{state: state, scheduler: scheduler, git_root: git_root} = context
    Stub.set_stage_blocker(git_root, self())
    paths = ["first.ex", "overflow.ex" | Enum.map(1..16, &"queued-#{&1}.ex")]
    {panel_state, panel_id} = install_panel(state, git_root, paths)

    git_state = GuiActionHandler.dispatch(panel_state, {:git_stage_file, panel_id, "first.ex", 1})

    {git_state, running_request} =
      receive_resolved_mutation(git_state, scheduler, :stage, :running)

    assert_receive {:stub_stage_blocked, _worker}

    git_state =
      Enum.reduce(1..16, git_state, fn index, acc ->
        acc = GuiActionHandler.dispatch(acc, {:git_stage_file, panel_id, "queued-#{index}.ex", 1})
        {acc, _request} = receive_resolved_mutation(acc, scheduler, :stage, :queued)
        acc
      end)

    overflow_state =
      GuiActionHandler.dispatch(git_state, {:git_stage_file, panel_id, "overflow.ex", 1})

    {overflow_state, overflow} = receive_admission_result(overflow_state, scheduler, :stage)
    overflow_id = overflow.request.id
    overflow_operation_id = overflow.request.operation_id

    assert_receive {:effect_terminal,
                    %Outcome{
                      request: %Request{id: ^overflow_id},
                      value: {:failed, :queue_full}
                    }},
                   @effect_timeout

    assert feedback_for(overflow_state, overflow_operation_id).message ==
             "Git action queue is full"

    assert feedback_for(overflow_state, overflow_operation_id).status == :error

    assert EffectScheduler.stats(scheduler) == %{
             resources: 1,
             running: 1,
             queued: 16,
             pending: 0,
             admitted: 17,
             capacity: 64
           }

    assert :ok = EffectScheduler.cancel(scheduler, running_request.id)

    missing_opts = [git_root_resolver: {GitRepositoryResolver, :not_git}]

    missing_state =
      GuiActionHandler.dispatch(panel_state, {:git_stage_all, panel_id}, missing_opts)

    {missing_state, missing} = receive_admission_result(missing_state, scheduler, :stage_all)
    assert match?({:failed, _reason}, missing.value)

    assert feedback_for(missing_state, missing.request.operation_id).message ==
             "Not in a git repository"

    assert feedback_for(missing_state, missing.request.operation_id).status == :error
  end

  test "actions offered by a replaced panel cannot stage, commit, or dispatch a remote event",
       %{state: state, git_root: root, scheduler: scheduler} do
    replacement_root = root <> "_replacement"
    on_exit(fn -> Stub.clear(replacement_root) end)
    {state, offered_id} = install_panel(state, root, ["shared.ex"])
    {state, current_id} = install_panel(state, replacement_root, ["shared.ex"])
    assert current_id != offered_id

    message = <<0, 3, "fix">>

    for {subtype, tail} <- [
          {0x1B, <<>>},
          {0x1C, <<>>},
          {0x1D, <<0, message::binary>>},
          {0x1D, <<1, message::binary>>},
          {0x38, <<>>},
          {0x39, <<>>},
          {0x3A, <<>>},
          {0x3B, message}
        ] do
      denied = dispatch_git_packet(state, <<0x07, subtype, offered_id::64, tail::binary>>)
      assert NoticeWorkflow.message(denied) == "Git status target is no longer available"
      assert denied.feedback.operation_feedback == state.feedback.operation_feedback
    end

    assert EffectScheduler.stats(scheduler).admitted == 0
    assert Stub.staged_paths(root) == []
    assert Stub.staged_paths(replacement_root) == []

    state = dispatch_git_packet(state, <<0x07, 0x1B, current_id::64>>)
    {state, request} = receive_resolved_mutation(state, scheduler, :stage_all, :running)
    assert %GitMutation{git_root: ^replacement_root} = request.effect
    {state, outcome} = receive_result(state, scheduler, request.id)
    assert match?({:completed, _result}, outcome.value)
    assert Stub.staged_paths(replacement_root) == ["."]
    assert Stub.staged_paths(root) == []

    dispatch_git_packet(state, <<0x07, 0x3A, current_id::64>>)

    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{
                        effect: %EventEffect{
                          event: {:editor_action, :git_status_remote, {^replacement_root, :fetch}}
                        }
                      },
                      value: :running
                    }},
                   @effect_timeout
  end

  test "switching repositories rejects every stale file action even when the same row exists",
       %{state: state, git_root: root, scheduler: scheduler} do
    path = "shared.ex"
    staged = %StatusEntry{path: path, status: :modified, staged: true}
    {state, offered_id} = install_panel(state, root, [path, staged])
    replacement_root = root <> "_replacement"
    {state, current_id} = install_panel(state, replacement_root, [path, staged])
    assert current_id != offered_id

    for {action, section, notice} <- [
          {:git_stage_file, 1, "Git status target is no longer available"},
          {:git_unstage_file, 0, "Git status target is no longer available"},
          {:git_discard_file, 1, "Git status target is no longer available"},
          {:git_open_file, 1, "No git status entry for #{path}"},
          {:git_open_diff, 1, "No git diff entry for #{path}"}
        ] do
      denied = GuiActionHandler.dispatch(state, {action, offered_id, path, section})
      assert NoticeWorkflow.message(denied) == notice
      assert denied.workspace.buffers.active == state.workspace.buffers.active
      assert SidebarWorkflow.git_status_panel(denied).id == current_id
    end

    for section <- [0, 2] do
      denied = GuiActionHandler.dispatch(state, {:git_discard_file, current_id, path, section})

      assert NoticeWorkflow.message(denied) == "Git status target is no longer available"
    end

    assert EffectScheduler.stats(scheduler).admitted == 0

    state = GuiActionHandler.dispatch(state, {:git_discard_file, current_id, path, 1})
    {state, request} = receive_resolved_mutation(state, scheduler, :discard, :running)
    assert %GitMutation{git_root: ^replacement_root, path: ^path} = request.effect
    {state, _outcome} = receive_result(state, scheduler, request.id)
    assert feedback_for(state, request.operation_id).message == "Discarded #{path}"
  end

  test "a discard offered before a status refresh cannot delete a replacement row",
       %{state: state, git_root: root, scheduler: scheduler} do
    path = "replacement.ex"
    untracked = %StatusEntry{path: path, status: :untracked, staged: false}
    staged = %StatusEntry{path: path, status: :added, staged: true}
    {state, offered_id} = install_panel(state, root, [untracked])

    replacement =
      Enum.reduce([[staged], [untracked]], state, fn entries, current ->
        event = %Minga.Events.GitStatusEvent{
          git_root: root,
          entries: entries,
          branch: "main",
          ahead: 0,
          behind: 0
        }

        panel = Panel.refresh(SidebarWorkflow.git_status_panel(current), event)
        SidebarWorkflow.refresh_git_status(current, panel)
      end)

    denied = GuiActionHandler.dispatch(replacement, {:git_discard_file, offered_id, path, 2})

    assert NoticeWorkflow.message(denied) == "Git status target is no longer available"
    assert EffectScheduler.stats(scheduler).admitted == 0
  end

  test "TUI discard confirms the offered panel, not a reopened panel for the same repository",
       %{state: state, git_root: root, scheduler: scheduler} do
    path = "shared.ex"
    {state, offered_id} = install_panel(state, root, [path])
    workspace = SessionState.set_keymap_scope(state.workspace, :git_status)
    panel = SidebarWorkflow.git_status_panel(state)

    state =
      SidebarWorkflow.replace_git_status_tui(
        %{state | workspace: workspace},
        TUIState.next(TUIState.new(), panel.entries)
      )

    assert {:handled, offered} = GitStatus.handle_key(state, ?d, 0)
    assert NoticeWorkflow.message(offered) =~ "Discard changes to #{path}?"

    assert %{discard_confirmation: {^offered_id, ^path, 1}} =
             SidebarWorkflow.git_status_tui_state(offered)

    reopened = SidebarWorkflow.replace_git_status(offered, panel)
    assert SidebarWorkflow.git_status_panel(reopened).id != offered_id
    assert {:handled, denied} = GitStatus.handle_key(reopened, ?y, 0)
    assert NoticeWorkflow.message(denied) == "Git status target is no longer available"
    assert %{discard_confirmation: nil} = SidebarWorkflow.git_status_tui_state(denied)
    assert EffectScheduler.stats(scheduler).admitted == 0

    assert {:handled, offered} = GitStatus.handle_key(denied, ?d, 0)
    assert {:handled, state} = GitStatus.handle_key(offered, ?y, 0)
    {state, request} = receive_resolved_mutation(state, scheduler, :discard, :running)
    assert %GitMutation{git_root: ^root, path: ^path} = request.effect
    {_state, outcome} = receive_result(state, scheduler, request.id)
    assert match?({:completed, _result}, outcome.value)
  end

  @spec dispatch_git_packet(EditorState.t(), binary()) :: EditorState.t()
  defp dispatch_git_packet(state, packet) do
    assert {:ok, {:gui_action, action}} = Protocol.decode_event(packet)
    GuiActionHandler.dispatch(state, action)
  end

  @spec install_panel(EditorState.t(), String.t(), [String.t() | StatusEntry.t()]) ::
          {EditorState.t(), Panel.id()}
  defp install_panel(state, root, rows) do
    entries =
      Enum.map(rows, fn
        %StatusEntry{} = entry -> entry
        path -> %StatusEntry{path: path, status: :modified, staged: false}
      end)

    panel = Panel.new(%{git_root: root, entries: entries})
    state = SidebarWorkflow.replace_git_status(state, panel)
    {state, SidebarWorkflow.git_status_panel(state).id}
  end

  @spec receive_resolved_mutation(
          EditorState.t(),
          pid(),
          GitMutation.operation(),
          :running | :queued
        ) :: {EditorState.t(), Request.t()}
  defp receive_resolved_mutation(state, scheduler, operation, disposition) do
    {state, admission} = receive_admission_result(state, scheduler, operation)

    {state, request} =
      case disposition do
        :running -> receive_running_lifecycle(state, operation)
        :queued -> receive_queued_lifecycle(state, operation, admission.request.operation_id)
      end

    assert request.operation_id == admission.request.operation_id
    refute request.id == admission.request.id
    refute feedback_for(state, request.operation_id).status == :success
    {state, request}
  end

  @spec receive_admission_result(EditorState.t(), pid(), GitMutation.operation()) ::
          {EditorState.t(), Outcome.t()}
  defp receive_admission_result(state, scheduler, operation) do
    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{
                        effect: %GitMutationAdmission{operation: ^operation}
                      },
                      value: :running
                    } = lifecycle},
                   @effect_timeout

    state = apply_lifecycle(state, lifecycle)

    assert_receive {:effect_result, ^scheduler,
                    %Outcome{
                      request: %Request{
                        effect: %GitMutationAdmission{operation: ^operation}
                      }
                    } = outcome},
                   @effect_timeout

    {:noreply, state} = MingaEditor.handle_info({:effect_result, scheduler, outcome}, state)
    refute feedback_for(state, outcome.request.operation_id).status == :success
    {state, outcome}
  end

  @spec receive_running_lifecycle(EditorState.t(), GitMutation.operation()) ::
          {EditorState.t(), Request.t()}
  defp receive_running_lifecycle(state, operation) do
    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{effect: %GitMutation{operation: ^operation}} = request,
                      value: :running
                    } = outcome},
                   @effect_timeout

    {apply_lifecycle(state, outcome), request}
  end

  @spec receive_queued_lifecycle(EditorState.t(), GitMutation.operation(), pos_integer()) ::
          {EditorState.t(), Request.t()}
  defp receive_queued_lifecycle(state, operation, expected_operation_id) do
    receive do
      {:effect_lifecycle,
       %Outcome{
         request: %Request{effect: %GitMutation{operation: ^operation}} = request,
         value: {:queued, %OperationQueue{position: position, total: total}}
       } = outcome} ->
        assert position > 0
        assert total >= position
        state = apply_lifecycle(state, outcome)

        if request.operation_id == expected_operation_id do
          {state, request}
        else
          receive_queued_lifecycle(state, operation, expected_operation_id)
        end
    after
      @effect_timeout ->
        flunk("timed out waiting for queued #{operation} operation #{expected_operation_id}")
    end
  end

  @spec receive_result(EditorState.t(), pid(), reference()) :: {EditorState.t(), Outcome.t()}
  defp receive_result(state, scheduler, request_id) do
    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %Request{id: ^request_id}} = outcome},
                   @effect_timeout

    {:noreply, state} = MingaEditor.handle_info({:effect_result, scheduler, outcome}, state)
    {state, outcome}
  end

  @spec feedback(EditorState.t()) :: MingaEditor.State.Operation.t()
  defp feedback(state), do: OperationFeedback.selected(state.feedback.operation_feedback)

  @spec feedback_for(EditorState.t(), pos_integer()) :: MingaEditor.State.Operation.t()
  defp feedback_for(state, operation_id) do
    {:ok, operation} = OperationFeedback.fetch(state.feedback.operation_feedback, operation_id)
    operation
  end

  @spec apply_lifecycle(EditorState.t(), Outcome.t()) :: EditorState.t()
  defp apply_lifecycle(state, outcome) do
    {:noreply, state} = MingaEditor.handle_info({:effect_lifecycle, outcome}, state)
    state
  end
end
