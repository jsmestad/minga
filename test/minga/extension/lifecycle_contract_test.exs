defmodule Minga.Extension.LifecycleContractTest do
  use ExUnit.Case, async: true

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ArtifactGenerationState
  alias Minga.Extension.CallbackRegistry
  alias Minga.Extension.CodeLease
  alias Minga.Extension.DeferredBatchCompleteEvent
  alias Minga.Extension.Instance
  alias Minga.Extension.Instance.Worker
  alias Minga.Extension.InstanceRegistry
  alias Minga.Extension.Lazy
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.RuntimeSupervisor
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap.Active, as: KeymapActive

  defmodule Runtime do
    use Minga.Extension

    @impl true
    def name, do: :instance_runtime
    @impl true
    def description, do: "Instance lifecycle runtime"
    @impl true
    def version, do: "1.0.0"

    @impl true
    def init(config) do
      case Keyword.get(config, :init_gate) do
        {test_pid, result} ->
          send(test_pid, {:init_entered, self()})

          receive do
            :continue_init -> resolve_init_result(result)
          end

        nil ->
          {:ok, %{}}
      end
    end

    @spec resolve_init_result(term()) :: term()
    defp resolve_init_result(result) when is_function(result, 0), do: result.()
    defp resolve_init_result(result), do: result

    @impl true
    def child_spec(config) do
      restart = Keyword.get(config, :restart, :permanent)
      test_pid = Keyword.get(config, :runtime_test_pid)

      %{
        id: __MODULE__,
        start: {__MODULE__, :start_runtime, [test_pid]},
        restart: restart,
        type: :worker
      }
    end

    @spec start_runtime(pid() | nil) :: Agent.on_start()
    def start_runtime(test_pid) do
      result = Agent.start_link(fn -> %{test_pid: test_pid} end)
      if is_pid(test_pid), do: send(test_pid, {:runtime_child_started, elem(result, 1)})
      result
    end
  end

  defmodule RuntimeTwo do
    use Minga.Extension

    @impl true
    def name, do: :instance_runtime_two
    @impl true
    def description, do: "Second Instance lifecycle runtime"
    @impl true
    def version, do: "1.0.0"
    @impl true
    def init(_config), do: {:ok, %{}}

    @impl true
    def child_spec(config) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_runtime, [Keyword.get(config, :runtime_test_pid)]},
        restart: Keyword.get(config, :restart, :permanent),
        type: :worker
      }
    end

    @spec start_runtime(pid() | nil) :: Agent.on_start()
    def start_runtime(test_pid) do
      result = Agent.start_link(fn -> :runtime_two end)
      if is_pid(test_pid), do: send(test_pid, {:runtime_child_started, elem(result, 1)})
      result
    end
  end

  defmodule ChildSpecFailure do
    use Minga.Extension

    @impl true
    def name, do: :child_spec_failure
    @impl true
    def description, do: "Child spec failure"
    @impl true
    def version, do: "1.0.0"
    @impl true
    def init(_config), do: {:ok, %{}}
    @impl true
    def child_spec(_config), do: raise("child spec exploded")
  end

  defmodule BlockedThenStarts do
    use Minga.Extension

    @impl true
    def name, do: :blocked_then_starts
    @impl true
    def description, do: "Blocks its first child start MFA"
    @impl true
    def version, do: "1.0.0"
    @impl true
    def init(_config), do: {:ok, %{}}

    @impl true
    def child_spec(config) do
      %{
        id: __MODULE__,
        start:
          {__MODULE__, :start_runtime,
           [Keyword.fetch!(config, :attempts), Keyword.fetch!(config, :runtime_test_pid)]},
        restart: :temporary,
        type: :worker
      }
    end

    @spec start_runtime(Agent.agent(), pid()) :: Agent.on_start()
    def start_runtime(attempts, test_pid) do
      case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
        0 ->
          send(test_pid, {:blocked_child_start_mfa, self()})
          receive do: (:never -> {:error, :unexpected_release})

        _attempt ->
          send(test_pid, {:retry_child_start_mfa, self()})

          receive do
            :release_retry_child_start -> Runtime.start_runtime(test_pid)
          end
      end
    end
  end

  defmodule InfiniteShutdownThenStops do
    use Minga.Extension

    @impl true
    def name, do: :infinite_shutdown_then_stops
    @impl true
    def description, do: "Ignores its first shutdown request"
    @impl true
    def version, do: "1.0.0"
    @impl true
    def init(_config), do: {:ok, %{}}

    @impl true
    def child_spec(config) do
      %{
        id: __MODULE__,
        start:
          {__MODULE__, :start_runtime,
           [Keyword.fetch!(config, :attempts), Keyword.fetch!(config, :runtime_test_pid)]},
        restart: :temporary,
        shutdown: :infinity,
        type: :worker
      }
    end

    @spec start_runtime(Agent.agent(), pid()) :: {:ok, pid()} | Agent.on_start()
    def start_runtime(attempts, test_pid) do
      case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
        0 ->
          pid = spawn_link(fn -> ignore_shutdown(test_pid) end)
          send(test_pid, {:runtime_child_started, pid})
          {:ok, pid}

        _attempt ->
          Runtime.start_runtime(test_pid)
      end
    end

    @spec ignore_shutdown(pid()) :: no_return()
    defp ignore_shutdown(test_pid) do
      Process.flag(:trap_exit, true)
      send(test_pid, {:infinite_shutdown_ready, self()})

      receive do
        {:EXIT, _from, :shutdown} -> ignore_shutdown(test_pid)
        _message -> ignore_shutdown(test_pid)
      end
    end
  end

  defmodule ChildStartFailure do
    use Minga.Extension

    @impl true
    def name, do: :child_start_failure
    @impl true
    def description, do: "Child start failure"
    @impl true
    def version, do: "1.0.0"
    @impl true
    def init(_config), do: {:ok, %{}}

    @impl true
    def child_spec(_config) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :refuse_start, []},
        restart: :temporary,
        type: :worker
      }
    end

    @spec refuse_start() :: {:error, :child_refused_start}
    def refuse_start, do: {:error, :child_refused_start}
  end

  defmodule CommandRegistrationFailure do
    use Minga.Extension

    command(:authority_duplicate_command, "Duplicate authority command",
      execute: {__MODULE__, :run}
    )

    @impl true
    def name, do: :command_registration_failure
    @impl true
    def description, do: "Command registration failure"
    @impl true
    def version, do: "1.0.0"
    @impl true
    def init(_config), do: {:ok, %{}}
    @spec run(term()) :: term()
    def run(state), do: state
  end

  defmodule OptionFailure do
    use Minga.Extension

    option(:positive_count, :pos_integer, default: 1, description: "Positive count")

    @impl true
    def name, do: :option_failure
    @impl true
    def description, do: "Option failure"
    @impl true
    def version, do: "1.0.0"
    @impl true
    def init(_config), do: {:ok, %{}}
  end

  defmodule ModelineFailure do
    use Minga.Extension

    modeline_segment :mode do
      _context = ctx
      {" invalid ", :default, :default, [], nil}
    end

    @impl true
    def name, do: :modeline_failure
    @impl true
    def description, do: "Modeline failure"
    @impl true
    def version, do: "1.0.0"
    @impl true
    def init(_config), do: {:ok, %{}}
  end

  defmodule KeybindRuntime do
    use Minga.Extension

    keybind(:normal, "SPC z z", :noop, "Keybind registration probe")

    @impl true
    def name, do: :keybind_runtime
    @impl true
    def description, do: "Keybind runtime"
    @impl true
    def version, do: "1.0.0"
    @impl true
    def init(_config), do: {:ok, %{}}
  end

  defmodule EventRuntime do
    use Minga.Extension

    editor_event_handler(__MODULE__, [:buffer_saved])

    @impl true
    def name, do: :event_runtime
    @impl true
    def description, do: "Event runtime"
    @impl true
    def version, do: "1.0.0"
    @impl true
    def init(_config), do: {:ok, %{}}

    @spec handle_editor_event(term(), term()) :: {:handled, term()}
    def handle_editor_event(state, _event), do: {:handled, state}
  end

  defmodule CrashContributionRuntime do
    use Minga.Extension

    command(:crash_contribution_command, "Crash contribution command",
      execute: {__MODULE__, :run}
    )

    editor_event_handler(__MODULE__, [:buffer_saved])

    @impl true
    def name, do: :crash_contribution_runtime
    @impl true
    def description, do: "Crash contribution runtime"
    @impl true
    def version, do: "1.0.0"
    @impl true
    def init(_config), do: {:ok, %{}}

    @impl true
    def child_spec(config) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_runtime, [Keyword.get(config, :runtime_test_pid)]},
        restart: :temporary,
        type: :worker
      }
    end

    @spec start_runtime(pid() | nil) :: Agent.on_start()
    def start_runtime(test_pid) do
      result = Agent.start_link(fn -> :crash_contribution_runtime end)
      if is_pid(test_pid), do: send(test_pid, {:runtime_child_started, elem(result, 1)})
      result
    end

    @spec run(term()) :: term()
    def run(state), do: state

    @spec handle_editor_event(term(), term()) :: {:handled, term()}
    def handle_editor_event(state, _event), do: {:handled, state}
  end

  defmodule LeaseRuntime do
    use Minga.Extension

    @impl true
    def name, do: :lease_runtime
    @impl true
    def description, do: "Lease runtime"
    @impl true
    def version, do: "1.0.0"
    @impl true
    def init(_config), do: {:ok, %{}}
  end

  defmodule RuntimeThree do
    use Minga.Extension

    @impl true
    def name, do: :instance_runtime_three
    @impl true
    def description, do: "Third Instance lifecycle runtime"
    @impl true
    def version, do: "1.0.0"
    @impl true
    def init(_config), do: {:ok, %{}}

    @impl true
    def child_spec(config) do
      %{
        id: __MODULE__,
        start: {Agent, :start_link, [fn -> :runtime_three end]},
        restart: Keyword.get(config, :restart, :permanent),
        type: :worker
      }
    end
  end

  setup do
    suffix = System.unique_integer([:positive])
    registry = :"instance_contract_registry_#{suffix}"
    roots = :"instance_contract_roots_#{suffix}"
    commands = :"instance_contract_commands_#{suffix}"
    keymap = :"instance_contract_keymap_#{suffix}"
    callback_registry = :"instance_contract_callbacks_#{suffix}"
    owner = :"instance_contract_artifacts_#{suffix}"
    persistence_key = {__MODULE__, suffix}
    runtime_application = :"instance_contract_app_#{suffix}"

    :ok =
      :application.load(
        {:application, runtime_application,
         [
           description: ~c"instance contract",
           vsn: ~c"1",
           modules: [Runtime, RuntimeTwo, RuntimeThree],
           registered: [],
           applications: [:kernel, :stdlib]
         ]}
      )

    fixture_applications =
      Enum.map(
        [
          ChildSpecFailure,
          BlockedThenStarts,
          InfiniteShutdownThenStops,
          ChildStartFailure,
          CommandRegistrationFailure,
          OptionFailure,
          ModelineFailure,
          KeybindRuntime,
          EventRuntime,
          CrashContributionRuntime,
          LeaseRuntime
        ],
        fn module ->
          application =
            :"instance_contract_#{module |> Module.split() |> List.last() |> Macro.underscore()}_#{suffix}"

          :ok =
            :application.load(
              {:application, application,
               [
                 description: ~c"instance contract fixture",
                 vsn: ~c"1",
                 modules: [module],
                 registered: [],
                 applications: [:kernel, :stdlib]
               ]}
            )

          application
        end
      )

    on_exit(fn ->
      :application.unload(runtime_application)
      Enum.each(fixture_applications, &:application.unload/1)
    end)

    start_supervised!({ExtRegistry, name: registry})
    {:ok, _root_pid} = ExtSupervisor.start_link(name: roots)
    start_supervised!({CommandRegistry, name: commands})
    start_supervised!({KeymapActive, name: keymap})
    start_supervised!({CallbackRegistry, name: callback_registry})

    start_supervised!(
      {ArtifactGenerationState, name: owner, persistence_key: persistence_key},
      id: {ArtifactGenerationState, suffix}
    )

    admission =
      start_supervised!(
        {ArtifactAdmission, name: nil, state_owner: owner},
        id: {ArtifactAdmission, suffix}
      )

    code_lease = start_supervised!({CodeLease, name: nil}, id: {CodeLease, suffix})

    on_exit(fn -> ArtifactGenerationState.reset_for_test(persistence_key) end)

    opts = [
      command_registry: commands,
      keymap: keymap,
      callback_registry: callback_registry,
      artifact_admission: admission,
      code_lease: code_lease
    ]

    {:ok,
     registry: registry,
     roots: roots,
     commands: commands,
     keymap: keymap,
     callback_registry: callback_registry,
     admission: admission,
     code_lease: code_lease,
     runtime_application: runtime_application,
     opts: opts}
  end

  test "module and path declarations publish lifecycle through their Instance", ctx do
    module_name = unique_name(:module_source)
    module_entry = register_module(ctx, module_name, [])
    assert {:ok, module_pid} = start_extension(ctx, module_name, module_entry)
    assert InstanceRegistry.whereis(instance_registry(ctx), :instance, module_name)
    assert {:ok, module_projection} = ExtRegistry.get(ctx.registry, module_name)
    assert module_projection.status == :running
    assert module_projection.pid == module_pid
    assert module_projection.module == Runtime
    assert module_projection.manifest.source == :module
    assert :ok = stop_extension(ctx, module_name, ctx.opts)

    path_name = unique_name(:path_source)
    path_dir = Path.join(System.tmp_dir!(), Atom.to_string(path_name))
    path_module = Module.concat(Minga.TestExtensions, Macro.camelize(Atom.to_string(path_name)))
    File.mkdir_p!(path_dir)

    on_exit(fn -> File.rm_rf!(path_dir) end)

    File.write!(Path.join(path_dir, "extension.ex"), """
    defmodule #{inspect(path_module)} do
      use Minga.Extension
      @impl true
      def name, do: #{inspect(path_name)}
      @impl true
      def description, do: "Path lifecycle"
      @impl true
      def version, do: "1.0.0"
      @impl true
      def init(_config), do: {:ok, %{}}
    end
    """)

    :ok = ExtRegistry.register(ctx.registry, path_name, path_dir, [])
    {:ok, path_entry} = ExtRegistry.get(ctx.registry, path_name)
    assert {:ok, path_pid} = start_extension(ctx, path_name, path_entry)
    assert InstanceRegistry.whereis(instance_registry(ctx), :instance, path_name)
    assert {:ok, path_projection} = ExtRegistry.get(ctx.registry, path_name)
    assert path_projection.status == :running
    assert path_projection.pid == path_pid
    assert path_projection.module == path_module
    assert path_projection.manifest.source == :path
    assert :ok = stop_extension(ctx, path_name, ctx.opts)
  end

  test "Hex application declarations use the same Instance lifecycle", ctx do
    name = unique_name(:hex_application_source)

    :ok =
      ExtRegistry.register_hex(ctx.registry, name, Atom.to_string(ctx.runtime_application),
        app: ctx.runtime_application
      )

    {:ok, entry} = ExtRegistry.get(ctx.registry, name)
    assert {:ok, pid} = start_extension(ctx, name, entry)
    assert InstanceRegistry.whereis(instance_registry(ctx), :instance, name)
    assert {:ok, projection} = ExtRegistry.get(ctx.registry, name)
    assert projection.status == :running
    assert projection.pid == pid
    assert projection.module == Runtime
    assert projection.manifest.source == :hex

    assert {:ok, modules} =
             ArtifactAdmission.source_modules({:extension, name}, server: ctx.admission)

    assert modules == Enum.sort([Runtime, RuntimeTwo, RuntimeThree])

    assert :ok = stop_extension(ctx, name, ctx.opts)
    assert {:ok, %{status: :stopped, pid: nil}} = ExtRegistry.get(ctx.registry, name)
  end

  test "JSON and resolved Git declarations use the same Instance lifecycle", ctx do
    json_name = unique_name(:json_source)
    json_dir = Path.join(System.tmp_dir!(), Atom.to_string(json_name))
    File.mkdir_p!(json_dir)

    File.write!(Path.join(json_dir, "plugin.json"), """
    {"name":"#{json_name}","version":"1.0.0","description":"JSON lifecycle"}
    """)

    :ok = ExtRegistry.register(ctx.registry, json_name, json_dir, [])
    {:ok, json_entry} = ExtRegistry.get(ctx.registry, json_name)
    assert {:ok, json_pid} = start_extension(ctx, json_name, json_entry)
    assert InstanceRegistry.whereis(instance_registry(ctx), :instance, json_name)
    assert {:ok, json_projection} = ExtRegistry.get(ctx.registry, json_name)
    assert json_projection.pid == json_pid
    assert json_projection.manifest.source == :path
    assert :ok = stop_extension(ctx, json_name, ctx.opts)
    refute Process.alive?(json_pid)

    git_name = unique_name(:resolved_git_source)
    git_dir = Path.join(System.tmp_dir!(), Atom.to_string(git_name))
    git_module = Module.concat(Minga.TestExtensions, Macro.camelize(Atom.to_string(git_name)))
    File.mkdir_p!(git_dir)

    File.write!(Path.join(git_dir, "extension.ex"), """
    defmodule #{inspect(git_module)} do
      use Minga.Extension
      @impl true
      def name, do: #{inspect(git_name)}
      @impl true
      def description, do: "Resolved Git lifecycle"
      @impl true
      def version, do: "1.0.0"
      @impl true
      def init(_config), do: {:ok, %{}}
    end
    """)

    :ok = ExtRegistry.register_git(ctx.registry, git_name, "https://example.invalid/repo", [])
    :ok = ExtRegistry.update(ctx.registry, git_name, path: git_dir)
    {:ok, git_entry} = ExtRegistry.get(ctx.registry, git_name)
    assert {:ok, git_pid} = start_extension(ctx, git_name, git_entry)
    assert InstanceRegistry.whereis(instance_registry(ctx), :instance, git_name)
    assert {:ok, git_projection} = ExtRegistry.get(ctx.registry, git_name)
    assert git_projection.pid == git_pid
    assert git_projection.manifest.source == :git
    assert :ok = stop_extension(ctx, git_name, ctx.opts)
    refute Process.alive?(git_pid)

    File.rm_rf!(json_dir)
    File.rm_rf!(git_dir)
  end

  test "first concurrent callers synchronize through root and Instance registration", ctx do
    name = unique_name(:concurrent_root_start)
    entry = register_module(ctx, name, init_gate: {self(), {:ok, %{}}})
    parent = self()

    callers =
      for _index <- 1..12 do
        Task.async(fn ->
          send(parent, {:root_start_ready, self()})
          receive do: (:start_now -> start_extension(ctx, name, entry))
        end)
      end

    caller_pids =
      Enum.map(callers, fn _caller ->
        assert_receive {:root_start_ready, caller_pid}
        caller_pid
      end)

    Enum.each(caller_pids, &send(&1, :start_now))
    assert_receive {:init_entered, workflow}, 5_000
    send(workflow, :continue_init)

    results = Enum.map(callers, &Task.await(&1, 5_000))
    assert [{:ok, runtime}] = Enum.uniq(results)
    assert is_pid(runtime)
    refute Enum.any?(results, &match?({:error, {:instance_not_started, _}}, &1))
    refute_receive {:init_entered, _duplicate_workflow}
  end

  test "concurrent starts join one transition and return the same runtime PID", ctx do
    name = unique_name(:concurrent_start)
    config = [init_gate: {self(), {:ok, %{}}}]
    entry = register_module(ctx, name, config)

    first = Task.async(fn -> start_extension(ctx, name, entry) end)
    assert_receive {:init_entered, workflow}, 5_000

    second = Task.async(fn -> start_extension(ctx, name, entry) end)
    refute Task.yield(second, 50)

    send(workflow, :continue_init)
    assert {:ok, pid} = Task.await(first)
    assert {:ok, ^pid} = Task.await(second)
    assert {:running, %{pid: ^pid}} = Instance.phase(instance(ctx, name))
  end

  test "concurrent failed starts converge through one rollback", ctx do
    name = unique_name(:failed_start)
    config = [init_gate: {self(), {:error, :boom}}]
    entry = register_module(ctx, name, config)

    first = Task.async(fn -> start_extension(ctx, name, entry) end)
    assert_receive {:init_entered, workflow}, 5_000
    second = Task.async(fn -> start_extension(ctx, name, entry) end)
    send(workflow, :continue_init)

    assert {:error, reason} = Task.await(first)
    assert {:error, ^reason} = Task.await(second)
    assert {:load_error, %{reason: ^reason}} = Instance.phase(instance(ctx, name))
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == :empty
  end

  test "child-spec and child-start failures keep exact facade tuples and safe retry state", ctx do
    child_spec_name = unique_name(:child_spec_failure)
    child_spec_entry = register_module(ctx, child_spec_name, [], ChildSpecFailure)

    assert {:error, {:child_spec_failed, "child spec exploded"}} =
             start_extension(ctx, child_spec_name, child_spec_entry)

    assert {:ok,
            %{
              status: :load_error,
              pid: nil,
              last_error: {:child_spec_failed, "child spec exploded"}
            }} = ExtRegistry.get(ctx.registry, child_spec_name)

    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, child_spec_name)) == :empty

    child_start_name = unique_name(:child_start_failure)
    child_start_entry = register_module(ctx, child_start_name, [], ChildStartFailure)

    assert {:error, :child_refused_start} =
             start_extension(ctx, child_start_name, child_start_entry)

    assert {:ok, %{status: :load_error, pid: nil, last_error: :child_refused_start}} =
             ExtRegistry.get(ctx.registry, child_start_name)

    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, child_start_name)) == :empty
  end

  test "contribution registration failure rolls back exactly once and retry is safe", ctx do
    name = unique_name(:command_registration_failure)
    entry = register_module(ctx, name, [], CommandRegistrationFailure)

    assert :ok =
             CommandRegistry.register(
               ctx.commands,
               :config,
               :authority_duplicate_command,
               "Existing command",
               fn state -> state end
             )

    reason =
      {:duplicate_name, :authority_duplicate_command, :config, {:extension, name}}

    assert {:error, ^reason} = start_extension(ctx, name, entry)

    assert {:ok, %{status: :load_error, pid: nil, last_error: ^reason}} =
             ExtRegistry.get(ctx.registry, name)

    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == :empty
    assert :ok = CommandRegistry.unregister(ctx.commands, :authority_duplicate_command)
    assert {:ok, runtime} = start_extension(ctx, name, entry)
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == {:ok, runtime}
    assert {:ok, _command} = CommandRegistry.lookup(ctx.commands, :authority_duplicate_command)
  end

  test "failed stub cleanup blocks activation until cleanup retry succeeds", ctx do
    name = unique_name(:stub_cleanup_failure)

    entry =
      register_module(
        ctx,
        name,
        [load_policy: {:on_command, [:authority_duplicate_command]}],
        CommandRegistrationFailure
      )

    assert :ok =
             CommandRegistry.register(
               ctx.commands,
               :config,
               :authority_duplicate_command,
               "Existing command",
               fn state -> state end
             )

    cleanup = fn _source -> {:error, :stub_cleanup_busy} end
    opts = Keyword.put(ctx.opts, :callbacks, %{stub_cleanup_failure: cleanup})

    assert {:error, {:cleanup_failed, _stub_reason, failures}} =
             ExtSupervisor.register_lazy_extension(
               ctx.roots,
               ctx.registry,
               name,
               entry,
               opts
             )

    assert Enum.any?(failures, &match?(%{family: :stub_cleanup_failure}, &1))
    assert {:cleanup_failed, _context} = Instance.phase(instance(ctx, name))

    assert {:error, {:cleanup_retry_required, _reason}} =
             start_extension(ctx, name, entry, opts)

    assert :ok = stop_extension(ctx, name, Keyword.put(ctx.opts, :callbacks, %{}))
    assert :ok = CommandRegistry.unregister(ctx.commands, :authority_duplicate_command)

    assert :ok =
             ExtSupervisor.register_lazy_extension(
               ctx.roots,
               ctx.registry,
               name,
               entry,
               ctx.opts
             )
  end

  test "keybind event and lease registration failures retain exact projection and retry safely",
       ctx do
    cases = [
      {:keybind, KeybindRuntime, [keymap: :missing_keymap_authority]},
      {:event, EventRuntime, [callback_registry: :missing_callback_authority]},
      {:lease, LeaseRuntime, [code_lease: :missing_lease_authority]}
    ]

    Enum.each(cases, fn {family, module, failing_opts} ->
      name = unique_name(family)
      entry = register_module(ctx, name, [], module)
      opts = Keyword.merge(ctx.opts, failing_opts)
      assert {:error, reason} = start_extension(ctx, name, entry, opts)
      assert {:ok, projection} = ExtRegistry.get(ctx.registry, name)
      assert projection.status == :load_error
      assert projection.last_error == reason

      case projection.pid do
        pid when is_pid(pid) ->
          assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == {:ok, pid}

        nil ->
          assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == :empty
      end

      if match?({:cleanup_failed, _, _}, reason) do
        assert :ok = stop_extension(ctx, name, ctx.opts)
      end

      assert {:ok, runtime} = start_extension(ctx, name, entry, ctx.opts)
      assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == {:ok, runtime}
      assert :ok = stop_extension(ctx, name, ctx.opts)
    end)
  end

  test "a safely rolled back failed start can retry through the same Instance", ctx do
    name = unique_name(:failed_start_retry)
    attempts = start_supervised!({Agent, fn -> 0 end})

    init_result = fn ->
      Agent.get_and_update(attempts, fn
        0 -> {{:error, :first_attempt_failed}, 1}
        count -> {{:ok, %{}}, count + 1}
      end)
    end

    entry = register_module(ctx, name, init_gate: {self(), init_result})
    first = Task.async(fn -> start_extension(ctx, name, entry) end)
    assert_receive {:init_entered, first_workflow}, 5_000
    send(first_workflow, :continue_init)
    assert {:error, _reason} = Task.await(first)
    assert {:load_error, _context} = Instance.phase(instance(ctx, name))
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == :empty

    second = Task.async(fn -> start_extension(ctx, name, entry) end)
    assert_receive {:init_entered, second_workflow}, 5_000
    send(second_workflow, :continue_init)
    assert {:ok, replacement} = Task.await(second)
    assert {:running, %{pid: ^replacement}} = Instance.phase(instance(ctx, name))
  end

  test "stop during a successful start replies both callers and cleans once", ctx do
    name = unique_name(:stop_during_successful_start)
    entry = register_module(ctx, name, init_gate: {self(), {:ok, %{}}})
    parent = self()

    cleanup = fn source ->
      send(parent, {:stop_during_start_cleanup, source})
      :ok
    end

    opts = Keyword.put(ctx.opts, :callbacks, %{cleanup_probe: cleanup})
    start_task = Task.async(fn -> start_extension(ctx, name, entry, opts) end)
    assert_receive {:init_entered, workflow}, 5_000
    stop_task = Task.async(fn -> stop_extension(ctx, name, opts) end)
    send(workflow, :continue_init)

    assert {:ok, runtime} = Task.await(start_task)
    runtime_ref = Process.monitor(runtime)
    assert :ok = Task.await(stop_task)
    assert_receive {:stop_during_start_cleanup, {:extension, ^name}}
    refute_receive {:stop_during_start_cleanup, {:extension, ^name}}
    assert_receive {:DOWN, ^runtime_ref, :process, ^runtime, _reason}
  end

  test "stop during a failed start reports incomplete rollback to both callers", ctx do
    name = unique_name(:stop_during_failed_start)
    entry = register_module(ctx, name, init_gate: {self(), {:error, :start_failed}})

    cleanup = fn _source -> {:error, :rollback_cleanup_failed} end
    opts = Keyword.put(ctx.opts, :callbacks, %{cleanup_failure: cleanup})
    start_task = Task.async(fn -> start_extension(ctx, name, entry, opts) end)
    assert_receive {:init_entered, workflow}, 5_000
    stop_task = Task.async(fn -> stop_extension(ctx, name, opts) end)
    send(workflow, :continue_init)

    assert {:error, {:cleanup_failed, "init failed: :start_failed", failures}} =
             Task.await(start_task)

    assert Enum.any?(failures, &match?(%{family: :cleanup_failure}, &1))

    assert {:error, {:cleanup_failed, "init failed: :start_failed", ^failures}} =
             Task.await(stop_task)

    assert {:cleanup_failed, _context} = Instance.phase(instance(ctx, name))
  end

  test "concurrent stops finalize once", ctx do
    name = unique_name(:concurrent_stop)
    entry = register_module(ctx, name, [])
    assert {:ok, _pid} = start_extension(ctx, name, entry)
    test_pid = self()

    finalizer = fn source ->
      send(test_pid, {:finalizer_entered, self(), source})

      receive do
        :finish_finalizer -> :ok
      end
    end

    opts = Keyword.put(ctx.opts, :callbacks, %{editor_effects: finalizer})
    first = Task.async(fn -> stop_extension(ctx, name, opts) end)
    assert_receive {:finalizer_entered, finalizer_pid, {:extension, ^name}}
    second = Task.async(fn -> stop_extension(ctx, name, opts) end)
    refute Task.yield(second, 50)
    send(finalizer_pid, :finish_finalizer)

    assert :ok = Task.await(first)
    assert :ok = Task.await(second)
    refute_receive {:finalizer_entered, _, _}
    assert :stopped = Instance.phase(instance(ctx, name))
  end

  test "start during stop queues one deterministic intent", ctx do
    name = unique_name(:start_during_stop)
    entry = register_module(ctx, name, [])
    assert {:ok, first_pid} = start_extension(ctx, name, entry)
    test_pid = self()

    finalizer = fn _source ->
      send(test_pid, {:stop_barrier, self()})
      receive do: (:release -> :ok)
    end

    opts = Keyword.put(ctx.opts, :callbacks, %{editor_effects: finalizer})
    stop_task = Task.async(fn -> stop_extension(ctx, name, opts) end)
    assert_receive {:stop_barrier, barrier}
    start_task = Task.async(fn -> start_extension(ctx, name, entry, opts) end)
    refute Task.yield(start_task, 50)
    send(barrier, :release)

    assert :ok = Task.await(stop_task)
    assert {:ok, replacement} = Task.await(start_task)
    refute replacement == first_pid
    assert {:running, %{pid: ^replacement}} = Instance.phase(instance(ctx, name))
  end

  test "failed finalization keeps retry context and start cannot bypass it", ctx do
    name = unique_name(:finalizer_retry)
    entry = register_module(ctx, name, [])
    assert {:ok, runtime} = start_extension(ctx, name, entry)
    attempts = start_supervised!({Agent, fn -> 0 end})

    finalizer = fn _source ->
      Agent.get_and_update(attempts, fn
        0 -> {{:error, :editor_busy}, 1}
        count -> {:ok, count + 1}
      end)
    end

    opts = Keyword.put(ctx.opts, :callbacks, %{editor_effects: finalizer})

    assert {:error, {:source_quiesce_failed, %{reason: :editor_busy}}} =
             stop_extension(ctx, name, opts)

    assert {:error, {:cleanup_retry_required, _reason}} = start_extension(ctx, name, entry, opts)
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == {:ok, runtime}
    assert :ok = stop_extension(ctx, name, opts)
    assert :stopped = Instance.phase(instance(ctx, name))
  end

  test "second unload finalizer failure preserves an exact retry contract", ctx do
    name = unique_name(:unload_finalizer_retry)
    entry = register_module(ctx, name, [])
    attempts = start_supervised!({Agent, fn -> 0 end})

    unload_finalizer = fn _source ->
      Agent.get_and_update(attempts, fn
        0 -> {{:error, :unload_editor_busy}, 1}
        count -> {:ok, count + 1}
      end)
    end

    opts = Keyword.put(ctx.opts, :callbacks, %{editor_extension_unload: unload_finalizer})
    assert {:ok, runtime} = start_extension(ctx, name, entry, opts)

    assert {:error, {:source_quiesce_failed, %{reason: :unload_editor_busy}}} =
             stop_extension(ctx, name, opts)

    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == {:ok, runtime}
    assert CodeLease.source_status({:extension, name}, server: ctx.code_lease) == :active
    assert {:error, {:cleanup_retry_required, _reason}} = start_extension(ctx, name, entry, opts)
    assert :ok = stop_extension(ctx, name, opts)
    assert :stopped = Instance.phase(instance(ctx, name))
  end

  test "cleanup failure blocks start until a successful stop retry", ctx do
    name = unique_name(:cleanup_retry)
    entry = register_module(ctx, name, [])
    assert {:ok, _runtime} = start_extension(ctx, name, entry)
    attempts = start_supervised!({Agent, fn -> 0 end})

    cleanup = fn _source ->
      Agent.get_and_update(attempts, fn
        0 -> {{:error, :cleanup_busy}, 1}
        count -> {:ok, count + 1}
      end)
    end

    opts = Keyword.put(ctx.opts, :callbacks, %{custom_cleanup: cleanup})
    assert {:error, {:cleanup_failed, _failures}} = stop_extension(ctx, name, opts)
    assert {:error, {:cleanup_retry_required, _reason}} = start_extension(ctx, name, entry, opts)
    assert :ok = stop_extension(ctx, name, opts)
    assert {:ok, _replacement} = start_extension(ctx, name, entry, opts)
  end

  test "racing lazy triggers activate one captured artifact", ctx do
    name = unique_name(:lazy_race)
    config = [load_policy: {:on_command, [:lazy_race]}, init_gate: {self(), {:ok, %{}}}]
    _entry = register_module(ctx, name, config)
    assert :ok = ExtSupervisor.start_all(ctx.roots, ctx.registry, ctx.opts)
    authority = instance(ctx, name)

    first = Task.async(fn -> Instance.start(authority) end)
    assert_receive {:init_entered, workflow}, 5_000
    second = Task.async(fn -> Instance.start(authority) end)
    send(workflow, :continue_init)

    assert {:ok, pid} = Task.await(first)
    assert {:ok, ^pid} = Task.await(second)
  end

  test "deferred batch logs one authority exit and continues later declarations", ctx do
    name = unique_name(:deferred_continues)
    entry = register_module(ctx, name, load_policy: :deferred, runtime_test_pid: self())
    assert :ok = stop_extension(ctx, name, ctx.opts)
    Minga.Events.subscribe(:extension_deferred_batch_complete)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 Lazy.schedule_deferred_loads([
                   {:missing_deferred_authority, :missing_deferred, entry},
                   {instance(ctx, name), name, entry}
                 ])

        assert_receive {:runtime_child_started, _runtime}, 5_000

        assert_receive {:minga_event, :extension_deferred_batch_complete,
                        %DeferredBatchCompleteEvent{count: 2}}
      end)

    assert log =~ "Extension missing_deferred deferred load failed"
    assert log =~ "instance_call_exit"
  end

  test "deferred activation rejects a re-registered declaration identity", ctx do
    name = unique_name(:deferred_identity)
    original = register_module(ctx, name, load_policy: :deferred)
    assert :ok = ExtSupervisor.start_all(ctx.roots, ctx.registry, ctx.opts)
    authority = instance(ctx, name)

    :ok = ExtRegistry.register_module(ctx.registry, name, RuntimeTwo, load_policy: :deferred)
    {:ok, replacement} = ExtRegistry.get(ctx.registry, name)
    assert :ok = Instance.declare(authority, replacement, ctx.registry, ctx.opts)
    assert {:error, :stale_deferred_declaration} = Instance.start_deferred(authority, original)

    receive do
    after
      150 -> :ok
    end

    assert :stopped = Instance.phase(authority)
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == :empty
  end

  test "stale monitor and acknowledgement messages cannot alter a later runtime", ctx do
    name = unique_name(:stale_messages)
    entry = register_module(ctx, name, [])
    assert {:ok, pid} = start_extension(ctx, name, entry)
    authority = instance(ctx, name)
    authority_pid = instance_pid(ctx, name)

    send(authority_pid, {:DOWN, make_ref(), :process, pid, :kill})
    send(authority_pid, {:extension_finalizer_ack, make_ref(), :editor_effects, {:error, :stale}})
    send(authority_pid, {CodeLease, :drained, {:extension, name}, make_ref()})
    _ = Instance.phase(authority)

    assert {:running, %{pid: ^pid}} = Instance.phase(authority)
    assert {:ok, ^pid} = Instance.start(authority)
  end

  test "lifecycle spans preserve phases and structured failure metadata", ctx do
    telemetry_id = {__MODULE__, unique_name(:lifecycle_spans)}
    recipient = self()

    :telemetry.attach(
      telemetry_id,
      [:minga, :extension, :lifecycle, :stop],
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:lifecycle_span, event, measurements, metadata})
      end,
      recipient
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)
    success_name = unique_name(:span_success)
    success_entry = register_module(ctx, success_name, [], Runtime)
    assert {:ok, _runtime} = start_extension(ctx, success_name, success_entry)
    assert :ok = stop_extension(ctx, success_name, ctx.opts)

    for phase <- [:init, :child_start, :load, :stop, :cleanup] do
      assert_receive {:lifecycle_span, [:minga, :extension, :lifecycle, :stop],
                      %{duration: _duration},
                      %{extension: ^success_name, phase: ^phase, outcome: :ok}}
    end

    failure_name = unique_name(:span_failure)
    failure_entry = register_module(ctx, failure_name, [], ChildStartFailure)
    assert {:error, :child_refused_start} = start_extension(ctx, failure_name, failure_entry)

    assert_receive {:lifecycle_span, [:minga, :extension, :lifecycle, :stop],
                    %{duration: _duration},
                    %{
                      extension: ^failure_name,
                      phase: :child_start,
                      outcome: :error,
                      reason: :child_refused_start
                    }}

    assert_receive {:lifecycle_span, [:minga, :extension, :lifecycle, :stop],
                    %{duration: _duration},
                    %{
                      extension: ^failure_name,
                      phase: :load,
                      outcome: :error,
                      reason: :child_refused_start
                    }}
  end

  test "permanent runtime crashes publish replacement telemetry before the next request", ctx do
    name = unique_name(:permanent_restart)
    telemetry_id = {__MODULE__, name}
    test_pid = self()

    :telemetry.attach(
      telemetry_id,
      [:minga, :extension, :lifecycle, :crash_restart_count],
      fn _event, measurements, metadata, recipient ->
        send(recipient, {:restart_telemetry, measurements, metadata})
      end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)
    entry = register_module(ctx, name, restart: :permanent)
    assert {:ok, pid} = start_extension(ctx, name, entry)
    assert_receive {:restart_telemetry, %{count: 0}, %{extension: ^name}}
    Process.exit(pid, :kill)

    replacement = await_runtime_replacement(ctx, name, pid)
    assert_receive {:restart_telemetry, %{count: 1}, %{extension: ^name}}

    assert {:ok, ^replacement} = Instance.start(instance(ctx, name))
    assert {:ok, projected} = ExtRegistry.get(ctx.registry, name)
    assert projected.pid == replacement
  end

  test "temporary and transient policies are interpreted only by Instance", ctx do
    temporary = unique_name(:temporary_runtime)
    temporary_entry = register_module(ctx, temporary, restart: :temporary)
    assert {:ok, temporary_pid} = start_extension(ctx, temporary, temporary_entry)
    Process.exit(temporary_pid, :kill)
    assert_eventually_phase(ctx, temporary, :crashed)
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, temporary)) == :empty

    transient = unique_name(:transient_runtime)
    transient_entry = register_module(ctx, transient, [restart: :transient], RuntimeTwo)
    assert {:ok, transient_pid} = start_extension(ctx, transient, transient_entry)
    assert :ok = Agent.stop(transient_pid, :normal)
    assert_eventually_phase(ctx, transient, :stopped)
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, transient)) == :empty
  end

  test "transient policy replaces an abnormally exited runtime", ctx do
    name = unique_name(:transient_runtime_crash)
    entry = register_module(ctx, name, [restart: :transient], RuntimeTwo)
    assert {:ok, crashed_pid} = start_extension(ctx, name, entry)
    Process.exit(crashed_pid, :kill)
    replacement = await_runtime_replacement(ctx, name, crashed_pid)
    assert {:ok, ^replacement} = Instance.start(instance(ctx, name))
  end

  test "Instance death cancels blocked start work before a child exists", ctx do
    name = unique_name(:blocked_start_crash)
    entry = register_module(ctx, name, init_gate: {self(), {:ok, %{}}})
    parent = self()

    caller =
      spawn(fn ->
        result = start_extension(ctx, name, entry)
        send(parent, {:blocked_start_caller, result})
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:init_entered, worker}, 5_000
    worker_ref = Process.monitor(worker)
    authority = instance_pid(ctx, name)
    Process.exit(authority, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    assert_receive {:blocked_start_caller, {:error, {:authority_unavailable, ^name, _reason}}}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert :ok = stop_extension(ctx, name, ctx.opts)
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == :empty
  end

  test "Instance and RuntimeSupervisor death after child start clean without duplication", ctx do
    for crash_target <- [:instance, :runtime_supervisor] do
      name = unique_name(:"child_started_crash_#{crash_target}")
      module = if crash_target == :instance, do: Runtime, else: RuntimeTwo
      entry = register_module(ctx, name, [runtime_test_pid: self()], module)
      callback_registry = Process.whereis(ctx.callback_registry)
      :ok = :sys.suspend(callback_registry)
      parent = self()

      _caller =
        spawn(fn ->
          result = start_extension(ctx, name, entry)
          send(parent, {:child_started_caller, crash_target, result})
        end)

      assert_receive {:runtime_child_started, runtime}, 5_000
      runtime_ref = Process.monitor(runtime)

      target =
        case crash_target do
          :instance -> instance_pid(ctx, name)
          :runtime_supervisor -> runtime_supervisor_pid(ctx, name)
        end

      Process.exit(target, :kill)

      assert_receive {:child_started_caller, ^crash_target,
                      {:error, {:authority_unavailable, ^name, _reason}}}

      assert_receive {:DOWN, ^runtime_ref, :process, ^runtime, _reason}, 5_000
      refute_receive {:runtime_child_started, _duplicate}

      :ok = :sys.resume(callback_registry)
      assert :ok = stop_extension(ctx, name, ctx.opts)
      assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == :empty

      assert {:ok, replacement} = start_extension(ctx, name, entry)
      assert_receive {:runtime_child_started, ^replacement}
      refute_receive {:runtime_child_started, _duplicate}
      assert :ok = stop_extension(ctx, name, ctx.opts)
    end
  end

  test "Instance and RuntimeSupervisor crashes resume a blocked stop without leaks", ctx do
    for crash_target <- [:instance, :runtime_supervisor] do
      name = unique_name(crash_target)
      module = if crash_target == :instance, do: Runtime, else: RuntimeTwo
      entry = register_module(ctx, name, [], module)
      assert {:ok, runtime} = start_extension(ctx, name, entry)
      runtime_ref = Process.monitor(runtime)
      parent = self()

      finalizer = fn _source ->
        send(parent, {:blocked_finalizer, crash_target, self()})
        receive do: (:release -> :ok)
      end

      opts = Keyword.put(ctx.opts, :callbacks, %{editor_effects: finalizer})

      caller =
        spawn(fn ->
          result = stop_extension(ctx, name, opts)
          send(parent, {:blocked_stop_caller, crash_target, result})
        end)

      caller_ref = Process.monitor(caller)
      assert_receive {:blocked_finalizer, ^crash_target, worker}
      worker_ref = Process.monitor(worker)

      target =
        case crash_target do
          :instance -> instance_pid(ctx, name)
          :runtime_supervisor -> runtime_supervisor_pid(ctx, name)
        end

      Process.exit(target, :kill)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _worker_reason}

      assert_receive {:blocked_stop_caller, ^crash_target,
                      {:error, {:authority_unavailable, ^name, _reason}}}

      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
      assert_receive {:DOWN, ^runtime_ref, :process, ^runtime, _reason}, 5_000
      assert :ok = stop_extension(ctx, name, ctx.opts)
      assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == :empty
    end
  end

  test "runtime DOWN before start completion rolls back queued lifecycle requests", ctx do
    name = unique_name(:runtime_down_during_start)
    source = {:extension, name}
    parent = self()

    cleanup = fn cleanup_source ->
      send(parent, {:runtime_down_start_cleanup, cleanup_source})
      :ok
    end

    entry = register_module(ctx, name, [runtime_test_pid: self()], CrashContributionRuntime)
    callback_registry = Process.whereis(ctx.callback_registry)
    :ok = :sys.suspend(callback_registry)
    opts = Keyword.put(ctx.opts, :callbacks, %{runtime_down_cleanup: cleanup})

    first_start = Task.async(fn -> start_extension(ctx, name, entry, opts) end)
    assert_receive {:runtime_child_started, runtime}, 5_000
    authority = instance(ctx, name)

    assert {:starting, %{runtime: %{pid: ^runtime}, worker: %Worker{pid: start_worker}}} =
             eventually(fn ->
               case Instance.phase(authority) do
                 {:starting, %{runtime: %{pid: ^runtime}, worker: %Worker{}}} = phase -> phase
                 _phase -> nil
               end
             end)

    worker_ref = Process.monitor(start_worker)
    second_start = Task.async(fn -> Instance.start(authority) end)
    stop = Task.async(fn -> stop_extension(ctx, name, opts) end)

    assert {:starting, %{waiters: [_, _] = waiters, stop_waiters: [_] = stop_waiters}} =
             eventually(fn ->
               case Instance.phase(authority) do
                 {:starting, %{waiters: [_, _], stop_waiters: [_]}} = phase -> phase
                 _phase -> nil
               end
             end)

    assert [_, _] = waiters
    assert [_] = stop_waiters

    runtime_ref = Process.monitor(runtime)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^runtime_ref, :process, ^runtime, :killed}

    assert {:stopping, _context} =
             eventually(fn ->
               case Instance.phase(authority) do
                 {:stopping, _context} = phase -> phase
                 _phase -> nil
               end
             end)

    assert_receive {:DOWN, ^worker_ref, :process, ^start_worker, :killed}
    assert {:stopping, _context} = Instance.phase(authority)
    :ok = :sys.resume(callback_registry)

    assert {:error, :killed} = Task.await(first_start)
    assert {:error, :killed} = Task.await(second_start)
    assert :ok = Task.await(stop)
    assert_receive {:runtime_down_start_cleanup, ^source}
    refute_receive {:runtime_down_start_cleanup, ^source}

    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == :empty
    assert :error = CommandRegistry.lookup(ctx.commands, :crash_contribution_command)

    assert CallbackRegistry.callbacks_for_source(:buffer_saved, source, ctx.callback_registry) ==
             []

    assert CodeLease.source_status(source, server: ctx.code_lease) == :unknown
    assert CodeLease.active_leases(source: source, server: ctx.code_lease) == []
    assert {:load_error, %{reason: :killed}} = Instance.phase(authority)

    assert {:ok, %{status: :load_error, pid: nil, last_error: :killed}} =
             ExtRegistry.get(ctx.registry, name)

    retry_opts = Keyword.put(ctx.opts, :callbacks, %{})
    assert {:ok, replacement} = start_extension(ctx, name, entry, retry_opts)
    assert_receive {:runtime_child_started, ^replacement}
    assert {:running, %{pid: ^replacement}} = Instance.phase(authority)
    assert :ok = stop_extension(ctx, name, retry_opts)
  end

  test "transition timeout after child start rolls back the known runtime without duplication",
       ctx do
    name = unique_name(:known_runtime_timeout)
    entry = register_module(ctx, name, [runtime_test_pid: self()], CrashContributionRuntime)
    callback_registry = Process.whereis(ctx.callback_registry)
    :ok = :sys.suspend(callback_registry)

    timeout_ms = 5_000
    opts = Keyword.put(ctx.opts, :transition_timeout_ms, timeout_ms)
    start_task = Task.async(fn -> start_extension(ctx, name, entry, opts) end)
    assert_receive {:runtime_child_started, runtime}, 10_000
    runtime_ref = Process.monitor(runtime)
    authority = instance_pid(ctx, name)

    worker_id =
      eventually(fn ->
        case :sys.get_state(authority) do
          %{phase: {:starting, %{runtime: %{pid: ^runtime}, worker: %Worker{id: id}}}} -> id
          _state -> nil
        end
      end)

    send(authority, {Worker, :timeout, worker_id, :start})
    _barrier = :sys.get_state(authority)
    :ok = :sys.resume(callback_registry)

    assert {:error, {:transition_timeout, :start, ^timeout_ms}} =
             Task.await(start_task, timeout_ms + 1_000)

    assert_receive {:DOWN, ^runtime_ref, :process, ^runtime, _reason}, 5_000
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == :empty
    assert :error = CommandRegistry.lookup(ctx.commands, :crash_contribution_command)
    assert {:ok, projection} = ExtRegistry.get(ctx.registry, name)
    assert projection.status == :load_error
    assert projection.pid == nil

    assert {:ok, replacement} = start_extension(ctx, name, entry)
    assert_receive {:runtime_child_started, ^replacement}
    assert {:ok, _command} = CommandRegistry.lookup(ctx.commands, :crash_contribution_command)
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == {:ok, replacement}
    assert :ok = stop_extension(ctx, name, ctx.opts)
  end

  test "blocked child start MFA replaces the wedged runtime branch within the authority deadline",
       ctx do
    name = unique_name(:blocked_child_start)
    attempts = start_supervised!({Agent, fn -> 0 end})

    entry =
      register_module(
        ctx,
        name,
        [attempts: attempts, runtime_test_pid: self()],
        BlockedThenStarts
      )

    timeout_ms = 25

    opts =
      ctx.opts
      |> Keyword.put(:transition_timeout_ms, timeout_ms)
      |> Keyword.put(:runtime_query_timeout_ms, 10)

    start_task = Task.async(fn -> start_extension(ctx, name, entry, opts) end)
    assert_receive {:blocked_child_start_mfa, old_runtime_supervisor}
    old_instance = instance_pid(ctx, name)
    supervisor_ref = Process.monitor(old_runtime_supervisor)

    assert {:error, {:transition_timeout, :start, ^timeout_ms}} = Task.await(start_task, 1_000)
    assert_receive {:DOWN, ^supervisor_ref, :process, ^old_runtime_supervisor, :killed}
    _new_instance = await_new_instance(ctx, name, old_instance)

    assert eventually(fn ->
             RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == :empty
           end)

    retry_task = Task.async(fn -> start_extension(ctx, name, entry) end)
    assert_receive {:retry_child_start_mfa, retry_runtime_supervisor}, 10_000
    refute Task.yield(retry_task, 50)

    send(retry_runtime_supervisor, :release_retry_child_start)
    assert {:ok, runtime} = Task.await(retry_task)
    assert_receive {:runtime_child_started, ^runtime}
    refute_receive {:runtime_child_started, _duplicate}
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == {:ok, runtime}
    assert :ok = stop_extension(ctx, name, ctx.opts)
  end

  test "infinite runtime shutdown returns a typed failure and replaces the wedged branch", ctx do
    name = unique_name(:infinite_shutdown)
    attempts = start_supervised!({Agent, fn -> 0 end})

    entry =
      register_module(
        ctx,
        name,
        [attempts: attempts, runtime_test_pid: self()],
        InfiniteShutdownThenStops
      )

    assert {:ok, runtime} = start_extension(ctx, name, entry)
    assert_receive {:runtime_child_started, ^runtime}
    assert_receive {:infinite_shutdown_ready, ^runtime}
    runtime_ref = Process.monitor(runtime)
    old_instance = instance_pid(ctx, name)
    old_runtime_supervisor = runtime_supervisor_pid(ctx, name)
    supervisor_ref = Process.monitor(old_runtime_supervisor)
    opts = Keyword.put(ctx.opts, :callback_timeout_ms, 25)

    stop_task = Task.async(fn -> stop_extension(ctx, name, opts) end)

    assert {:error, {:runtime_termination_failed, {:transition_timeout, :terminate, 25}}} =
             Task.await(stop_task, 1_000)

    assert_receive {:DOWN, ^runtime_ref, :process, ^runtime, :killed}
    assert_receive {:DOWN, ^supervisor_ref, :process, ^old_runtime_supervisor, :killed}
    _new_instance = await_new_instance(ctx, name, old_instance)

    assert {:ok, replacement} =
             eventually(fn ->
               case start_extension(ctx, name, entry) do
                 {:ok, _pid} = started -> started
                 {:error, _reason} -> nil
               end
             end)

    assert_receive {:runtime_child_started, ^replacement}
    refute replacement == runtime
    refute_receive {:runtime_child_started, _duplicate}
    assert :ok = stop_extension(ctx, name, ctx.opts)
  end

  test "bounded finalizer and cleanup workers reply queued callers with typed failures", ctx do
    finalizer_name = unique_name(:finalizer_timeout)
    finalizer_entry = register_module(ctx, finalizer_name, [])
    assert {:ok, runtime} = start_extension(ctx, finalizer_name, finalizer_entry)
    parent = self()

    blocked_finalizer = fn _source ->
      send(parent, {:timeout_worker, :finalizer, self()})
      receive do: (:never -> :ok)
    end

    finalizer_opts =
      ctx.opts
      |> Keyword.put(:callback_timeout_ms, 25)
      |> Keyword.put(:callbacks, %{editor_effects: blocked_finalizer})

    finalizer_stop = Task.async(fn -> stop_extension(ctx, finalizer_name, finalizer_opts) end)
    assert_receive {:timeout_worker, :finalizer, finalizer_worker}
    finalizer_ref = Process.monitor(finalizer_worker)

    assert {:error,
            {:source_quiesce_failed, {:transition_timeout, {:finalizer, :editor_effects}, 25}}} =
             Task.await(finalizer_stop)

    assert_receive {:DOWN, ^finalizer_ref, :process, ^finalizer_worker, :killed}

    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, finalizer_name)) ==
             {:ok, runtime}

    assert :ok = stop_extension(ctx, finalizer_name, Keyword.put(ctx.opts, :callbacks, %{}))

    cleanup_name = unique_name(:cleanup_timeout)
    cleanup_entry = register_module(ctx, cleanup_name, [], RuntimeTwo)
    assert {:ok, _runtime} = start_extension(ctx, cleanup_name, cleanup_entry)

    blocked_cleanup = fn _source ->
      send(parent, {:timeout_worker, :cleanup, self()})
      receive do: (:never -> :ok)
    end

    cleanup_opts =
      ctx.opts
      |> Keyword.put(:callback_timeout_ms, 25)
      |> Keyword.put(:callbacks, %{blocked_cleanup: blocked_cleanup})

    cleanup_stop = Task.async(fn -> stop_extension(ctx, cleanup_name, cleanup_opts) end)
    assert_receive {:timeout_worker, :cleanup, cleanup_worker}
    cleanup_ref = Process.monitor(cleanup_worker)

    assert {:error,
            {:cleanup_failed,
             [
               %{
                 family: :cleanup_worker,
                 reason: {:transition_timeout, :cleanup, 25}
               }
             ]}} = Task.await(cleanup_stop)

    assert_receive {:DOWN, ^cleanup_ref, :process, ^cleanup_worker, :killed}
    assert :ok = stop_extension(ctx, cleanup_name, Keyword.put(ctx.opts, :callbacks, %{}))
  end

  test "declaration removal after child start fails projection and rolls back", ctx do
    name = unique_name(:projection_removal)
    entry = register_module(ctx, name, runtime_test_pid: self())
    callback_registry = Process.whereis(ctx.callback_registry)
    :ok = :sys.suspend(callback_registry)
    start_task = Task.async(fn -> start_extension(ctx, name, entry) end)
    assert_receive {:runtime_child_started, runtime}, 5_000
    runtime_ref = Process.monitor(runtime)
    :ok = ExtRegistry.unregister(ctx.registry, name)
    :ok = :sys.resume(callback_registry)

    assert {:error, {:extension_not_declared, ^name}} = Task.await(start_task)
    assert_receive {:DOWN, ^runtime_ref, :process, ^runtime, _reason}, 5_000
    assert :error = ExtRegistry.get(ctx.registry, name)
    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == :empty
  end

  test "restart policies cover normal shutdown tuple-shutdown and abnormal reasons", ctx do
    telemetry_id = {__MODULE__, unique_name(:restart_matrix)}
    recipient = self()

    :telemetry.attach_many(
      telemetry_id,
      [
        [:minga, :extension, :lifecycle, :crash_restart_count],
        [:minga, :extension, :lifecycle, :stop],
        [:minga, :extension, :lifecycle, :terminal]
      ],
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:policy_telemetry, event, measurements, metadata})
      end,
      recipient
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    permanent = unique_name(:permanent_matrix)
    transient = unique_name(:transient_matrix)
    temporary = unique_name(:temporary_matrix)

    permanent_entry = register_module(ctx, permanent, [restart: :permanent], Runtime)
    transient_entry = register_module(ctx, transient, [restart: :transient], RuntimeTwo)
    temporary_entry = register_module(ctx, temporary, [restart: :temporary], RuntimeThree)

    assert_policy_matrix(ctx, permanent, permanent_entry, :permanent)
    assert_policy_matrix(ctx, transient, transient_entry, :transient)
    assert_policy_matrix(ctx, temporary, temporary_entry, :temporary)
  end

  test "an Instance crash adopts only its own local runtime", ctx do
    first = unique_name(:adopt_first)
    second = unique_name(:adopt_second)
    first_entry = register_module(ctx, first, [])
    second_entry = register_module(ctx, second, [], RuntimeTwo)
    assert {:ok, first_runtime} = start_extension(ctx, first, first_entry)
    assert {:ok, second_runtime} = start_extension(ctx, second, second_entry)

    old_instance = instance_pid(ctx, first)
    Process.exit(old_instance, :kill)
    new_instance = await_new_instance(ctx, first, old_instance)

    assert {:ok, ^first_runtime} = Instance.start(new_instance)
    refute first_runtime == second_runtime
    assert {:ok, ^second_runtime} = Instance.start(instance(ctx, second))
  end

  test "RuntimeSupervisor replacement restarts Instance after an empty local supervisor", ctx do
    name = unique_name(:runtime_supervisor_crash)
    entry = register_module(ctx, name, [])
    assert {:ok, runtime} = start_extension(ctx, name, entry)
    old_instance = instance_pid(ctx, name)
    old_runtime_supervisor = runtime_supervisor_pid(ctx, name)

    Process.exit(old_runtime_supervisor, :kill)
    new_instance = await_new_instance(ctx, name, old_instance)
    assert {:ok, replacement} = eventually(fn -> Instance.start(new_instance) end)
    refute replacement == runtime
    refute runtime_supervisor_pid(ctx, name) == old_runtime_supervisor
  end

  test "live CodeLease owner triggers a bounded retryable drain failure", ctx do
    name = unique_name(:lease_drain_timeout)
    entry = register_module(ctx, name, [])
    assert {:ok, runtime} = start_extension(ctx, name, entry)
    owner = spawn(fn -> receive do: (:done -> :ok) end)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

    assert {:ok, lease} =
             CodeLease.admit_callback({:extension, name}, Runtime, :editor_event,
               server: ctx.code_lease,
               owner: owner
             )

    opts = Keyword.put(ctx.opts, :drain_timeout_ms, 25)

    assert {:error, {:code_lease_drain_timeout, 25}} =
             stop_extension(ctx, name, opts)

    assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == {:ok, runtime}
    assert CodeLease.source_status({:extension, name}, server: ctx.code_lease) == :active

    assert {:error, {:cleanup_retry_required, {:code_lease_drain_timeout, 25}}} =
             start_extension(ctx, name, entry, opts)

    assert :ok = CodeLease.release(lease)
    send(owner, :done)
    assert :ok = stop_extension(ctx, name, opts)
  end

  test "terminal crash replies queued stop and start waiters exactly once", ctx do
    name = unique_name(:terminal_queued_waiters)
    parent = self()

    finalizer = fn _source ->
      send(parent, {:terminal_finalizer_blocked, self()})

      receive do
        :release -> {:error, :terminal_editor_failure}
      end
    end

    opts = Keyword.put(ctx.opts, :callbacks, %{editor_effects: finalizer})
    entry = register_module(ctx, name, restart: :temporary)
    assert {:ok, runtime} = start_extension(ctx, name, entry, opts)
    GenServer.stop(runtime, :abnormal)
    assert_receive {:terminal_finalizer_blocked, finalizer_worker}

    start_task = Task.async(fn -> start_extension(ctx, name, entry, opts) end)
    stop_task = Task.async(fn -> stop_extension(ctx, name, opts) end)
    refute Task.yield(start_task, 25)
    refute Task.yield(stop_task, 25)
    send(finalizer_worker, :release)

    expected =
      {:terminal_crash_cleanup_failed,
       [
         quiesce: %{
           family: :editor_effects,
           source: {:extension, name},
           reason: :terminal_editor_failure
         }
       ]}

    assert {:error, ^expected} = Task.await(start_task)
    assert {:error, ^expected} = Task.await(stop_task)
    assert {:load_error, %{reason: ^expected}} = Instance.phase(instance(ctx, name))
    refute_receive {:terminal_finalizer_blocked, _duplicate}
  end

  test "non-restarting abnormal crash removes contributions and publishes exact crash", ctx do
    name = unique_name(:terminal_crash_projection)
    entry = register_module(ctx, name, [], CrashContributionRuntime)
    source = {:extension, name}
    assert {:ok, runtime} = start_extension(ctx, name, entry)
    assert {:ok, _command} = CommandRegistry.lookup(ctx.commands, :crash_contribution_command)

    assert CallbackRegistry.callbacks_for_source(:buffer_saved, source, ctx.callback_registry) !=
             []

    GenServer.stop(runtime, :abnormal)

    assert {:crashed, %{reason: :abnormal}} =
             eventually(fn ->
               case Instance.phase(instance(ctx, name)) do
                 {:crashed, %{reason: :abnormal}} = phase -> phase
                 _phase -> nil
               end
             end)

    assert {:ok, projection} = ExtRegistry.get(ctx.registry, name)
    assert projection.status == :crashed
    assert projection.pid == nil
    assert projection.last_error == :abnormal
    assert :error = CommandRegistry.lookup(ctx.commands, :crash_contribution_command)

    assert CallbackRegistry.callbacks_for_source(:buffer_saved, source, ctx.callback_registry) ==
             []

    assert CodeLease.source_status(source, server: ctx.code_lease) == :inactive
  end

  test "CodeLease drain completion is event-driven", ctx do
    source = {:extension, unique_name(:lease_drain)}
    assert :ok = CodeLease.activate_source(source, [Runtime], server: ctx.code_lease)
    owner = spawn(fn -> receive do: (:done -> :ok) end)

    assert {:ok, lease} =
             CodeLease.admit_callback(source, Runtime, :editor_event,
               server: ctx.code_lease,
               owner: owner
             )

    assert {:ok, _token} = CodeLease.quiesce_source(source, server: ctx.code_lease)
    ref = make_ref()
    assert :ok = CodeLease.notify_when_drained(source, self(), ref, server: ctx.code_lease)
    refute_receive {CodeLease, :drained, ^source, ^ref}
    assert :ok = CodeLease.release(lease)
    assert_receive {CodeLease, :drained, ^source, ^ref}
    send(owner, :done)
  end

  @spec assert_policy_matrix(
          map(),
          atom(),
          ExtRegistry.entry(),
          :permanent | :transient | :temporary
        ) :: :ok
  defp assert_policy_matrix(ctx, name, entry, policy) do
    assert {:ok, initial_pid} = start_extension(ctx, name, entry)

    assert_receive {:policy_telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                    %{count: 0}, %{extension: ^name}},
                   5_000

    final_pid =
      Enum.reduce([:normal, :shutdown, {:shutdown, :policy}, :abnormal], initial_pid, fn reason,
                                                                                         pid ->
        terminate_with_reason(pid, reason)

        assert_policy_transition(
          ctx,
          name,
          entry,
          reason,
          pid,
          restart_expected?(policy, reason)
        )
      end)

    assert is_pid(final_pid)
    assert :ok = stop_extension(ctx, name, ctx.opts)
    :ok
  end

  @spec assert_policy_transition(
          map(),
          atom(),
          ExtRegistry.entry(),
          term(),
          pid(),
          boolean()
        ) :: pid()
  defp assert_policy_transition(ctx, name, _entry, _reason, pid, true) do
    assert_receive {:policy_telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                    %{count: _count}, %{extension: ^name}},
                   5_000

    assert {:ok, replacement} = Instance.start(instance(ctx, name))
    refute replacement == pid
    replacement
  end

  defp assert_policy_transition(ctx, name, entry, reason, _pid, false) do
    assert_receive {:policy_telemetry, [:minga, :extension, :lifecycle, :stop],
                    %{duration: _duration}, %{extension: ^name, phase: :cleanup, outcome: :ok}},
                   5_000

    expected_phase = terminal_policy_phase(reason)

    assert_receive {:policy_telemetry, [:minga, :extension, :lifecycle, :terminal], %{count: 1},
                    %{extension: ^name, phase: ^expected_phase}},
                   5_000

    assert {:ok, replacement} = start_extension(ctx, name, entry)

    assert_receive {:policy_telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                    %{count: _count}, %{extension: ^name}},
                   5_000

    replacement
  end

  @spec terminal_policy_phase(term()) :: Minga.Extension.Instance.State.phase()
  defp terminal_policy_phase(:abnormal), do: {:crashed, %{reason: :abnormal}}
  defp terminal_policy_phase(_reason), do: :stopped

  @spec terminate_with_reason(pid(), term()) :: :ok
  defp terminate_with_reason(pid, :normal), do: Agent.stop(pid, :normal)
  defp terminate_with_reason(pid, reason), do: GenServer.stop(pid, reason)

  @spec restart_expected?(:permanent | :transient | :temporary, term()) :: boolean()
  defp restart_expected?(:permanent, _reason), do: true
  defp restart_expected?(:transient, :abnormal), do: true
  defp restart_expected?(_policy, _reason), do: false

  @spec register_module(map(), atom(), keyword(), module()) :: ExtRegistry.entry()
  defp register_module(ctx, name, config, module \\ Runtime) do
    :ok = ExtRegistry.register_module(ctx.registry, name, module, config)
    {:ok, entry} = ExtRegistry.get(ctx.registry, name)
    entry
  end

  @spec start_extension(map(), atom(), ExtRegistry.entry(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  defp start_extension(ctx, name, entry, opts \\ []) do
    ExtSupervisor.start_extension(
      ctx.roots,
      ctx.registry,
      name,
      entry,
      Keyword.merge(ctx.opts, opts)
    )
  end

  @spec stop_extension(map(), atom(), keyword()) :: :ok | {:error, term()}
  defp stop_extension(ctx, name, opts) do
    {:ok, entry} = ExtRegistry.get(ctx.registry, name)
    ExtSupervisor.stop_extension(ctx.roots, ctx.registry, name, entry, opts)
  end

  @spec instance_registry(map()) :: atom()
  defp instance_registry(ctx), do: InstanceRegistry.registry_for_root(ctx.roots)

  @spec instance(map(), atom()) :: GenServer.server()
  defp instance(ctx, name) do
    InstanceRegistry.via(instance_registry(ctx), :instance, name)
  end

  @spec instance_pid(map(), atom()) :: pid()
  defp instance_pid(ctx, name) do
    InstanceRegistry.whereis(InstanceRegistry.registry_for_root(ctx.roots), :instance, name)
  end

  @spec runtime_supervisor(map(), atom()) :: GenServer.server()
  defp runtime_supervisor(ctx, name) do
    InstanceRegistry.via(InstanceRegistry.registry_for_root(ctx.roots), :runtime, name)
  end

  @spec runtime_supervisor_pid(map(), atom()) :: pid()
  defp runtime_supervisor_pid(ctx, name) do
    InstanceRegistry.whereis(InstanceRegistry.registry_for_root(ctx.roots), :runtime, name)
  end

  @spec await_runtime_replacement(map(), atom(), pid()) :: pid()
  defp await_runtime_replacement(ctx, name, old_pid) do
    eventually(fn ->
      case RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) do
        {:ok, pid} when pid != old_pid -> pid
        _other -> nil
      end
    end)
  end

  @spec await_new_instance(map(), atom(), pid()) :: GenServer.server()
  defp await_new_instance(ctx, name, old_pid) do
    eventually(fn ->
      case instance_pid(ctx, name) do
        pid when is_pid(pid) and pid != old_pid -> instance(ctx, name)
        _other -> nil
      end
    end)
  end

  @spec assert_eventually_phase(map(), atom(), atom()) :: :ok
  defp assert_eventually_phase(ctx, name, tag) do
    _ =
      eventually(fn ->
        case Instance.phase(instance(ctx, name)) do
          {^tag, _context} -> :ok
          ^tag -> :ok
          _phase -> nil
        end
      end)

    :ok
  end

  @spec eventually((-> result), non_neg_integer()) :: result when result: var
  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        receive do
        after
          10 -> eventually(fun, attempts - 1)
        end

      false ->
        receive do
        after
          10 -> eventually(fun, attempts - 1)
        end

      result ->
        result
    end
  end

  defp eventually(fun, 0), do: flunk("condition not met: #{inspect(fun.())}")

  @spec unique_name(atom()) :: atom()
  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
end
