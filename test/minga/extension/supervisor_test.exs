defmodule Minga.Extension.SupervisorTest do
  # Runtime code compilation and fixed Minga.TestExtensions module names are global.
  use ExUnit.Case, async: false

  # Runtime code compilation makes these inherently slow (~250ms).
  # Excluded from test.llm; runs in test.heavy and full suite.
  @moduletag :heavy

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ArtifactGenerationState
  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CallbackRegistry
  alias Minga.Extension.CodeLease
  alias Minga.Extension.InstanceRegistry
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.RuntimeSupervisor
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap.Active, as: KeymapActive

  setup do
    reg_name = :"ext_reg_#{System.unique_integer([:positive])}"
    sup_name = :"ext_sup_#{System.unique_integer([:positive])}"
    cmd_reg_name = :"ext_cmd_reg_#{System.unique_integer([:positive])}"

    {:ok, _} = ExtRegistry.start_link(name: reg_name)
    {:ok, _} = ExtSupervisor.start_link(name: sup_name)
    {:ok, _} = CommandRegistry.start_link(name: cmd_reg_name)

    {:ok, registry: reg_name, supervisor: sup_name, command_registry: cmd_reg_name}
  end

  describe "start_extension/4" do
    test "starts a valid extension from a local path", ctx do
      {path, cleanup} =
        make_extension("ValidExt", """
        defmodule Minga.TestExtensions.ValidExt do
          use Minga.Extension

          @impl true
          def name, do: :valid_ext

          @impl true
          def description, do: "A test extension"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.ValidExt)
        :code.delete(Minga.TestExtensions.ValidExt)
      end)

      :ok = ExtRegistry.register(ctx.registry, :valid_ext, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :valid_ext)

      assert {:ok, pid} =
               ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :valid_ext, entry)

      assert Process.alive?(pid)

      {:ok, updated} = ExtRegistry.get(ctx.registry, :valid_ext)
      assert updated.status == :running
      assert updated.pid == pid
      assert updated.module == Minga.TestExtensions.ValidExt
    end

    test "returns the running pid instead of starting a duplicate child", ctx do
      {path, cleanup} =
        make_extension("AlreadyRunningExt", """
        defmodule Minga.TestExtensions.AlreadyRunningExt do
          use Minga.Extension

          @impl true
          def name, do: :already_running_ext

          @impl true
          def description, do: "Already running test extension"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.AlreadyRunningExt)
        :code.delete(Minga.TestExtensions.AlreadyRunningExt)
      end)

      :ok = ExtRegistry.register(ctx.registry, :already_running_ext, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :already_running_ext)

      assert {:ok, pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :already_running_ext,
                 entry
               )

      assert {:ok, ^pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :already_running_ext,
                 entry
               )

      assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, :already_running_ext)) ==
               {:ok, pid}
    end

    test "registry projection is repaired from the Instance rather than used as authority", ctx do
      {path, cleanup} =
        make_extension("StaleRegistryPidExt", """
        defmodule Minga.TestExtensions.StaleRegistryPidExt do
          use Minga.Extension

          @impl true
          def name, do: :stale_registry_pid_ext

          @impl true
          def description, do: "Stale registry pid test extension"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.StaleRegistryPidExt)
        :code.delete(Minga.TestExtensions.StaleRegistryPidExt)
      end)

      :ok = ExtRegistry.register(ctx.registry, :stale_registry_pid_ext, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :stale_registry_pid_ext)

      assert {:ok, pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :stale_registry_pid_ext,
                 entry
               )

      stale_pid = self()

      ExtRegistry.update(ctx.registry, :stale_registry_pid_ext,
        status: :running,
        pid: stale_pid,
        module: Minga.TestExtensions.StaleRegistryPidExt
      )

      assert {:ok, ^pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :stale_registry_pid_ext,
                 entry
               )

      {:ok, updated} = ExtRegistry.get(ctx.registry, :stale_registry_pid_ext)
      assert updated.pid == pid

      assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, :stale_registry_pid_ext)) ==
               {:ok, pid}
    end

    test "records load_error for nonexistent path", ctx do
      :ok =
        ExtRegistry.register(
          ctx.registry,
          :missing,
          "/tmp/does_not_exist_#{System.unique_integer([:positive])}",
          []
        )

      {:ok, entry} = ExtRegistry.get(ctx.registry, :missing)

      assert {:error, _reason} =
               ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :missing, entry)

      {:ok, updated} = ExtRegistry.get(ctx.registry, :missing)
      assert updated.status == :load_error
    end

    test "records load_error for extension with no .ex files", ctx do
      dir = Path.join(System.tmp_dir!(), "empty_ext_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      :ok = ExtRegistry.register(ctx.registry, :empty, dir, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :empty)

      assert {:error, _reason} =
               ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :empty, entry)

      {:ok, updated} = ExtRegistry.get(ctx.registry, :empty)
      assert updated.status == :load_error
    end

    test "records load_error when init returns error", ctx do
      {path, cleanup} =
        make_extension("FailInit", """
        defmodule Minga.TestExtensions.FailInit do
          use Minga.Extension

          @impl true
          def name, do: :fail_init

          @impl true
          def description, do: "Fails to init"

          @impl true
          def version, do: "0.1.0"

          @impl true
          def init(_config), do: {:error, :something_wrong}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.FailInit)
        :code.delete(Minga.TestExtensions.FailInit)
      end)

      :ok = ExtRegistry.register(ctx.registry, :fail_init, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :fail_init)

      assert {:error, _} =
               ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :fail_init, entry)

      {:ok, updated} = ExtRegistry.get(ctx.registry, :fail_init)
      assert updated.status == :load_error
    end

    test "records load_error when a hex application cannot start", ctx do
      package = "missing_hex_app_#{System.unique_integer([:positive])}"

      :ok = ExtRegistry.register_hex(ctx.registry, :hex_start_fail, package, app: :hex_start_fail)
      {:ok, entry} = ExtRegistry.get(ctx.registry, :hex_start_fail)

      assert {:error, {:hex_application_start_failed, :hex_start_fail, _reason}} =
               ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :hex_start_fail, entry)

      {:ok, updated} = ExtRegistry.get(ctx.registry, :hex_start_fail)
      assert updated.status == :load_error
      assert updated.pid == nil
    end

    test "Hex sources adopt complete application inventories before empty or event registration",
         ctx do
      authorities = start_runtime_authorities(ctx)

      empty_root = unique_runtime_module("HexEmptyRoot")
      event_root = unique_runtime_module("HexEventRoot")
      event_handler = unique_runtime_module("HexEventHandler")
      empty_app = unique_runtime_name(:hex_empty_app)
      event_app = unique_runtime_name(:hex_event_app)

      compile_runtime_module("""
      defmodule #{inspect(empty_root)} do
        use Minga.Extension
        @impl true
        def name, do: :hex_empty_inventory
        @impl true
        def description, do: "Hex empty inventory"
        @impl true
        def version, do: "1.0.0"
        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """)

      compile_runtime_module("""
      defmodule #{inspect(event_handler)} do
        @spec handle_editor_event(term(), term()) :: :not_matched
        def handle_editor_event(_state, _event), do: :not_matched
      end
      """)

      compile_runtime_module("""
      defmodule #{inspect(event_root)} do
        use Minga.Extension
        editor_event_handler #{inspect(event_handler)}, [:editor_action]
        @impl true
        def name, do: :hex_event_inventory
        @impl true
        def description, do: "Hex event inventory"
        @impl true
        def version, do: "1.0.0"
        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """)

      load_test_application(empty_app, [empty_root])
      load_test_application(event_app, [event_root, event_handler])
      empty_md5 = empty_root.module_info(:md5)
      event_md5 = event_handler.module_info(:md5)

      :ok =
        ExtRegistry.register_hex(ctx.registry, :hex_empty_inventory, "hex-empty-inventory",
          app: empty_app
        )

      {:ok, empty_entry} = ExtRegistry.get(ctx.registry, :hex_empty_inventory)

      assert {:ok, _pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :hex_empty_inventory,
                 empty_entry,
                 authorities.opts
               )

      assert {:ok, [^empty_root]} =
               ArtifactAdmission.source_modules({:extension, :hex_empty_inventory},
                 server: authorities.admission
               )

      assert CallbackRegistry.callbacks(:editor_action, authorities.callback_registry) == []
      assert empty_root.module_info(:md5) == empty_md5

      :ok =
        ExtRegistry.register_hex(ctx.registry, :hex_event_inventory, "hex-event-inventory",
          app: event_app
        )

      {:ok, event_entry} = ExtRegistry.get(ctx.registry, :hex_event_inventory)

      assert {:ok, _pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :hex_event_inventory,
                 event_entry,
                 authorities.opts
               )

      assert {:ok, event_modules} =
               ArtifactAdmission.source_modules({:extension, :hex_event_inventory},
                 server: authorities.admission
               )

      assert event_modules == Enum.sort([event_root, event_handler])

      assert [{{:extension, :hex_event_inventory}, ^event_handler}] =
               CallbackRegistry.callbacks(:editor_action, authorities.callback_registry)

      assert {:ok, :not_matched} =
               CallbackInvoker.invoke(
                 {:extension, :hex_event_inventory},
                 event_handler,
                 :handle_editor_event,
                 [:state, :event],
                 :editor_event,
                 authorities.code_lease
               )

      assert event_handler.module_info(:md5) == event_md5
    end

    test "module sources admit declared and explicit helper MFAs and reject foreign ownership",
         ctx do
      authorities = start_runtime_authorities(ctx)
      app = unique_runtime_name(:module_inventory_app)
      first_root = unique_runtime_module("ModuleInventoryRoot")
      collision_root = unique_runtime_module("ModuleInventoryCollision")
      unowned_root = unique_runtime_module("ModuleInventoryUnowned")
      command_helper = unique_runtime_module("ModuleCommandHelper")
      picker_helper = unique_runtime_module("ModulePickerHelper")
      sidebar_helper = unique_runtime_module("ModuleSidebarHelper")
      event_helper = unique_runtime_module("ModuleEventHelper")

      compile_runtime_module("""
      defmodule #{inspect(command_helper)} do
        @spec run(term()) :: :command_helper
        def run(_state), do: :command_helper
      end
      """)

      compile_runtime_module("""
      defmodule #{inspect(picker_helper)} do
        @spec title() :: String.t()
        def title, do: "Runtime picker"
      end
      """)

      compile_runtime_module("""
      defmodule #{inspect(sidebar_helper)} do
        @spec handle(term(), String.t(), map()) :: :sidebar_helper
        def handle(_state, _action, _context), do: :sidebar_helper
      end
      """)

      compile_runtime_module("""
      defmodule #{inspect(event_helper)} do
        @spec handle_editor_event(term(), term()) :: :not_matched
        def handle_editor_event(_state, _event), do: :not_matched
      end
      """)

      compile_runtime_module(
        module_inventory_root_source(
          first_root,
          :module_inventory,
          command_helper,
          event_helper
        )
      )

      compile_runtime_module(
        module_inventory_root_source(
          collision_root,
          :module_inventory_collision,
          command_helper,
          event_helper
        )
      )

      compile_runtime_module(
        module_inventory_root_source(
          unowned_root,
          :module_inventory_unowned,
          command_helper,
          event_helper
        )
      )

      owned_modules = [
        first_root,
        collision_root,
        unowned_root,
        command_helper,
        picker_helper,
        sidebar_helper,
        event_helper
      ]

      load_test_application(app, owned_modules)

      :ok = ExtRegistry.register_module(ctx.registry, :module_inventory, first_root, [])
      {:ok, first_entry} = ExtRegistry.get(ctx.registry, :module_inventory)

      opts =
        Keyword.put(authorities.opts, :runtime_owned_modules, [picker_helper, sidebar_helper])

      assert {:ok, _pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :module_inventory,
                 first_entry,
                 opts
               )

      source = {:extension, :module_inventory}

      expected =
        Enum.sort([first_root, command_helper, picker_helper, sidebar_helper, event_helper])

      assert {:ok, ^expected} =
               ArtifactAdmission.source_modules(source, server: authorities.admission)

      assert {:ok, :command_helper} =
               CallbackInvoker.invoke(
                 source,
                 command_helper,
                 :run,
                 [:state],
                 :command,
                 authorities.code_lease
               )

      assert {:ok, "Runtime picker"} =
               CallbackInvoker.invoke(
                 source,
                 picker_helper,
                 :title,
                 [],
                 :picker_title,
                 authorities.code_lease
               )

      assert {:ok, :sidebar_helper} =
               CallbackInvoker.invoke(
                 source,
                 sidebar_helper,
                 :handle,
                 [:state, "toggle", %{}],
                 :sidebar_action,
                 authorities.code_lease
               )

      assert {:ok, :not_matched} =
               CallbackInvoker.invoke(
                 source,
                 event_helper,
                 :handle_editor_event,
                 [:state, :event],
                 :editor_event,
                 authorities.code_lease
               )

      :ok =
        ExtRegistry.register_module(
          ctx.registry,
          :module_inventory_collision,
          collision_root,
          []
        )

      {:ok, collision_entry} = ExtRegistry.get(ctx.registry, :module_inventory_collision)

      collision_result =
        ExtSupervisor.start_extension(
          ctx.supervisor,
          ctx.registry,
          :module_inventory_collision,
          collision_entry,
          opts
        )

      assert {:error,
              {:module_owned_by_source, ^command_helper, ^source,
               {:extension, :module_inventory_collision}}} = collision_result

      :ok =
        ExtRegistry.register_module(ctx.registry, :module_inventory_unowned, unowned_root, [])

      {:ok, unowned_entry} = ExtRegistry.get(ctx.registry, :module_inventory_unowned)
      unowned_opts = Keyword.put(authorities.opts, :runtime_owned_modules, [Minga.Buffer])

      assert {:error, {:module_conflicts_with_host, Minga.Buffer}} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :module_inventory_unowned,
                 unowned_entry,
                 unowned_opts
               )
    end

    test "passes config to init/1", ctx do
      {path, cleanup} =
        make_extension("ConfigExt", """
        defmodule Minga.TestExtensions.ConfigExt do
          use Minga.Extension

          @impl true
          def name, do: :config_ext

          @impl true
          def description, do: "Reads config"

          @impl true
          def version, do: "0.1.0"

          @impl true
          def init(config) do
            if Keyword.get(config, :greeting) == "hello" do
              {:ok, %{}}
            else
              {:error, :bad_config}
            end
          end
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.ConfigExt)
        :code.delete(Minga.TestExtensions.ConfigExt)
      end)

      :ok = ExtRegistry.register(ctx.registry, :config_ext, path, greeting: "hello")
      {:ok, entry} = ExtRegistry.get(ctx.registry, :config_ext)

      assert {:ok, _pid} =
               ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :config_ext, entry)

      {:ok, updated} = ExtRegistry.get(ctx.registry, :config_ext)
      assert updated.status == :running
    end
  end

  describe "stop_extension/4" do
    test "reports authority unavailable when a declared running projection has no root", ctx do
      :ok = ExtRegistry.register(ctx.registry, :lookup_failure, System.tmp_dir!(), [])

      :ok =
        ExtRegistry.update(ctx.registry, :lookup_failure,
          module: Minga.TestExtensions.LookupFailure,
          status: :running,
          pid: nil
        )

      {:ok, entry} = ExtRegistry.get(ctx.registry, :lookup_failure)

      assert {:error, {:authority_unavailable, :lookup_failure, _reason}} =
               ExtSupervisor.stop_extension(
                 :missing_extension_supervisor,
                 ctx.registry,
                 :lookup_failure,
                 entry
               )
    end

    test "stale stop request stops the current restarted replacement", ctx do
      {path, cleanup} =
        make_extension("StaleStop", """
        defmodule Minga.TestExtensions.StaleStop do
          use Minga.Extension

          @impl true
          def name, do: :stale_stop

          @impl true
          def description, do: "Stale stop test"

          @impl true
          def version, do: "0.1.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.StaleStop)
        :code.delete(Minga.TestExtensions.StaleStop)
      end)

      :ok = ExtRegistry.register(ctx.registry, :stale_stop, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :stale_stop)

      {:ok, old_pid} =
        ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :stale_stop, entry)

      {:ok, stale_entry} = ExtRegistry.get(ctx.registry, :stale_stop)

      Process.exit(old_pid, :kill)

      restarted_entry =
        wait_until(fn ->
          {:ok, current} = ExtRegistry.get(ctx.registry, :stale_stop)
          if is_pid(current.pid) and current.pid != old_pid, do: current, else: nil
        end)

      assert :ok =
               ExtSupervisor.stop_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :stale_stop,
                 stale_entry
               )

      {:ok, current_entry} = ExtRegistry.get(ctx.registry, :stale_stop)
      assert current_entry.status == :stopped
      assert current_entry.pid == nil
      refute Process.alive?(restarted_entry.pid)
    end

    test "stops a running extension while retaining its admitted module", ctx do
      {path, cleanup} =
        make_extension("StopMe", """
        defmodule Minga.TestExtensions.StopMe do
          use Minga.Extension

          @impl true
          def name, do: :stop_me

          @impl true
          def description, do: "Will be stopped"

          @impl true
          def version, do: "0.1.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.StopMe)
        :code.delete(Minga.TestExtensions.StopMe)
      end)

      :ok = ExtRegistry.register(ctx.registry, :stop_me, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :stop_me)
      {:ok, pid} = ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :stop_me, entry)
      assert Process.alive?(pid)

      {:ok, running_entry} = ExtRegistry.get(ctx.registry, :stop_me)
      :ok = ExtSupervisor.stop_extension(ctx.supervisor, ctx.registry, :stop_me, running_entry)

      refute Process.alive?(pid)

      {:ok, stopped} = ExtRegistry.get(ctx.registry, :stop_me)
      assert stopped.status == :stopped
      assert stopped.pid == nil
      assert stopped.module == Minga.TestExtensions.StopMe
      assert Code.ensure_loaded?(Minga.TestExtensions.StopMe)
    end

    test "same-VM restart uses the admitted artifact after source changes", ctx do
      module = Minga.TestExtensions.GenerationPinned

      {path, cleanup} =
        make_extension("GenerationPinned", """
        defmodule #{inspect(module)} do
          use Minga.Extension
          @impl true
          def name, do: :generation_pinned
          @impl true
          def description, do: "Pinned generation"
          @impl true
          def version, do: Atom.to_string(:v1)
          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(module)
        :code.delete(module)
      end)

      :ok = ExtRegistry.register(ctx.registry, :generation_pinned, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :generation_pinned)

      assert {:ok, _pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :generation_pinned,
                 entry
               )

      {:ok, running} = ExtRegistry.get(ctx.registry, :generation_pinned)

      assert :ok =
               ExtSupervisor.stop_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :generation_pinned,
                 running
               )

      source_file = Path.join(path, "extension.ex")
      source = File.read!(source_file) |> String.replace(":v1", ":v2")
      File.write!(source_file, source)
      Minga.Events.subscribe(:extension_restart_required)

      {:ok, stopped} = ExtRegistry.get(ctx.registry, :generation_pinned)

      assert {:ok, _pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :generation_pinned,
                 stopped
               )

      assert [{:generation_pinned, "v1", :running}] =
               ExtSupervisor.list_extensions(ctx.registry)

      assert_receive {:minga_event, :extension_restart_required,
                      %Minga.Events.ExtensionRestartRequiredEvent{
                        extension: :generation_pinned,
                        reason: :source_changed
                      }}
    end

    test "quiesces source work after admission closes and before runtime termination", ctx do
      authorities = start_runtime_authorities(ctx)
      name = :ordered_source_stop
      source = {:extension, name}
      :ok = ExtRegistry.register_module(ctx.registry, name, Minga.Extensions.MCP, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, name)

      assert {:ok, runtime} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 name,
                 entry,
                 authorities.opts
               )

      runtime_monitor = Process.monitor(runtime)

      test_pid = self()

      finalizer = fn finalized_source ->
        {:ok, projected} = ExtRegistry.get(ctx.registry, name)

        runtime_present? =
          RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == {:ok, runtime}

        send(test_pid, {:source_finalized, finalized_source, projected.status, runtime_present?})
        :ok
      end

      {:ok, running_entry} = ExtRegistry.get(ctx.registry, name)

      assert :ok =
               ExtSupervisor.stop_extension(
                 ctx.supervisor,
                 ctx.registry,
                 name,
                 running_entry,
                 Keyword.put(authorities.opts, :callbacks, %{editor_effects: finalizer})
               )

      assert_receive {:source_finalized, ^source, :stopped, true}
      refute_receive {:source_finalized, ^source, _, _}
      assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}
    end

    test "source finalizer failure keeps runtime alive and allows stop retry", ctx do
      authorities = start_runtime_authorities(ctx)
      name = :failed_source_quiesce
      source = {:extension, name}
      :ok = ExtRegistry.register_module(ctx.registry, name, Minga.Extensions.MCP, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, name)

      assert {:ok, runtime} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 name,
                 entry,
                 authorities.opts
               )

      runtime_monitor = Process.monitor(runtime)

      test_pid = self()
      attempts = start_supervised!({Agent, fn -> 0 end})

      finalizer = fn finalized_source ->
        attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})
        send(test_pid, {:source_finalizer_called, finalized_source, attempt})
        if attempt == 0, do: {:error, :scheduler_unavailable}, else: :ok
      end

      later_cleanup = fn cleaned_source ->
        send(test_pid, {:later_cleanup_called, cleaned_source})
        :ok
      end

      {:ok, running_entry} = ExtRegistry.get(ctx.registry, name)

      assert {:error,
              {:source_quiesce_failed,
               %{family: :editor_effects, source: ^source, reason: :scheduler_unavailable}}} =
               ExtSupervisor.stop_extension(
                 ctx.supervisor,
                 ctx.registry,
                 name,
                 running_entry,
                 Keyword.put(authorities.opts, :callbacks, %{
                   editor_effects: finalizer,
                   later_cleanup: later_cleanup
                 })
               )

      assert_receive {:source_finalizer_called, ^source, 0}
      refute_receive {:later_cleanup_called, ^source}
      refute_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}

      assert RuntimeSupervisor.local_child(runtime_supervisor(ctx, name)) == {:ok, runtime}

      {:ok, quiescing_entry} = ExtRegistry.get(ctx.registry, name)
      assert quiescing_entry.status == :load_error
      assert quiescing_entry.pid == runtime

      assert {:error, {:cleanup_retry_required, _reason}} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 name,
                 quiescing_entry,
                 authorities.opts
               )

      assert :ok =
               ExtSupervisor.stop_extension(
                 ctx.supervisor,
                 ctx.registry,
                 name,
                 quiescing_entry,
                 Keyword.put(authorities.opts, :callbacks, %{
                   editor_effects: finalizer,
                   later_cleanup: later_cleanup
                 })
               )

      assert_receive {:source_finalizer_called, ^source, 1}
      refute_receive {:source_finalizer_called, ^source, 2}
      assert_receive {:later_cleanup_called, ^source}
      assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}
    end

    test "stops a module-sourced extension without purging its module", ctx do
      authorities = start_runtime_authorities(ctx)
      :ok = ExtRegistry.register_module(ctx.registry, :minga_mcp, Minga.Extensions.MCP, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :minga_mcp)

      assert {:ok, pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :minga_mcp,
                 entry,
                 authorities.opts
               )

      assert Process.alive?(pid)
      assert :code.is_loaded(Minga.Extensions.MCP) != false

      {:ok, running_entry} = ExtRegistry.get(ctx.registry, :minga_mcp)

      :ok =
        ExtSupervisor.stop_extension(
          ctx.supervisor,
          ctx.registry,
          :minga_mcp,
          running_entry,
          authorities.opts
        )

      refute Process.alive?(pid)

      {:ok, stopped} = ExtRegistry.get(ctx.registry, :minga_mcp)
      assert stopped.status == :stopped
      assert stopped.pid == nil
      assert stopped.module == Minga.Extensions.MCP
      assert :code.is_loaded(Minga.Extensions.MCP) != false

      assert {:ok, restarted_pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :minga_mcp,
                 stopped,
                 authorities.opts
               )

      assert restarted_pid != pid
      refute restarted_pid == nil
    end
  end

  describe "start failure contracts" do
    test "option and modeline preparation failures publish exact load errors", ctx do
      {option_path, option_cleanup} =
        make_extension("OptionContractFailure", """
        defmodule Minga.TestExtensions.OptionContractFailure do
          use Minga.Extension

          option :positive_count, :pos_integer,
            default: 1,
            description: "Positive count"

          @impl true
          def name, do: :option_contract_failure
          @impl true
          def description, do: "Option contract failure"
          @impl true
          def version, do: "1.0.0"
          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      {modeline_path, modeline_cleanup} =
        make_extension("ModelineContractFailure", """
        defmodule Minga.TestExtensions.ModelineContractFailure do
          use Minga.Extension

          modeline_segment :mode do
            _ctx = ctx
            {" invalid ", :default, :default, [], nil}
          end

          @impl true
          def name, do: :modeline_contract_failure
          @impl true
          def description, do: "Modeline contract failure"
          @impl true
          def version, do: "1.0.0"
          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        option_cleanup.()
        modeline_cleanup.()
        :code.purge(Minga.TestExtensions.OptionContractFailure)
        :code.delete(Minga.TestExtensions.OptionContractFailure)
        :code.purge(Minga.TestExtensions.ModelineContractFailure)
        :code.delete(Minga.TestExtensions.ModelineContractFailure)
      end)

      :ok =
        ExtRegistry.register(ctx.registry, :option_contract_failure, option_path,
          positive_count: 0
        )

      {:ok, option_entry} = ExtRegistry.get(ctx.registry, :option_contract_failure)

      assert {:error, option_reason} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :option_contract_failure,
                 option_entry
               )

      assert is_binary(option_reason)
      assert option_reason =~ "positive_count"

      assert {:ok, %{status: :load_error, pid: nil, last_error: ^option_reason}} =
               ExtRegistry.get(ctx.registry, :option_contract_failure)

      :ok = ExtRegistry.register(ctx.registry, :modeline_contract_failure, modeline_path, [])
      {:ok, modeline_entry} = ExtRegistry.get(ctx.registry, :modeline_contract_failure)

      assert {:error,
              {:modeline_segment_rejected, :mode, {:reserved_name, :mode}} = modeline_reason} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :modeline_contract_failure,
                 modeline_entry
               )

      assert {:ok, %{status: :load_error, pid: nil, last_error: ^modeline_reason}} =
               ExtRegistry.get(ctx.registry, :modeline_contract_failure)
    end
  end

  describe "start_all/2 and stop_all/2" do
    test "starts and stops all registered extensions", ctx do
      {path_a, cleanup_a} =
        make_extension("ExtA", """
        defmodule Minga.TestExtensions.ExtA do
          use Minga.Extension

          @impl true
          def name, do: :ext_a

          @impl true
          def description, do: "Extension A"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      {path_b, cleanup_b} =
        make_extension("ExtB", """
        defmodule Minga.TestExtensions.ExtB do
          use Minga.Extension

          @impl true
          def name, do: :ext_b

          @impl true
          def description, do: "Extension B"

          @impl true
          def version, do: "2.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup_a.()
        cleanup_b.()

        for mod <- [Minga.TestExtensions.ExtA, Minga.TestExtensions.ExtB] do
          :code.purge(mod)
          :code.delete(mod)
        end
      end)

      :ok = ExtRegistry.register(ctx.registry, :ext_a, path_a, [])
      :ok = ExtRegistry.register(ctx.registry, :ext_b, path_b, [])

      :ok = ExtSupervisor.start_all(ctx.supervisor, ctx.registry)

      {:ok, a} = ExtRegistry.get(ctx.registry, :ext_a)
      {:ok, b} = ExtRegistry.get(ctx.registry, :ext_b)
      assert a.status == :running
      assert b.status == :running
      assert Process.alive?(a.pid)
      assert Process.alive?(b.pid)

      :ok = ExtSupervisor.stop_all(ctx.supervisor, ctx.registry)

      {:ok, a_stopped} = ExtRegistry.get(ctx.registry, :ext_a)
      {:ok, b_stopped} = ExtRegistry.get(ctx.registry, :ext_b)
      assert a_stopped.status == :stopped
      assert b_stopped.status == :stopped
    end

    test "start_all surfaces git clone failures with the clone reason and keeps starting later extensions",
         ctx do
      failing_git_dir =
        Path.join(
          System.tmp_dir!(),
          "minga_git_source_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(failing_git_dir)

      on_exit(fn ->
        File.rm_rf!(failing_git_dir)
        File.rm_rf!(Minga.Extension.Git.extension_path(:git_start_fail))
      end)

      {success_path, success_cleanup} =
        make_extension("GitStartSuccess", """
        defmodule Minga.TestExtensions.GitStartSuccess do
          use Minga.Extension

          @impl true
          def name, do: :git_start_ok

          @impl true
          def description, do: "Git start success"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        success_cleanup.()
        :code.purge(Minga.TestExtensions.GitStartSuccess)
        :code.delete(Minga.TestExtensions.GitStartSuccess)
      end)

      :ok = ExtRegistry.register_git(ctx.registry, :git_start_fail, failing_git_dir, [])
      :ok = ExtRegistry.register(ctx.registry, :git_start_ok, success_path, [])

      assert {:error, failures} = ExtSupervisor.start_all(ctx.supervisor, ctx.registry)

      assert %{extension: :git_start_fail, reason: clone_reason} =
               Enum.find(failures, &(&1.extension == :git_start_fail))

      assert is_binary(clone_reason) and clone_reason =~ "git clone failed"
      {:ok, failed_entry} = ExtRegistry.get(ctx.registry, :git_start_fail)
      assert failed_entry.status == :load_error
      assert failed_entry.last_error == clone_reason

      instance_registry = InstanceRegistry.registry_for_root(ctx.supervisor)
      assert InstanceRegistry.whereis(instance_registry, :root, :git_start_fail)
      assert InstanceRegistry.whereis(instance_registry, :instance, :git_start_fail)

      {:ok, success_entry} = ExtRegistry.get(ctx.registry, :git_start_ok)
      assert success_entry.status == :running
      assert Process.alive?(success_entry.pid)
    end

    test "start_all aggregates startup cleanup failures and keeps starting later extensions",
         ctx do
      cleanup_family = :test_cleanup_failure

      {failing_path, failing_cleanup} =
        make_extension("StartAllFailing", """
        defmodule Minga.TestExtensions.StartAllFailing do
          use Minga.Extension

          @impl true
          def name, do: :start_all_fail

          @impl true
          def description, do: "Fails during startup cleanup"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:error, :intentional_failure}
        end
        """)

      {success_path, success_cleanup} =
        make_extension("StartAllSuccess", """
        defmodule Minga.TestExtensions.StartAllSuccess do
          use Minga.Extension

          @impl true
          def name, do: :start_all_ok

          @impl true
          def description, do: "Starts successfully"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        failing_cleanup.()
        success_cleanup.()
        :code.purge(Minga.TestExtensions.StartAllFailing)
        :code.delete(Minga.TestExtensions.StartAllFailing)
        :code.purge(Minga.TestExtensions.StartAllSuccess)
        :code.delete(Minga.TestExtensions.StartAllSuccess)
      end)

      :ok = ExtRegistry.register(ctx.registry, :start_all_fail, failing_path, [])
      :ok = ExtRegistry.register(ctx.registry, :start_all_ok, success_path, [])

      test_callbacks = %{cleanup_family => fn _source -> raise "cleanup failure" end}

      assert {:error, failures} =
               ExtSupervisor.start_all(ctx.supervisor, ctx.registry, callbacks: test_callbacks)

      assert Enum.any?(failures, fn
               %{extension: :start_all_fail, reason: {:cleanup_failed, reason, cleanup_failures}} ->
                 assert reason =~ "intentional_failure"

                 Enum.any?(cleanup_failures, fn
                   %{family: ^cleanup_family, source: {:extension, :start_all_fail}} -> true
                   _ -> false
                 end)

               _ ->
                 false
             end)

      {:ok, failed_entry} = ExtRegistry.get(ctx.registry, :start_all_fail)
      assert failed_entry.status == :load_error
      assert failed_entry.pid == nil

      {:ok, success_entry} = ExtRegistry.get(ctx.registry, :start_all_ok)
      assert success_entry.status == :running
      assert Process.alive?(success_entry.pid)
    end
  end

  describe "list_extensions/1" do
    test "returns name, version, and status for each extension", ctx do
      {path, cleanup} =
        make_extension("Listed", """
        defmodule Minga.TestExtensions.Listed do
          use Minga.Extension

          @impl true
          def name, do: :listed

          @impl true
          def description, do: "Listable"

          @impl true
          def version, do: "3.2.1"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.Listed)
        :code.delete(Minga.TestExtensions.Listed)
      end)

      :ok = ExtRegistry.register(ctx.registry, :listed, path, [])
      :ok = ExtSupervisor.start_all(ctx.supervisor, ctx.registry)

      extensions = ExtSupervisor.list_extensions(ctx.registry)
      assert [{:listed, "3.2.1", :running}] = extensions
    end
  end

  describe "crash isolation" do
    test "temporary extension normal exit is finalized as stopped", ctx do
      {path, cleanup} =
        make_extension("TemporaryNormalExit", """
        defmodule Minga.TestExtensions.TemporaryNormalExit do
          use Minga.Extension

          @impl true
          def name, do: :temporary_normal_exit

          @impl true
          def description, do: "Temporary normal exit"

          @impl true
          def version, do: "0.1.0"

          @impl true
          def init(config) do
            command_registry = Keyword.fetch!(config, :command_registry)
            source = {:extension, :temporary_normal_exit}
            command = %Minga.Command{name: :temporary_normal_exit_cmd, description: "Temporary normal exit", execute: &__MODULE__.noop/1}
            :ok = Minga.Command.Registry.register_command(command_registry, source, command)
            {:ok, %{}}
          end

          @spec noop(map()) :: map()
          def noop(state), do: state

          @impl true
          def child_spec(config) do
            %{
              id: __MODULE__,
              start: {Agent, :start_link, [fn -> config end]},
              restart: :temporary,
              type: :worker
            }
          end
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.TemporaryNormalExit)
        :code.delete(Minga.TestExtensions.TemporaryNormalExit)
      end)

      config = [command_registry: ctx.command_registry]
      :ok = ExtRegistry.register(ctx.registry, :temporary_normal_exit, path, config)
      {:ok, entry} = ExtRegistry.get(ctx.registry, :temporary_normal_exit)

      {:ok, pid} =
        ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :temporary_normal_exit, entry,
          command_registry: ctx.command_registry
        )

      assert {:ok, _command} =
               CommandRegistry.lookup(ctx.command_registry, :temporary_normal_exit_cmd)

      Agent.stop(pid, :normal)

      stopped_entry =
        wait_until(fn ->
          {:ok, current} = ExtRegistry.get(ctx.registry, :temporary_normal_exit)
          if current.status == :stopped and current.pid == nil, do: current, else: nil
        end)

      assert stopped_entry.module == Minga.TestExtensions.TemporaryNormalExit
      assert Code.ensure_loaded?(Minga.TestExtensions.TemporaryNormalExit)
      assert :error = CommandRegistry.lookup(ctx.command_registry, :temporary_normal_exit_cmd)
    end

    test "a crashing extension does not take down the supervisor", ctx do
      {path, cleanup} =
        make_extension("Crasher", """
        defmodule Minga.TestExtensions.Crasher do
          use Minga.Extension

          @impl true
          def name, do: :crasher

          @impl true
          def description, do: "Will crash"

          @impl true
          def version, do: "0.0.1"

          @impl true
          def init(_config), do: {:ok, %{}}

          @impl true
          def child_spec(_config) do
            %{
              id: __MODULE__,
              start: {Agent, :start_link, [fn -> :ok end]},
              restart: :temporary,
              type: :worker
            }
          end
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.Crasher)
        :code.delete(Minga.TestExtensions.Crasher)
      end)

      :ok = ExtRegistry.register(ctx.registry, :crasher, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :crasher)
      {:ok, pid} = ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :crasher, entry)

      # Kill the extension process and wait for the supervisor to handle it
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      # Supervisor is still alive
      assert Process.alive?(Process.whereis(ctx.supervisor))
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec runtime_supervisor(map(), atom()) :: GenServer.server()
  defp runtime_supervisor(ctx, name) do
    registry = InstanceRegistry.registry_for_root(ctx.supervisor)
    InstanceRegistry.via(registry, :runtime, name)
  end

  @spec wait_until((-> term()), non_neg_integer()) :: term()
  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        receive do
        after
          10 -> wait_until(fun, attempts - 1)
        end

      result ->
        result
    end
  end

  defp wait_until(fun, 0), do: flunk("condition was not met, last result: #{inspect(fun.())}")

  @spec start_runtime_authorities(map()) :: map()
  defp start_runtime_authorities(ctx) do
    owner_name = unique_runtime_name(:runtime_inventory_owner)
    persistence_key = {__MODULE__, :runtime_inventory, make_ref()}

    start_supervised!(
      {ArtifactGenerationState, name: owner_name, persistence_key: persistence_key},
      id: unique_runtime_name(:runtime_inventory_owner_child)
    )

    on_exit(fn ->
      assert :ok = ArtifactGenerationState.reset_for_test(persistence_key)
    end)

    admission =
      start_supervised!(
        {ArtifactAdmission, name: nil, state_owner: owner_name},
        id: unique_runtime_name(:runtime_inventory_admission)
      )

    code_lease =
      start_supervised!(
        {CodeLease, name: nil},
        id: unique_runtime_name(:runtime_inventory_code_lease)
      )

    callback_registry = unique_runtime_name(:runtime_inventory_callback_registry)
    start_supervised!({CallbackRegistry, name: callback_registry})
    keymap = unique_runtime_name(:runtime_inventory_keymap)
    start_supervised!({KeymapActive, name: keymap})

    opts = [
      command_registry: ctx.command_registry,
      keymap: keymap,
      artifact_admission: admission,
      code_lease: code_lease,
      callback_registry: callback_registry
    ]

    %{
      admission: admission,
      code_lease: code_lease,
      callback_registry: callback_registry,
      opts: opts
    }
  end

  @spec module_inventory_root_source(module(), atom(), module(), module()) :: String.t()
  defp module_inventory_root_source(root, name, command_helper, event_helper) do
    """
    defmodule #{inspect(root)} do
      use Minga.Extension
      command :#{name}_command, "Runtime inventory command",
        execute: {#{inspect(command_helper)}, :run}
      editor_event_handler #{inspect(event_helper)}, [:editor_action]
      @impl true
      def name, do: #{inspect(name)}
      @impl true
      def description, do: "Runtime module inventory"
      @impl true
      def version, do: "1.0.0"
      @impl true
      def init(_config), do: {:ok, %{}}
    end
    """
  end

  @spec compile_runtime_module(String.t()) :: module()
  defp compile_runtime_module(source) do
    [{module, _beam}] = Code.compile_string(source, "runtime_inventory_test.ex")
    module
  end

  @spec load_test_application(atom(), [module()]) :: :ok
  defp load_test_application(application, modules) do
    spec =
      {:application, application,
       [
         description: ~c"Runtime inventory test application",
         vsn: ~c"1.0.0",
         modules: modules,
         registered: [],
         applications: [:kernel, :stdlib]
       ]}

    assert :ok = :application.load(spec)
    assert {:ok, _started} = Application.ensure_all_started(application)

    on_exit(fn ->
      _result = Application.stop(application)
      assert :ok = Application.unload(application)

      Enum.each(modules, fn module ->
        :code.purge(module)
        :code.delete(module)
      end)
    end)

    :ok
  end

  @spec unique_runtime_name(atom()) :: atom()
  defp unique_runtime_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")

  @spec unique_runtime_module(String.t()) :: module()
  defp unique_runtime_module(suffix),
    do: Module.concat(["RuntimeInventory#{suffix}#{System.unique_integer([:positive])}"])

  @spec make_extension(String.t(), String.t()) :: {String.t(), (-> :ok)}
  defp make_extension(dir_name, source) do
    dir =
      Path.join(System.tmp_dir!(), "minga_ext_#{dir_name}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "extension.ex"), source)

    cleanup = fn -> File.rm_rf!(dir) end
    {dir, cleanup}
  end
end
