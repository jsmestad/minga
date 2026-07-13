defmodule MingaEditor.Handlers.GuiActionGitAsyncTest do
  @moduledoc "Git GUI actions scheduled as typed, repository-keyed FIFO effects."

  use ExUnit.Case, async: true

  alias Minga.Git.Stub
  alias Minga.Test.GitRepositoryResolver
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

    state = TestHelpers.base_state(sidebar_registry: table, effect_scheduler: scheduler)

    dispatch_opts = [
      git_root_resolver: {GitRepositoryResolver, {:return, git_root, git_root}}
    ]

    %{state: state, scheduler: scheduler, git_root: git_root, dispatch_opts: dispatch_opts}
  end

  test "commit success and failure flow through typed domain outcomes", context do
    %{state: state, scheduler: scheduler, git_root: git_root, dispatch_opts: opts} = context

    state = GuiActionHandler.dispatch(state, {:git_commit, "fix the thing"}, opts)
    assert EditorState.status_msg(state) == "Committing…"

    {state, request} = receive_resolved_mutation(state, scheduler, :commit, :running)
    assert request.resource == {:git_repository, Path.expand(git_root)}
    assert %GitMutation{message: "fix the thing", amend?: false} = request.effect
    assert_receive {:stub_git_commit, ^git_root, "fix the thing", []}

    {state, success} = receive_result(state, scheduler, request.id)
    assert success.status == :completed
    assert EditorState.status_msg(state) == "Committed stub000"

    Stub.set_commit_result(git_root, {:error, "boom commit"})
    state = GuiActionHandler.dispatch(state, {:git_commit, "fail commit", true}, opts)
    {state, request} = receive_resolved_mutation(state, scheduler, :commit, :running)
    assert %GitMutation{message: "fail commit", amend?: true} = request.effect
    assert_receive {:stub_git_commit, ^git_root, "fail commit", [amend: true]}

    {state, failure} = receive_result(state, scheduler, request.id)
    assert failure.status == :failed
    assert EditorState.status_msg(state) == "Amend failed: boom commit"
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
    assert stage_outcome.status == :completed
    assert Stub.staged_paths(git_root) == ["lib/a.ex"]

    {state, running_commit} = receive_running_lifecycle(state, :commit)
    assert running_commit.id == commit_request.id
    assert EditorState.status_msg(state) == "Committing…"
    assert_receive {:stub_git_commit, ^git_root, "after stage", []}

    {state, commit_outcome} = receive_result(state, scheduler, commit_request.id)
    assert commit_outcome.status == :completed
    assert EditorState.status_msg(state) == "Committed stub000"
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
    assert EditorState.status_msg(state) == "Staging lib/nonblocking.ex…"
    assert_receive {:git_resolver_blocked, ^tag, resolver_worker}

    send(resolver_worker, {:release_git_resolver, tag})
    {state, request} = receive_resolved_mutation(state, scheduler, :stage, :running)
    assert request.resource == {:git_repository, Path.expand(git_root)}

    {state, outcome} = receive_result(state, scheduler, request.id)
    assert outcome.status == :completed
    assert EditorState.status_msg(state) == "Staged lib/nonblocking.ex"
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

    assert_receive {:effect_terminal,
                    %Outcome{
                      request: %Request{id: ^overflow_id},
                      status: :failed,
                      reason: :queue_full
                    }},
                   @effect_timeout

    assert EditorState.status_msg(overflow_state) == "Git action queue is full"

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
    assert missing.status == :failed
    assert EditorState.status_msg(missing_state) == "Not in a git repository"
  end

  @spec receive_resolved_mutation(
          EditorState.t(),
          pid(),
          GitMutation.operation(),
          :running | :queued
        ) :: {EditorState.t(), Request.t()}
  defp receive_resolved_mutation(state, scheduler, operation, disposition) do
    {state, _admission} = receive_admission_result(state, scheduler, operation)

    case disposition do
      :running -> receive_running_lifecycle(state, operation)
      :queued -> receive_queued_lifecycle(state, operation)
    end
  end

  @spec receive_admission_result(EditorState.t(), pid(), GitMutation.operation()) ::
          {EditorState.t(), Outcome.t()}
  defp receive_admission_result(state, scheduler, operation) do
    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{
                        effect: %GitMutationAdmission{operation: ^operation}
                      },
                      status: :running
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
    {state, outcome}
  end

  @spec receive_running_lifecycle(EditorState.t(), GitMutation.operation()) ::
          {EditorState.t(), Request.t()}
  defp receive_running_lifecycle(state, operation) do
    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{effect: %GitMutation{operation: ^operation}} = request,
                      status: :running
                    } = outcome},
                   @effect_timeout

    {apply_lifecycle(state, outcome), request}
  end

  @spec receive_queued_lifecycle(EditorState.t(), GitMutation.operation()) ::
          {EditorState.t(), Request.t()}
  defp receive_queued_lifecycle(state, operation) do
    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{effect: %GitMutation{operation: ^operation}} = request,
                      status: :queued
                    } = outcome},
                   @effect_timeout

    {apply_lifecycle(state, outcome), request}
  end

  @spec receive_result(EditorState.t(), pid(), reference()) :: {EditorState.t(), Outcome.t()}
  defp receive_result(state, scheduler, request_id) do
    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %Request{id: ^request_id}} = outcome},
                   @effect_timeout

    {:noreply, state} = MingaEditor.handle_info({:effect_result, scheduler, outcome}, state)
    {state, outcome}
  end

  @spec apply_lifecycle(EditorState.t(), Outcome.t()) :: EditorState.t()
  defp apply_lifecycle(state, outcome) do
    {:noreply, state} = MingaEditor.handle_info({:effect_lifecycle, outcome}, state)
    state
  end
end
