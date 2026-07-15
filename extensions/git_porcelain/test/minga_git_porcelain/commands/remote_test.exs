unless Code.ensure_loaded?(MingaEditor.Test.FakeShell),
  do: Code.require_file("../../../../../test/support/fake_shell.ex", __DIR__)

defmodule MingaGitPorcelain.CommandsRemoteTest do
  @moduledoc "Typed scheduler and visible-feedback coverage for Git remote commands."

  # Uses the global shell/scope registries and the shared Git stub table.
  use ExUnit.Case, async: false

  alias Minga.Extension.CodeLease
  alias Minga.Extension.InvocationContext
  alias Minga.Git.Stub
  alias Minga.Keymap.Scope
  alias Minga.Project.Root
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.EffectScheduler
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.GitStatus.TUIState
  alias MingaEditor.Shell.Registry, as: ShellRegistry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.GitToast
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Test.FakeShell
  alias MingaEditor.Viewport
  alias MingaGitPorcelain.Commands
  alias MingaGitPorcelain.Effects.RemoteOperation
  alias MingaGitPorcelain.Input.GitStatus
  alias MingaGitPorcelain.Test.EffectDependencies, as: Dependencies

  @source {:extension, :minga_git_porcelain}
  @admission Module.concat(__MODULE__, Admission)
  @timeout 2_000

  setup do
    Dependencies.reset(self())
    start_supervised!({CodeLease, name: @admission})
    :ok = CodeLease.activate_source(@source, [RemoteOperation], server: @admission)
    MingaGitPorcelain.Feature.register_contributions()
    previous_root = Minga.Project.workspace_root()
    git_root = Path.join(System.tmp_dir!(), "git_remote_#{System.unique_integer([:positive])}")
    File.mkdir_p!(git_root)
    {:ok, root} = Root.directory(git_root)
    {:ok, _snapshot} = Minga.Project.activate(root)
    Stub.set_root(git_root, git_root)

    ShellRegistry.reset_for_test()
    ShellRegistry.seed_builtin()

    :ok =
      ShellRegistry.register({:extension, :git_remote_fake_shell}, %{
        id: :fake,
        module: FakeShell,
        display_name: "Fake",
        description: "Fake shell",
        capabilities: [:tui]
      })

    on_exit(fn ->
      Stub.clear(git_root)
      File.rm_rf!(git_root)
      restore_project(previous_root)
      Scope.unregister_source(@source)
      ShellRegistry.reset_for_test()
      ShellRegistry.seed_builtin()
    end)

    %{git_root: git_root}
  end

  test "remote commands remain registered" do
    names = Commands.__commands__() |> Enum.map(& &1.name)

    assert [:git_pull, :git_push, :git_fetch, :git_pull_and_retry] -- names == []
  end

  test "top-level and Git-status commands return while the same typed path is blocked", %{
    git_root: git_root
  } do
    {state, scheduler} = build_state()
    Stub.set_remote_blocker(git_root, :push, self())

    returned = Commands.execute(state, :git_push)
    assert returned.shell_runtime.state.notice.message == "Pushing…"

    running = receive_running(scheduler, :push)
    assert running.request.handler == RemoteOperation
    assert running.request.resource == {:git_porcelain_remote, @source}
    assert running.request.activity == :git_syncing
    assert_receive {:stub_git_remote_blocked, :push, push_worker}, @timeout
    assert is_pid(push_worker)

    duplicate = Commands.execute(returned, :git_pull)
    assert duplicate.shell_runtime.state.notice.message == "Git operation already in progress"
    refute_received {:stub_git_remote_blocked, :pull, _worker}

    assert :ok = EffectScheduler.cancel(scheduler, running.request.id)
    {_state, canceled} = receive_and_apply(returned, scheduler, :canceled)
    assert canceled.reason == :requested

    Stub.set_remote_blocker(git_root, :pull, self())
    status_state = git_status_state(%{state | effect_scheduler: scheduler})

    assert {:handled, returned_status} = GitStatus.handle_key(status_state, ?l, 0)

    assert returned_status.shell_runtime.state.notice.message == "Pulling…"
    status_running = receive_running(scheduler, :pull)
    assert status_running.request.handler == RemoteOperation
    assert status_running.request.resource == running.request.resource
    assert_receive {:stub_git_remote_blocked, :pull, pull_worker}, @timeout
    assert is_pid(pull_worker)

    assert :ok = EffectScheduler.cancel(scheduler, status_running.request.id)
    {_state, _canceled} = receive_and_apply(returned_status, scheduler, :canceled)
  end

  test "push, pull, fetch, and pull-and-retry produce success feedback and refresh", %{
    git_root: git_root
  } do
    Enum.reduce([:push, :pull, :fetch, :pull_and_retry], nil, fn operation, _previous ->
      {state, scheduler} = build_state()

      returned =
        with_source(fn ->
          Commands.schedule_remote(state, operation,
            git: Dependencies,
            admission: @admission,
            refresher: Dependencies
          )
        end)

      assert returned.shell_runtime.state.notice.message == progress_message(operation)
      running = receive_running(scheduler, operation)
      assert running.request.policy == Policy.fifo(0)

      assert_receive {:dependency_called, {:remote, first_operation}, worker, ^git_root}, @timeout

      case operation do
        :pull_and_retry ->
          assert first_operation == :pull
          assert_receive {:dependency_called, {:remote, :push}, ^worker, ^git_root}, @timeout

        _operation ->
          assert first_operation == operation
      end

      {result, outcome} = receive_and_apply(returned, scheduler, :completed)
      assert outcome.result == :ok
      assert result.shell_runtime.state.notice.message == success_message(operation)

      assert %{message: message, level: :success, action: nil} =
               Runtime.state(result.shell_runtime).git_toast

      assert message == success_message(operation)
      assert_receive {:dependency_called, :refresh, _apply_pid, ^git_root}, @timeout
      result
    end)
  end

  test "Git failures and non-fast-forward recovery preserve detailed feedback", %{
    git_root: git_root
  } do
    {state, scheduler} = build_state()
    Dependencies.put({:remote, :push}, {:return, {:error, "non-fast-forward rejected"}})

    returned =
      with_source(fn ->
        Commands.schedule_remote(state, :push,
          git: Dependencies,
          admission: @admission,
          refresher: Dependencies
        )
      end)

    _running = receive_running(scheduler, :push)
    {result, outcome} = receive_and_apply(returned, scheduler, :failed)
    assert outcome.reason == "non-fast-forward rejected"
    assert result.shell_runtime.state.notice.message == "Push failed: non-fast-forward rejected"

    assert %{
             message: "Push failed: non-fast-forward rejected",
             level: :error,
             action: :pull_and_retry
           } = Runtime.state(result.shell_runtime).git_toast

    assert_receive {:dependency_called, :refresh, _apply_pid, ^git_root}, @timeout
  end

  test "source unavailability is explicit and prevents remote work", %{git_root: git_root} do
    {:ok, _token} = CodeLease.quiesce_source(@source, server: @admission)
    {state, scheduler} = build_state()

    returned =
      with_source(fn ->
        Commands.schedule_remote(state, :push,
          git: Dependencies,
          admission: @admission,
          refresher: Dependencies
        )
      end)

    _running = receive_running(scheduler, :push)
    {result, outcome} = receive_and_apply(returned, scheduler, :failed)

    assert match?(
             {:source_unavailable, @source, RemoteOperation, :execute, _},
             outcome.reason
           )

    assert String.starts_with?(
             result.shell_runtime.state.notice.message,
             "Push failed: source unavailable"
           )

    refute_received {:dependency_called, {:remote, :push}, _worker, ^git_root}
    assert CodeLease.active_leases(server: @admission) == []
  end

  test "pull-and-retry stops after pull failure and reports retry push failure", %{
    git_root: git_root
  } do
    for {failing_operation, reason} <- [pull: "conflict", push: "denied"] do
      Dependencies.reset(self())
      Dependencies.put({:remote, failing_operation}, {:return, {:error, reason}})
      {state, scheduler} = build_state()

      returned =
        Commands.schedule_remote(state, :pull_and_retry,
          git: Dependencies,
          admission: @admission,
          refresher: Dependencies
        )

      _running = receive_running(scheduler, :pull_and_retry)
      assert_receive {:dependency_called, {:remote, :pull}, _worker, ^git_root}, @timeout

      case failing_operation do
        :pull ->
          refute_receive {:dependency_called, {:remote, :push}, _worker, ^git_root}, 50

        :push ->
          assert_receive {:dependency_called, {:remote, :push}, _worker, ^git_root}, @timeout
      end

      {result, outcome} = receive_and_apply(returned, scheduler, :failed)
      expected_reason = if failing_operation == :pull, do: "pull failed: #{reason}", else: reason
      assert outcome.reason == expected_reason

      expected_message = "Pull and retry failed: #{expected_reason}"
      assert result.shell_runtime.state.notice.message == expected_message

      assert %{message: ^expected_message, level: :error, action: nil} =
               Runtime.state(result.shell_runtime).git_toast

      assert_receive {:dependency_called, :refresh, _apply_pid, ^git_root}, @timeout
    end
  end

  test "callback failure and timeout settle once, report failure, and refresh", %{
    git_root: git_root
  } do
    for {action, expected_message} <- [
          {{:raise, "remote boom"}, "Fetch failed: extension callback exception: remote boom"},
          {{:block, :ok}, "Git operation timed out"}
        ] do
      Dependencies.reset(self())
      Dependencies.put({:remote, :fetch}, action)
      {state, scheduler} = build_state()

      returned =
        with_source(fn ->
          Commands.schedule_remote(state, :fetch,
            git: Dependencies,
            admission: @admission,
            refresher: Dependencies,
            timeout_ms: 60_000
          )
        end)

      running = receive_running(scheduler, :fetch)
      assert_receive {:dependency_called, {:remote, :fetch}, worker, ^git_root}, @timeout

      if match?({:block, _}, action) do
        worker_monitor = Process.monitor(worker)
        send(scheduler, {:effect_timeout, running.request.id})
        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, @timeout
      end

      {result, outcome} = receive_and_apply(returned, scheduler, :failed)
      assert String.starts_with?(result.shell_runtime.state.notice.message, expected_message)

      if match?({:raise, _}, action) do
        assert match?(
                 {:callback_failed, @source, RemoteOperation, :execute, :exception, _},
                 outcome.reason
               )
      end

      assert %{level: :error, action: nil} = Runtime.state(result.shell_runtime).git_toast
      assert_receive {:dependency_called, :refresh, _apply_pid, ^git_root}, @timeout
      assert EffectScheduler.stats(scheduler).admitted == 0
    end
  end

  test "explicit cancellation reports feedback, refreshes, and rejects delayed authority", %{
    git_root: git_root
  } do
    Dependencies.put({:remote, :pull}, {:block, :ok})
    {state, scheduler} = build_state()

    returned =
      with_source(fn ->
        Commands.schedule_remote(state, :pull,
          git: Dependencies,
          admission: @admission,
          refresher: Dependencies,
          timeout_ms: 60_000
        )
      end)

    running = receive_running(scheduler, :pull)
    assert_receive {:dependency_called, {:remote, :pull}, _worker, ^git_root}, @timeout

    [%{running: %{task: task}}] =
      scheduler |> :sys.get_state() |> Map.fetch!(:lanes) |> Map.values()

    assert :ok = EffectScheduler.cancel(scheduler, running.request.id)
    {result, outcome} = receive_and_apply(returned, scheduler, :canceled)
    assert outcome.reason == :requested
    assert result.shell_runtime.state.notice.message == "Git operation canceled"

    assert %{message: "Git operation canceled", level: :error} =
             result.shell_runtime.state.git_toast

    assert_receive {:dependency_called, :refresh, _apply_pid, ^git_root}, @timeout

    send(scheduler, {task.ref, {:ok, :late}})
    send(scheduler, {:effect_timeout, running.request.id})
    _barrier = EffectScheduler.stats(scheduler)
    request_id = running.request.id
    refute_received {:effect_result, ^scheduler, %Outcome{request: %{id: ^request_id}}}
  end

  test "terminal feedback never mutates or replays a foreign shell", %{git_root: git_root} do
    {state, scheduler} = build_state()
    Dependencies.put({:remote, :push}, {:return, {:error, "denied"}})

    returned =
      with_source(fn ->
        Commands.schedule_remote(state, :push,
          git: Dependencies,
          admission: @admission,
          refresher: Dependencies
        )
      end)

    _running = receive_running(scheduler, :push)
    foreign = MingaEditor.Shell.Workflow.switch(returned, :fake)
    foreign_shell = Runtime.state(foreign.shell_runtime)
    message_store = foreign.render.message_store

    {result, _outcome} = receive_and_apply(foreign, scheduler, :failed)
    assert Runtime.state(result.shell_runtime) == foreign_shell
    assert result.render.message_store == message_store
    assert_receive {:dependency_called, :refresh, _apply_pid, ^git_root}, @timeout

    restored = MingaEditor.Shell.Workflow.switch(result, :traditional)
    assert restored.shell_runtime.state.notice.message == nil
    refute GitToast.present?(restored.shell_runtime.state.git_toast)
  end

  defp restore_project(nil), do: Minga.Project.close()
  defp restore_project(%Root{} = root), do: Minga.Project.activate(root)

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

  defp git_status_state(state) do
    panel =
      GitStatusPanel.new(%{
        repo_state: :normal,
        branch: "main",
        ahead: 0,
        behind: 0,
        entries: []
      })

    state = %{
      state
      | workspace:
          state.workspace
          |> MingaEditor.Session.State.set_keymap_scope(:git_status),
        interaction: %MingaEditor.State.Interaction{
          focus_stack: [MingaEditor.Input.Scoped, MingaEditor.Input.ModeFSM]
        }
    }

    state
    |> SidebarWorkflow.replace_git_status(panel)
    |> SidebarWorkflow.replace_git_status_tui(TUIState.new())
  end

  defp with_source(fun), do: InvocationContext.with_source(@source, fun)

  defp receive_running(_scheduler, operation) do
    assert_receive {:effect_lifecycle,
                    %Outcome{
                      status: :running,
                      request: %{effect: %RemoteOperation{operation: ^operation}}
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

  defp progress_message(:push), do: "Pushing…"
  defp progress_message(:pull), do: "Pulling…"
  defp progress_message(:fetch), do: "Fetching…"
  defp progress_message(:pull_and_retry), do: "Pulling and retrying…"

  defp success_message(:push), do: "Pushed"
  defp success_message(:pull), do: "Pulled"
  defp success_message(:fetch), do: "Fetched"
  defp success_message(:pull_and_retry), do: "Pushed"
end
