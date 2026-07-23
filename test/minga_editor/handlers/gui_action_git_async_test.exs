defmodule MingaEditor.Handlers.GuiActionGitAsyncTest do
  @moduledoc "Git GUI actions scheduled as typed, repository-keyed FIFO effects."

  use ExUnit.Case, async: true

  alias Minga.Git.Stub
  alias Minga.Test.GitRepositoryResolver
  alias Minga.Test.RecordingFrontend
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.GitMutation
  alias MingaEditor.Effects.GitMutationAdmission
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.RenderPipeline.TestHelpers
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

    dispatch_opts = [
      git_root_resolver: {GitRepositoryResolver, {:return, git_root, git_root}}
    ]

    %{state: state, scheduler: scheduler, git_root: git_root, dispatch_opts: dispatch_opts}
  end

  test "commit success and failure flow through typed domain outcomes", context do
    %{state: state, scheduler: scheduler, git_root: git_root, dispatch_opts: opts} = context

    state = GuiActionHandler.dispatch(state, {:git_commit, "fix the thing"}, opts)
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
    state = GuiActionHandler.dispatch(state, {:git_commit, "fail commit", true}, opts)
    {state, request} = receive_resolved_mutation(state, scheduler, :commit, :running)
    assert %GitMutation{message: "fail commit", amend?: true} = request.effect
    assert_receive {:stub_git_commit, ^git_root, "fail commit", [amend: true]}

    {state, failure} = receive_result(state, scheduler, request.id)
    assert match?({:failed, _reason}, failure.value)
    assert feedback_for(state, request.operation_id).message == "Amend failed: boom commit"
    assert feedback_for(state, request.operation_id).status == :error
  end

  test "same-repository mutations are bounded FIFO and keep frontend activity visible", context do
    %{state: state, scheduler: scheduler, git_root: git_root, dispatch_opts: opts} = context
    Stub.set_stage_blocker(git_root, self())
    state = GuiActionHandler.dispatch(state, {:git_stage_file, "lib/a.ex"}, opts)
    {state, stage_request} = receive_resolved_mutation(state, scheduler, :stage, :running)
    assert_receive {:stub_stage_blocked, stage_worker}

    state = GuiActionHandler.dispatch(state, {:git_commit, "after stage"}, opts)
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
    assert Context.from_editor_state(state).git_syncing
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
    refute Context.from_editor_state(state).git_syncing
  end

  test "dispatch returns before a blocked repository resolver is released", context do
    %{state: state, scheduler: scheduler, git_root: git_root} = context
    tag = make_ref()

    opts = [
      git_root_resolver: {GitRepositoryResolver, {:block, self(), tag, git_root, git_root}}
    ]

    state = GuiActionHandler.dispatch(state, {:git_stage_file, "lib/nonblocking.ex"}, opts)
    assert feedback(state).message == "Staging lib/nonblocking.ex…"
    assert feedback(state).status == :pending
    assert_receive {:git_resolver_blocked, ^tag, resolver_worker}, @effect_timeout
    assert feedback(state).status == :pending

    send(resolver_worker, {:release_git_resolver, tag})
    {state, request} = receive_resolved_mutation(state, scheduler, :stage, :running)
    assert request.resource == {:git_repository, Path.expand(git_root)}

    {state, outcome} = receive_result(state, scheduler, request.id)
    assert match?({:completed, _result}, outcome.value)
    assert feedback_for(state, request.operation_id).message == "Staged lib/nonblocking.ex"
    assert feedback_for(state, request.operation_id).status == :success
  end

  test "queue overflow and missing repository have explicit feedback", context do
    %{state: state, scheduler: scheduler, git_root: git_root, dispatch_opts: opts} = context
    Stub.set_stage_blocker(git_root, self())

    state = GuiActionHandler.dispatch(state, {:git_stage_file, "first.ex"}, opts)
    {state, running_request} = receive_resolved_mutation(state, scheduler, :stage, :running)
    assert_receive {:stub_stage_blocked, _worker}

    state =
      Enum.reduce(1..16, state, fn index, acc ->
        acc = GuiActionHandler.dispatch(acc, {:git_stage_file, "queued-#{index}.ex"}, opts)
        {acc, _request} = receive_resolved_mutation(acc, scheduler, :stage, :queued)
        acc
      end)

    overflow_state = GuiActionHandler.dispatch(state, {:git_stage_file, "overflow.ex"}, opts)
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
    missing_state = GuiActionHandler.dispatch(state, :git_stage_all, missing_opts)
    {missing_state, missing} = receive_admission_result(missing_state, scheduler, :stage_all)
    assert match?({:failed, _reason}, missing.value)

    assert feedback_for(missing_state, missing.request.operation_id).message ==
             "Not in a git repository"

    assert feedback_for(missing_state, missing.request.operation_id).status == :error
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
