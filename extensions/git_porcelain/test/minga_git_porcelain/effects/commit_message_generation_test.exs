unless Code.ensure_loaded?(MingaEditor.Test.FakeShell),
  do: Code.require_file("../../../../../test/support/fake_shell.ex", __DIR__)

defmodule MingaGitPorcelain.Effects.CommitMessageGenerationTest do
  @moduledoc "Scheduler-worker and lifecycle coverage for commit-message generation."

  # Uses the global shell registry while checking foreign-shell delivery.
  use ExUnit.Case, async: false

  alias Minga.Extension.CodeLease
  alias Minga.Project.FileTree
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Shell.Registry, as: ShellRegistry
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.Test.FakeShell
  alias MingaEditor.Viewport
  alias MingaGitPorcelain.Commands
  alias MingaGitPorcelain.Effects.CommitMessageGeneration
  alias MingaGitPorcelain.Test.EffectDependencies, as: Dependencies

  @source {:extension, :minga_git_porcelain}
  @admission Module.concat(__MODULE__, Admission)
  @timeout 2_000

  setup do
    Dependencies.reset(self())
    start_supervised!({CodeLease, name: @admission})
    :ok = CodeLease.activate_source(@source, [CommitMessageGeneration], server: @admission)
    ShellRegistry.reset_for_test()
    ShellRegistry.seed_builtin()

    :ok =
      ShellRegistry.register({:extension, :git_generation_fake_shell}, %{
        id: :fake,
        module: FakeShell,
        display_name: "Fake",
        description: "Fake shell",
        capabilities: [:tui]
      })

    on_exit(fn ->
      ShellRegistry.reset_for_test()
      ShellRegistry.seed_builtin()
    end)

    :ok
  end

  test "request is data-only and root, staged diff, and generator run in one scheduler worker" do
    {state, scheduler} = build_state()
    opts = Keyword.delete(dependency_opts(), :source)
    returned = Commands.schedule_commit_generation(state, opts)

    assert returned.shell_runtime.state.notice.message == "Generating commit message…"
    running = receive_running()
    request = running.request
    assert request.handler == CommitMessageGeneration
    assert request.resource == {:git_porcelain_commit_generation, @source}
    assert request.policy == Policy.fifo(0)
    assert request.timeout_ms == 60_000
    assert request.source == @source
    refute contains_runtime_authority?(request.effect)

    assert_receive {:dependency_called, :project_root, caller, nil}, @timeout
    assert caller == self()
    assert_receive {:dependency_called, :git_root, ^caller, "/tmp/project"}, @timeout

    assert_receive {:dependency_called, :staged_diff, worker, {"/tmp/repo", [staged: true]}},
                   @timeout

    assert_receive {:dependency_called, :generator, ^worker, "diff --git"}, @timeout

    {result, outcome} = receive_and_apply(returned, scheduler, :completed)
    assert outcome.result == {:generated, "feat: generated"}
    assert result.shell_runtime.state.notice.message == "Commit message generated"

    assert {:prompt, %{prompt_ui: %{handler: MingaGitPorcelain.UI.Prompt.GitCommit}} = payload} =
             result.shell_runtime.state.modal

    assert payload.prompt_ui.text == "feat: generated"
  end

  test "not-repository, empty diff, and diff failures remain distinct and skip generation" do
    cases = [
      {:git_root, {:return, :not_git}, "Not in a git repository"},
      {:staged_diff, {:return, {:ok, ""}}, "Nothing staged to generate a message for"},
      {:staged_diff, {:return, {:error, "index unavailable"}},
       "Failed to read staged diff: index unavailable"}
    ]

    for {key, action, expected} <- cases do
      Dependencies.reset(self())
      Dependencies.put(key, action)
      {state, scheduler} = build_state()
      returned = Commands.schedule_commit_generation(state, dependency_opts())
      _running = receive_running()
      {result, _outcome} = receive_and_apply(returned, scheduler, :failed)
      assert result.shell_runtime.state.notice.message == expected
      refute_received {:dependency_called, :generator, _worker, _diff}
      assert result.shell_runtime.state.modal == :none
    end
  end

  test "generator error, raise, and exit remain explicit at the callback boundary" do
    cases = [
      {{:return, {:error, "provider unavailable"}}, "provider unavailable"},
      {{:raise, "generator boom"}, "Commit message generation callback exception:"},
      {{:exit, :generator_exit}, "Commit message generation callback exit:"}
    ]

    for {action, expected_prefix} <- cases do
      Dependencies.reset(self())
      Dependencies.put(:generator, action)
      {state, scheduler} = build_state()
      returned = Commands.schedule_commit_generation(state, dependency_opts())
      _running = receive_running()
      assert_receive {:dependency_called, :generator, _worker, "diff --git"}, @timeout
      {result, outcome} = receive_and_apply(returned, scheduler, :failed)
      assert String.starts_with?(result.shell_runtime.state.notice.message, expected_prefix)

      case action do
        {:return, _result} ->
          assert outcome.reason == {:generation_failed, "provider unavailable"}

        _contained_failure ->
          assert match?(
                   {:callback_failed, @source, CommitMessageGeneration, :execute, _, _},
                   outcome.reason
                 )
      end

      refute match?({:worker_exit, _reason}, outcome.reason)
      assert CodeLease.active_leases(server: @admission) == []
    end
  end

  test "source unavailability is explicit and prevents generation work" do
    {:ok, _token} = CodeLease.quiesce_source(@source, server: @admission)
    {state, scheduler} = build_state()
    returned = Commands.schedule_commit_generation(state, dependency_opts())
    _running = receive_running()
    {result, outcome} = receive_and_apply(returned, scheduler, :failed)

    assert match?(
             {:source_unavailable, @source, CommitMessageGeneration, :execute, _},
             outcome.reason
           )

    assert String.starts_with?(
             result.shell_runtime.state.notice.message,
             "Commit message source unavailable:"
           )

    assert_receive {:dependency_called, :project_root, caller, nil}
    assert caller == self()
    assert_receive {:dependency_called, :git_root, ^caller, "/tmp/project"}
    refute_received {:dependency_called, :staged_diff, _worker, _payload}
    assert CodeLease.active_leases(server: @admission) == []
  end

  test "timeout kills the generator, rejects duplicates, and releases admission" do
    Dependencies.put(:generator, {:block, {:ok, "late subject"}})
    {state, scheduler} = build_state()
    returned = Commands.schedule_commit_generation(state, dependency_opts())
    running = receive_running()
    assert_receive {:dependency_called, :generator, worker, "diff --git"}, @timeout
    worker_monitor = Process.monitor(worker)

    duplicate = Commands.schedule_commit_generation(returned, dependency_opts())

    assert duplicate.shell_runtime.state.notice.message ==
             "Commit message generation already in progress"

    send(scheduler, {:effect_timeout, running.request.id})
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, @timeout
    {result, outcome} = receive_and_apply(duplicate, scheduler, :failed)
    assert outcome.reason == :timeout
    assert result.shell_runtime.state.notice.message == "Commit message generation timed out"
    assert result.shell_runtime.state.modal == :none
    assert EffectScheduler.stats(scheduler).admitted == 0
  end

  test "explicit cancellation reports feedback without opening a prompt" do
    Dependencies.put(:generator, {:block, {:ok, "late subject"}})
    {state, scheduler} = build_state()
    returned = Commands.schedule_commit_generation(state, dependency_opts())
    running = receive_running()
    assert_receive {:dependency_called, :generator, worker, "diff --git"}, @timeout
    worker_monitor = Process.monitor(worker)

    assert :ok = EffectScheduler.cancel(scheduler, running.request.id)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, @timeout
    {result, outcome} = receive_and_apply(returned, scheduler, :canceled)
    assert outcome.reason == :requested
    assert result.shell_runtime.state.notice.message == "Commit message generation canceled"
    assert result.shell_runtime.state.modal == :none
  end

  test "source cancellation removes running work and delayed completion authority" do
    Dependencies.put(:generator, {:block, {:ok, "late subject"}})
    {state, scheduler} = build_state()
    _returned = Commands.schedule_commit_generation(state, dependency_opts())
    running = receive_running()
    assert_receive {:dependency_called, :generator, worker, "diff --git"}, @timeout
    worker_monitor = Process.monitor(worker)

    assert :ok = EffectScheduler.cancel_source(scheduler, @source)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, @timeout

    assert_receive {:effect_terminal,
                    %Outcome{
                      status: :canceled,
                      reason: :source_canceled,
                      request: %{id: request_id}
                    }},
                   @timeout

    assert request_id == running.request.id
    refute EffectScheduler.active_source?(scheduler, @source)
    refute_received {:effect_result, ^scheduler, %Outcome{request: %{id: ^request_id}}}

    Dependencies.reset(self())
    {state, scheduler} = build_state()
    returned = Commands.schedule_commit_generation(state, dependency_opts())
    _running = receive_running()

    assert_receive {:effect_result, ^scheduler,
                    %Outcome{status: :completed, request: %{id: completed_id}} = delayed},
                   @timeout

    assert :ok = EffectScheduler.cancel_source(scheduler, @source)
    assert EffectScheduler.claim(scheduler, delayed) == {:error, :not_pending}
    assert returned.shell_runtime.state.modal == :none

    assert_receive {:effect_terminal, %Outcome{status: :canceled, request: %{id: ^completed_id}}},
                   @timeout
  end

  test "delayed success cannot open a prompt after an A to B to A repository switch" do
    Dependencies.put(:generator, {:block, {:ok, "late subject"}})
    {state, scheduler} = build_state()

    initial_file_tree =
      FileTreeState.begin_root_scan(
        state.workspace.file_tree,
        FileTree.new("/tmp/repo-a"),
        :project
      )

    initial_workspace = SessionState.set_file_tree(state.workspace, initial_file_tree)
    initial = %{state | workspace: initial_workspace}
    returned = Commands.schedule_commit_generation(initial, dependency_opts())
    _running = receive_running()
    assert_receive {:dependency_called, :generator, worker, "diff --git"}, @timeout

    b_file_tree =
      FileTreeState.begin_root_scan(
        returned.workspace.file_tree,
        FileTree.new("/tmp/repo-b"),
        :project
      )

    a_file_tree =
      FileTreeState.begin_root_scan(b_file_tree, FileTree.new("/tmp/repo-a"), :project)

    switched_workspace = SessionState.set_file_tree(returned.workspace, a_file_tree)
    switched = %{returned | workspace: switched_workspace}
    send(worker, {:release_dependency, :generator})

    {result, outcome} = receive_and_apply(switched, scheduler, :completed)
    assert outcome.status == :stale
    assert outcome.reason == :repository_changed
    assert result.shell_runtime.state.modal == :none

    assert result.shell_runtime.state.notice.message ==
             "Commit message result ignored after repository changed"
  end

  test "delayed success respects an existing modal and a foreign shell" do
    {state, scheduler} = build_state()
    returned = Commands.schedule_commit_generation(state, dependency_opts())
    _running = receive_running()

    occupied = MingaEditor.PromptUI.open(returned, MingaGitPorcelain.UI.Prompt.GitAmend)
    {occupied_result, _outcome} = receive_and_apply(occupied, scheduler, :completed)

    assert {:prompt, %{prompt_ui: %{handler: MingaGitPorcelain.UI.Prompt.GitAmend}}} =
             occupied_result.shell_runtime.state.modal

    assert occupied_result.shell_runtime.state.notice.message ==
             "Commit message ready (prompt already open)"

    Dependencies.reset(self())
    {state, scheduler} = build_state()
    returned = Commands.schedule_commit_generation(state, dependency_opts())
    _running = receive_running()
    foreign = MingaEditor.Shell.Workflow.switch(returned, :fake)
    foreign_shell = Runtime.state(foreign.shell_runtime)
    message_store = foreign.render.message_store

    {foreign_result, _outcome} = receive_and_apply(foreign, scheduler, :completed)
    assert Runtime.state(foreign_result.shell_runtime) == foreign_shell
    assert foreign_result.render.message_store == message_store

    restored = MingaEditor.Shell.Workflow.switch(foreign_result, :traditional)
    assert restored.shell_runtime.state.modal == :none
    assert restored.shell_runtime.state.notice.message == nil
  end

  defp dependency_opts do
    [
      source: @source,
      git: Dependencies,
      project: Dependencies,
      generator: Dependencies,
      admission: @admission,
      timeout_ms: 60_000
    ]
  end

  defp build_state do
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

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil, backend: :headless},
      workspace: %MingaEditor.Session.State{viewport: Viewport.new(80, 24)},
      effect_scheduler: scheduler
    }

    {state, scheduler}
  end

  defp receive_running do
    assert_receive {:effect_lifecycle,
                    %Outcome{
                      status: :running,
                      request: %{handler: CommitMessageGeneration}
                    } = outcome},
                   @timeout

    outcome
  end

  defp receive_and_apply(state, scheduler, status) do
    assert_receive {:effect_result, ^scheduler, %Outcome{status: ^status} = outcome}, @timeout
    assert :ok = EffectScheduler.claim(scheduler, outcome)
    {state, outcome} = outcome.request.handler.apply(state, outcome)
    EffectScheduler.finalize(scheduler, outcome)
    _barrier = EffectScheduler.stats(scheduler)
    {state, outcome}
  end

  defp contains_runtime_authority?(effect) do
    effect
    |> Map.from_struct()
    |> Map.values()
    |> Enum.any?(fn value -> is_pid(value) or is_reference(value) or is_function(value) end)
  end
end
