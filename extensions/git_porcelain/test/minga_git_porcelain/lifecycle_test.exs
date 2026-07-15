defmodule MingaGitPorcelain.LifecycleTest do
  @moduledoc """
  Lifecycle coverage for the bundled Git porcelain extension package.
  """

  # Exercises global input/scope registries and extension module reloads.
  use ExUnit.Case, async: false

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.CodeLease
  alias Minga.Extension.InstanceRegistry
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.RuntimeSupervisor
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap.Active, as: ActiveKeymap
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.KeyParser
  alias Minga.Keymap.Scope
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Input
  alias MingaGitPorcelain.Effects.CommitMessageGeneration
  alias MingaGitPorcelain.Effects.RemoteOperation
  alias MingaGitPorcelain.Test.EffectDependencies, as: Dependencies

  @source {:extension, :minga_git_porcelain}
  @other_source {:extension, :unrelated_extension}
  @admission Module.concat(__MODULE__, Admission)
  @timeout 2_000

  setup do
    Dependencies.reset(self())
    start_supervised!({CodeLease, name: @admission})

    :ok =
      CodeLease.activate_source(
        @source,
        [RemoteOperation, CommitMessageGeneration],
        server: @admission
      )

    :ok = CodeLease.activate_source(@other_source, [RemoteOperation], server: @admission)
    cleanup_git_porcelain_contributions()

    on_exit(fn ->
      cleanup_git_porcelain_contributions()
    end)

    :ok
  end

  test "declares only retained runtime editor event families" do
    assert MingaGitPorcelain.__editor_event_handler_schema__() == [
             {MingaGitPorcelain.Commands, [:buffer_saved, :editor_action, :source_unload], []}
           ]
  end

  test "disable cancels only Git Porcelain work before runtime termination and rejects late delivery" do
    ctx = start_lifecycle_context()
    runtime = start_git_porcelain!(ctx)
    {scheduler, _task_supervisor} = start_scheduler()

    Dependencies.put({:remote, :push}, {:block, :ok})
    Dependencies.put({:remote, :pull}, {:block, :ok})

    git_request =
      RemoteOperation.request("/tmp/git-owned", :push,
        source: @source,
        git: Dependencies,
        admission: @admission,
        refresher: Dependencies,
        timeout_ms: 60_000
      )

    unrelated_request =
      RemoteOperation.request("/tmp/unrelated", :pull,
        source: @other_source,
        git: Dependencies,
        admission: @admission,
        refresher: Dependencies,
        timeout_ms: 60_000
      )

    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, git_request)
    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, unrelated_request)
    assert_receive {:dependency_called, {:remote, :push}, git_worker, "/tmp/git-owned"}, @timeout

    assert_receive {:dependency_called, {:remote, :pull}, unrelated_worker, "/tmp/unrelated"},
                   @timeout

    git_worker_monitor = Process.monitor(git_worker)
    unrelated_worker_monitor = Process.monitor(unrelated_worker)
    runtime_monitor = Process.monitor(runtime)

    task_ref = running_task_ref(scheduler, git_request.id)
    stop_git_porcelain!(ctx, callbacks(scheduler))

    assert_receive {:DOWN, ^git_worker_monitor, :process, ^git_worker, _reason}, @timeout
    assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}, @timeout
    refute EffectScheduler.active_source?(scheduler, @source)
    assert EffectScheduler.active_source?(scheduler, @other_source)
    refute_received {:DOWN, ^unrelated_worker_monitor, :process, ^unrelated_worker, _reason}

    assert_receive {:effect_terminal,
                    %Outcome{
                      status: :canceled,
                      reason: :source_canceled,
                      request: %{id: git_request_id}
                    }},
                   @timeout

    assert git_request_id == git_request.id

    send(scheduler, {task_ref, {:ok, :late}})
    send(scheduler, {:effect_timeout, git_request.id})
    _barrier = EffectScheduler.stats(scheduler)
    refute_received {:effect_result, ^scheduler, %Outcome{request: %{id: ^git_request_id}}}

    send(unrelated_worker, {:release_dependency, {:remote, :pull}})
    unrelated_outcome = receive_candidate(scheduler, unrelated_request.id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, unrelated_outcome)
    EffectScheduler.finalize(scheduler, unrelated_outcome)
    _barrier = EffectScheduler.stats(scheduler)

    assert_receive {:DOWN, ^unrelated_worker_monitor, :process, ^unrelated_worker, :normal},
                   @timeout
  end

  test "disable terminalizes a pending commit result before extension code is removed" do
    ctx = start_lifecycle_context()
    _runtime = start_git_porcelain!(ctx)
    {scheduler, _task_supervisor} = start_scheduler()

    request =
      CommitMessageGeneration.request(
        source: @source,
        git: Dependencies,
        project: Dependencies,
        generator: Dependencies,
        admission: @admission,
        timeout_ms: 60_000
      )

    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, request)
    delayed = receive_candidate(scheduler, request.id, :completed)
    assert EffectScheduler.active_source?(scheduler, @source)

    stop_git_porcelain!(ctx, callbacks(scheduler))

    assert_receive {:effect_terminal,
                    %Outcome{
                      status: :canceled,
                      reason: :source_canceled,
                      request: %{id: request_id}
                    }},
                   @timeout

    assert request_id == request.id
    assert EffectScheduler.claim(scheduler, delayed) == {:error, :not_pending}
    refute EffectScheduler.active_source?(scheduler, @source)
  end

  test "reload terminates the old child and replaces source-owned contributions without duplicates" do
    ctx = start_lifecycle_context()

    code_locations =
      Map.new([MingaGitPorcelain, MingaGitPorcelain.Commands], &{&1, :code.which(&1)})

    first_pid = start_git_porcelain!(ctx)
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx)) == {:ok, first_pid}
    assert_git_porcelain_contributions_registered(ctx)
    assert {:ok, admitted} = ArtifactAdmission.source_modules(@source)
    assert MingaGitPorcelain in admitted
    assert MingaGitPorcelain.Commands in admitted
    assert Map.new(Map.keys(code_locations), &{&1, :code.which(&1)}) == code_locations

    ref = Process.monitor(first_pid)
    stop_git_porcelain!(ctx)
    assert_receive {:DOWN, ^ref, :process, ^first_pid, _reason}, 1_000
    assert_git_porcelain_contributions_removed(ctx)

    second_pid = start_git_porcelain!(ctx)
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx)) == {:ok, second_pid}
    assert second_pid != first_pid
    assert_git_porcelain_contributions_registered(ctx)
    assert Enum.count(Input.surface_handlers(), &(&1 == MingaGitPorcelain.Input.GitStatus)) == 1

    second_ref = Process.monitor(second_pid)
    stop_git_porcelain!(ctx)
    assert_receive {:DOWN, ^second_ref, :process, ^second_pid, _reason}, 1_000
    assert_git_porcelain_contributions_removed(ctx)
  end

  defp start_lifecycle_context do
    supervisor = start_supervised!({ExtSupervisor, name: unique_name("git_porcelain_ext_sup")})
    registry = start_supervised!({ExtRegistry, name: unique_name("git_porcelain_ext_registry")})

    command_registry =
      start_supervised!({CommandRegistry, name: unique_name("git_porcelain_command_registry")})

    keymap = start_supervised!({ActiveKeymap, name: nil})
    path = Path.expand("../../lib", __DIR__)

    :ok = ExtRegistry.register(registry, :minga_git_porcelain, path, [])

    %{
      supervisor: supervisor,
      registry: registry,
      command_registry: command_registry,
      keymap: keymap
    }
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp runtime_supervisor(ctx) do
    registry = InstanceRegistry.registry_for_root(ctx.supervisor)
    InstanceRegistry.via(registry, :runtime, :minga_git_porcelain)
  end

  defp start_git_porcelain!(ctx) do
    {:ok, entry} = ExtRegistry.get(ctx.registry, :minga_git_porcelain)

    assert {:ok, pid} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :minga_git_porcelain,
               entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap,
               code_lease: @admission
             )

    pid
  end

  defp stop_git_porcelain!(ctx, callbacks \\ nil) do
    {:ok, entry} = ExtRegistry.get(ctx.registry, :minga_git_porcelain)

    opts = [
      command_registry: ctx.command_registry,
      keymap: ctx.keymap,
      code_lease: @admission
    ]

    opts = if callbacks == nil, do: opts, else: Keyword.put(opts, :callbacks, callbacks)

    assert :ok =
             ExtSupervisor.stop_extension(
               ctx.supervisor,
               ctx.registry,
               :minga_git_porcelain,
               entry,
               opts
             )
  end

  defp assert_git_porcelain_contributions_registered(ctx) do
    assert {:ok, _command} = CommandRegistry.lookup(ctx.command_registry, :git_status_toggle)
    assert {:ok, _command} = CommandRegistry.lookup(ctx.command_registry, :git_blame_line)
    assert {:command, :git_status_toggle, _description} = lookup_git_status_keybind(ctx.keymap)
    assert Scope.module_for(:git_status) == MingaGitPorcelain.Keymap.Scope
    assert Enum.member?(Input.surface_handlers(), MingaGitPorcelain.Input.GitStatus)
  end

  defp assert_git_porcelain_contributions_removed(ctx) do
    assert :error = CommandRegistry.lookup(ctx.command_registry, :git_status_toggle)
    assert :not_found = lookup_git_status_keybind(ctx.keymap)
    assert Scope.module_for(:git_status) == nil
    refute Enum.member?(Input.surface_handlers(), MingaGitPorcelain.Input.GitStatus)
  end

  defp lookup_git_status_keybind(keymap) do
    {:ok, keys} = KeyParser.parse("g g")

    keymap
    |> ActiveKeymap.leader_trie()
    |> Bindings.lookup_sequence(keys)
  end

  defp start_scheduler do
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
    {scheduler, task_supervisor}
  end

  defp callbacks(scheduler) do
    %{
      editor_effects: &EffectScheduler.cancel_source(scheduler, &1),
      input_handlers: &Input.unregister_source/1,
      keymap_scopes: &Scope.unregister_source/1
    }
  end

  defp running_task_ref(scheduler, request_id) do
    scheduler
    |> :sys.get_state()
    |> Map.fetch!(:lanes)
    |> Map.values()
    |> Enum.find_value(fn
      %{running: %{request: %{id: ^request_id}, task: task}} -> task.ref
      _lane -> nil
    end)
  end

  defp receive_candidate(scheduler, request_id, status) do
    assert_receive {:effect_result, ^scheduler,
                    %Outcome{status: ^status, request: %{id: id}} = outcome}
                   when id == request_id,
                   @timeout

    outcome
  end

  defp cleanup_git_porcelain_contributions do
    :ok = CommandRegistry.unregister_source(@source)
    :ok = ActiveKeymap.unregister_source(@source)
    :ok = Scope.unregister_source(@source)
    :ok = Input.unregister_source(@source)
  end
end
