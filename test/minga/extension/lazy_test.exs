defmodule Minga.Extension.LazyTest do
  # Runtime code compilation and fixed test module names are global.
  use ExUnit.Case, async: false

  # Runtime code compilation makes these inherently slow.
  @moduletag :heavy

  import ExUnit.CaptureLog

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Extension.DeferredBatchCompleteEvent
  alias Minga.Extension.InstanceRegistry
  alias Minga.Extension.Lazy
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap.Active, as: KeymapActive

  setup do
    reg_name = :"ext_reg_#{System.unique_integer([:positive])}"
    sup_name = :"ext_sup_#{System.unique_integer([:positive])}"
    cmd_reg_name = :"cmd_reg_#{System.unique_integer([:positive])}"
    keymap_name = :"keymap_#{System.unique_integer([:positive])}"

    {:ok, _} = ExtRegistry.start_link(name: reg_name)
    {:ok, _} = ExtSupervisor.start_link(name: sup_name)
    {:ok, _} = CommandRegistry.start_link(name: cmd_reg_name)
    {:ok, _} = KeymapActive.start_link(name: keymap_name)

    {:ok,
     registry: reg_name, supervisor: sup_name, command_registry: cmd_reg_name, keymap: keymap_name}
  end

  defp start_opts(ctx) do
    [command_registry: ctx.command_registry, keymap: ctx.keymap]
  end

  describe "register_stubs/5" do
    test "registers stub commands without calling init", ctx do
      {path, cleanup} =
        make_extension("LazyCmd", """
        defmodule Minga.TestExtensions.LazyCmd do
          use Minga.Extension

          load_policy {:on_command, [:lazy_test_cmd]}

          command :lazy_test_cmd, "A lazy command",
            execute: {Minga.TestExtensions.LazyCmd, :run}

          @impl true
          def name, do: :lazy_cmd

          @impl true
          def description, do: "Lazy command test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config) do
            # This should NOT be called during stub registration
            raise "init should not be called for lazy extensions"
          end

          def run(state), do: state
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.LazyCmd)
        :code.delete(Minga.TestExtensions.LazyCmd)
      end)

      :ok =
        ExtRegistry.register(ctx.registry, :lazy_cmd, path,
          load_policy: {:on_command, [:lazy_test_cmd]}
        )

      {:ok, entry} = ExtRegistry.get(ctx.registry, :lazy_cmd)

      assert :ok =
               Lazy.register_stubs(
                 ctx.supervisor,
                 ctx.registry,
                 :lazy_cmd,
                 entry,
                 start_opts(ctx)
               )

      # Extension should be in :stub status, NOT :running
      {:ok, updated} = ExtRegistry.get(ctx.registry, :lazy_cmd)
      assert updated.status == :stub
      assert updated.module == Minga.TestExtensions.LazyCmd
      assert updated.pid == nil

      # Command should be registered (as a stub)
      assert {:ok, cmd} = CommandRegistry.lookup(ctx.command_registry, :lazy_test_cmd)
      assert cmd.name == :lazy_test_cmd
      assert cmd.description == "A lazy command"

      # Manifest should be recorded
      assert updated.manifest != nil
      assert updated.manifest.name == :lazy_cmd
      assert updated.manifest.load_policy == {:on_command, [:lazy_test_cmd]}
    end

    test "registers stub keybindings without calling init", ctx do
      {path, cleanup} =
        make_extension("LazyKeys", """
        defmodule Minga.TestExtensions.LazyKeys do
          use Minga.Extension

          load_policy {:on_command, [:lazy_key_cmd]}

          command :lazy_key_cmd, "Lazy keybind test",
            execute: {Minga.TestExtensions.LazyKeys, :run}

          keybind :normal, "SPC t z", :lazy_key_cmd, "Test lazy keybind"

          @impl true
          def name, do: :lazy_keys

          @impl true
          def description, do: "Lazy keybind test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: raise("init should not be called")

          def run(state), do: state
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.LazyKeys)
        :code.delete(Minga.TestExtensions.LazyKeys)
      end)

      :ok =
        ExtRegistry.register(ctx.registry, :lazy_keys, path,
          load_policy: {:on_command, [:lazy_key_cmd]}
        )

      {:ok, entry} = ExtRegistry.get(ctx.registry, :lazy_keys)

      assert :ok =
               Lazy.register_stubs(
                 ctx.supervisor,
                 ctx.registry,
                 :lazy_keys,
                 entry,
                 start_opts(ctx)
               )

      # Keybinding should be registered in the leader trie
      leader_trie = KeymapActive.leader_trie(ctx.keymap)
      {:ok, keys} = Minga.Keymap.KeyParser.parse("t z")

      assert {:command, :lazy_key_cmd, _desc} =
               Minga.Keymap.Bindings.lookup_sequence(leader_trie, keys)
    end

    test "registered stub racing stop and redeclaration cannot activate its stale declaration",
         ctx do
      {path, cleanup} =
        make_extension("LazyRedeclareRace", """
        defmodule Minga.TestExtensions.LazyRedeclareRace do
          use Minga.Extension

          load_policy {:on_command, [:lazy_redeclare_race_cmd]}

          command :lazy_redeclare_race_cmd, "Lazy redeclaration race",
            execute: {Minga.TestExtensions.LazyRedeclareRace, :run}

          @impl true
          def name, do: :lazy_redeclare_race
          @impl true
          def description, do: "Lazy redeclaration race"
          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(config) do
            send(Keyword.fetch!(config, :test_pid), {:lazy_redeclare_init, config[:generation]})
            {:ok, %{}}
          end

          def run(state), do: Map.put(state, :lazy_generation, :new)
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.LazyRedeclareRace)
        :code.delete(Minga.TestExtensions.LazyRedeclareRace)
      end)

      old_config = [
        load_policy: {:on_command, [:lazy_redeclare_race_cmd]},
        test_pid: self(),
        generation: :old
      ]

      :ok = ExtRegistry.register(ctx.registry, :lazy_redeclare_race, path, old_config)
      {:ok, old_declaration} = ExtRegistry.get(ctx.registry, :lazy_redeclare_race)

      assert :ok =
               Lazy.register_stubs(
                 ctx.supervisor,
                 ctx.registry,
                 :lazy_redeclare_race,
                 old_declaration,
                 start_opts(ctx)
               )

      assert {:ok, stale_stub} =
               CommandRegistry.lookup(ctx.command_registry, :lazy_redeclare_race_cmd)

      parent = self()

      finalizer = fn _source ->
        send(parent, {:lazy_stop_blocked, self()})
        receive do: (:release -> :ok)
      end

      stop_opts = Keyword.put(start_opts(ctx), :callbacks, %{editor_effects: finalizer})

      stop_task =
        Task.async(fn ->
          ExtSupervisor.stop_extension(
            ctx.supervisor,
            ctx.registry,
            :lazy_redeclare_race,
            old_declaration,
            stop_opts
          )
        end)

      assert_receive {:lazy_stop_blocked, finalizer_worker}

      new_config =
        Keyword.merge(old_config, generation: :new)

      :ok = ExtRegistry.register(ctx.registry, :lazy_redeclare_race, path, new_config)
      {:ok, new_declaration} = ExtRegistry.get(ctx.registry, :lazy_redeclare_race)

      log =
        capture_log(fn ->
          stale_trigger = Task.async(fn -> stale_stub.execute.(%{untouched: true}) end)
          refute Task.yield(stale_trigger, 25)
          send(finalizer_worker, :release)
          assert :ok = Task.await(stop_task)
          assert %{untouched: true} = Task.await(stale_trigger)
        end)

      assert log =~ "Extension lazy_redeclare_race lazy activation failed"
      assert log =~ "stale_deferred_declaration"
      refute_receive {:lazy_redeclare_init, :old}

      assert :ok =
               Lazy.register_stubs(
                 ctx.supervisor,
                 ctx.registry,
                 :lazy_redeclare_race,
                 new_declaration,
                 start_opts(ctx)
               )

      assert {:ok, current_stub} =
               CommandRegistry.lookup(ctx.command_registry, :lazy_redeclare_race_cmd)

      assert {:extension_callback, {:extension, :lazy_redeclare_race},
              Minga.TestExtensions.LazyRedeclareRace, :run, {:ok, %{lazy_generation: :new}}} =
               current_stub.execute.(%{})

      assert_receive {:lazy_redeclare_init, :new}
      refute_receive {:lazy_redeclare_init, _duplicate}
    end

    test "extension with runtime error in body still registers stubs (AC4)", ctx do
      {path, cleanup} =
        make_extension("BrokenBody", """
        defmodule Minga.TestExtensions.BrokenBody do
          use Minga.Extension

          load_policy {:on_command, [:broken_body_cmd]}

          command :broken_body_cmd, "Broken body command",
            execute: {Minga.TestExtensions.BrokenBody, :run}

          @impl true
          def name, do: :broken_body

          @impl true
          def description, do: "Has a runtime error"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: raise("deliberate error in body")

          def run(_state), do: raise("deliberate runtime error")
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.BrokenBody)
        :code.delete(Minga.TestExtensions.BrokenBody)
      end)

      :ok =
        ExtRegistry.register(ctx.registry, :broken_body, path,
          load_policy: {:on_command, [:broken_body_cmd]}
        )

      {:ok, entry} = ExtRegistry.get(ctx.registry, :broken_body)

      # Should succeed: the deliberate error is in init/run, not compilation
      assert :ok =
               Lazy.register_stubs(
                 ctx.supervisor,
                 ctx.registry,
                 :broken_body,
                 entry,
                 start_opts(ctx)
               )

      # Command should be registered despite the broken body
      assert {:ok, cmd} = CommandRegistry.lookup(ctx.command_registry, :broken_body_cmd)
      assert cmd.name == :broken_body_cmd

      {:ok, updated} = ExtRegistry.get(ctx.registry, :broken_body)
      assert updated.status == :stub
    end
  end

  describe "autoload/4" do
    test "fully loads a stubbed extension on first trigger", ctx do
      {path, cleanup} =
        make_extension("AutoloadExt", """
        defmodule Minga.TestExtensions.AutoloadExt do
          use Minga.Extension

          load_policy {:on_command, [:autoload_cmd]}

          command :autoload_cmd, "Autoload test",
            execute: {Minga.TestExtensions.AutoloadExt, :run}

          @impl true
          def name, do: :autoload_ext

          @impl true
          def description, do: "Autoload test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{loaded: true}}

          def run(state), do: Map.put(state, :autoload_ran, true)
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.AutoloadExt)
        :code.delete(Minga.TestExtensions.AutoloadExt)
      end)

      :ok =
        ExtRegistry.register(ctx.registry, :autoload_ext, path,
          load_policy: {:on_command, [:autoload_cmd]}
        )

      {:ok, entry} = ExtRegistry.get(ctx.registry, :autoload_ext)

      # Register stubs
      assert :ok =
               Lazy.register_stubs(
                 ctx.supervisor,
                 ctx.registry,
                 :autoload_ext,
                 entry,
                 start_opts(ctx)
               )

      {:ok, pre_load} = ExtRegistry.get(ctx.registry, :autoload_ext)
      assert pre_load.status == :stub

      # Trigger autoload
      assert {:ok, pid} =
               Lazy.autoload(
                 ctx.supervisor,
                 ctx.registry,
                 :autoload_ext,
                 start_opts(ctx)
               )

      assert Process.alive?(pid)

      # Extension should now be :running
      {:ok, post_load} = ExtRegistry.get(ctx.registry, :autoload_ext)
      assert post_load.status == :running
      assert post_load.pid == pid

      # Real command should be registered (replacing the stub)
      assert {:ok, cmd} = CommandRegistry.lookup(ctx.command_registry, :autoload_cmd)

      assert {:extension_callback, {:extension, :autoload_ext}, Minga.TestExtensions.AutoloadExt,
              :run, {:ok, %{autoload_ran: true}}} =
               cmd.execute.(%{})
    end

    test "autoload ignores changed disk source and uses the admitted VM generation", ctx do
      module = Minga.TestExtensions.LazyGenerationPinned

      {path, cleanup} =
        make_extension("LazyGenerationPinned", """
        defmodule #{inspect(module)} do
          use Minga.Extension
          load_policy {:on_command, [:lazy_generation_cmd]}
          command :lazy_generation_cmd, "Generation", execute: {#{inspect(module)}, :run}
          @impl true
          def name, do: :lazy_generation_pinned
          @impl true
          def description, do: "Lazy generation"
          @impl true
          def version, do: "1"
          @impl true
          def init(_config), do: {:ok, %{}}
          def run(state), do: Map.put(state, :generation, :v1)
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(module)
        :code.delete(module)
      end)

      :ok =
        ExtRegistry.register(ctx.registry, :lazy_generation_pinned, path,
          load_policy: {:on_command, [:lazy_generation_cmd]}
        )

      {:ok, entry} = ExtRegistry.get(ctx.registry, :lazy_generation_pinned)

      assert :ok =
               Lazy.register_stubs(
                 ctx.supervisor,
                 ctx.registry,
                 :lazy_generation_pinned,
                 entry,
                 start_opts(ctx)
               )

      source_file = Path.join(path, "extension.ex")
      File.write!(source_file, File.read!(source_file) |> String.replace(":v1", ":v2"))
      Minga.Events.subscribe(:extension_restart_required)

      assert {:ok, _pid} =
               Lazy.autoload(
                 ctx.supervisor,
                 ctx.registry,
                 :lazy_generation_pinned,
                 start_opts(ctx)
               )

      assert {:ok, command} = CommandRegistry.lookup(ctx.command_registry, :lazy_generation_cmd)

      assert {:extension_callback, {:extension, :lazy_generation_pinned}, ^module, :run,
              {:ok, %{generation: :v1}}} = command.execute.(%{})

      assert_receive {:minga_event, :extension_restart_required,
                      %Minga.Events.ExtensionRestartRequiredEvent{
                        extension: :lazy_generation_pinned,
                        reason: :source_changed
                      }}
    end

    test "authority exit races return typed errors without crashing the caller", ctx do
      {path, cleanup} =
        make_extension("AutoloadAuthorityExit", """
        defmodule Minga.TestExtensions.AutoloadAuthorityExit do
          use Minga.Extension

          load_policy {:on_command, [:autoload_authority_exit_cmd]}

          command :autoload_authority_exit_cmd, "Authority exit",
            execute: {Minga.TestExtensions.AutoloadAuthorityExit, :run}

          @impl true
          def name, do: :autoload_authority_exit
          @impl true
          def description, do: "Autoload authority exit"
          @impl true
          def version, do: "1.0.0"
          @impl true
          def init(_config), do: {:ok, %{}}
          def run(state), do: Map.put(state, :should_not_run, true)
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.AutoloadAuthorityExit)
        :code.delete(Minga.TestExtensions.AutoloadAuthorityExit)
      end)

      :ok =
        ExtRegistry.register(ctx.registry, :autoload_authority_exit, path,
          load_policy: {:on_command, [:autoload_authority_exit_cmd]}
        )

      {:ok, entry} = ExtRegistry.get(ctx.registry, :autoload_authority_exit)

      assert :ok =
               Lazy.register_stubs(
                 ctx.supervisor,
                 ctx.registry,
                 :autoload_authority_exit,
                 entry,
                 start_opts(ctx)
               )

      registry = InstanceRegistry.registry_for_root(ctx.supervisor)
      authority = InstanceRegistry.whereis(registry, :instance, :autoload_authority_exit)
      :ok = :sys.suspend(authority)
      parent = self()

      task =
        Task.async(fn ->
          capture_log(fn ->
            result =
              Lazy.autoload(
                ctx.supervisor,
                ctx.registry,
                :autoload_authority_exit,
                start_opts(ctx)
              )

            send(parent, {:autoload_exit_result, result})
          end)
        end)

      refute Task.yield(task, 25)
      Process.exit(authority, :kill)
      log = Task.await(task)

      assert_receive {:autoload_exit_result,
                      {:error, {:authority_call_exit, :autoload_authority_exit, _reason}}}

      assert log =~ "Extension autoload_authority_exit lazy activation failed"
      assert log =~ "authority_call_exit"
    end

    test "stub command contains authority exit and leaves Editor state unchanged", ctx do
      {path, cleanup} =
        make_extension("LazyCommandAuthorityExit", """
        defmodule Minga.TestExtensions.LazyCommandAuthorityExit do
          use Minga.Extension

          load_policy {:on_command, [:lazy_command_authority_exit_cmd]}

          command :lazy_command_authority_exit_cmd, "Command authority exit",
            execute: {Minga.TestExtensions.LazyCommandAuthorityExit, :run}

          @impl true
          def name, do: :lazy_command_authority_exit
          @impl true
          def description, do: "Lazy command authority exit"
          @impl true
          def version, do: "1.0.0"
          @impl true
          def init(_config), do: {:ok, %{}}
          def run(state), do: Map.put(state, :should_not_run, true)
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.LazyCommandAuthorityExit)
        :code.delete(Minga.TestExtensions.LazyCommandAuthorityExit)
      end)

      :ok =
        ExtRegistry.register(ctx.registry, :lazy_command_authority_exit, path,
          load_policy: {:on_command, [:lazy_command_authority_exit_cmd]}
        )

      {:ok, entry} = ExtRegistry.get(ctx.registry, :lazy_command_authority_exit)

      assert :ok =
               Lazy.register_stubs(
                 ctx.supervisor,
                 ctx.registry,
                 :lazy_command_authority_exit,
                 entry,
                 start_opts(ctx)
               )

      assert {:ok, command} =
               CommandRegistry.lookup(ctx.command_registry, :lazy_command_authority_exit_cmd)

      registry = InstanceRegistry.registry_for_root(ctx.supervisor)
      authority = InstanceRegistry.whereis(registry, :instance, :lazy_command_authority_exit)
      :ok = :sys.suspend(authority)
      parent = self()

      task =
        Task.async(fn ->
          capture_log(fn ->
            result = command.execute.(%{unchanged: true})
            send(parent, {:lazy_command_exit_result, result})
          end)
        end)

      refute Task.yield(task, 25)
      Process.exit(authority, :kill)
      log = Task.await(task)

      assert_receive {:lazy_command_exit_result, %{unchanged: true}}
      assert log =~ "Extension lazy_command_authority_exit lazy activation failed"
      assert log =~ "authority_call_exit"
    end

    test "autoload is idempotent (returns running pid on second call)", ctx do
      {path, cleanup} =
        make_extension("AutoloadIdempotent", """
        defmodule Minga.TestExtensions.AutoloadIdempotent do
          use Minga.Extension

          load_policy {:on_command, [:autoload_idem_cmd]}

          command :autoload_idem_cmd, "Idempotent autoload",
            execute: {Minga.TestExtensions.AutoloadIdempotent, :run}

          @impl true
          def name, do: :autoload_idempotent

          @impl true
          def description, do: "Idempotent autoload test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}

          def run(state), do: state
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.AutoloadIdempotent)
        :code.delete(Minga.TestExtensions.AutoloadIdempotent)
      end)

      :ok =
        ExtRegistry.register(ctx.registry, :autoload_idempotent, path,
          load_policy: {:on_command, [:autoload_idem_cmd]}
        )

      {:ok, entry} = ExtRegistry.get(ctx.registry, :autoload_idempotent)

      :ok =
        Lazy.register_stubs(
          ctx.supervisor,
          ctx.registry,
          :autoload_idempotent,
          entry,
          start_opts(ctx)
        )

      # First autoload
      assert {:ok, pid1} =
               Lazy.autoload(ctx.supervisor, ctx.registry, :autoload_idempotent, start_opts(ctx))

      # Second autoload should return the same pid
      assert {:ok, ^pid1} =
               Lazy.autoload(ctx.supervisor, ctx.registry, :autoload_idempotent, start_opts(ctx))
    end
  end

  describe "compatibility deferred scheduler" do
    test "logs and aggregates lazy stub registration failures", ctx do
      {path, cleanup} =
        make_extension("DeferredRegistrationFailure", """
        defmodule Minga.TestExtensions.DeferredRegistrationFailure do
          use Minga.Extension

          load_policy :deferred

          @impl true
          def name, do: :deferred_registration_failure
          @impl true
          def description, do: "Deferred registration failure"
          @impl true
          def version, do: "1.0.0"
          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.DeferredRegistrationFailure)
        :code.delete(Minga.TestExtensions.DeferredRegistrationFailure)
      end)

      :ok =
        ExtRegistry.register(ctx.registry, :deferred_registration_failure, path,
          load_policy: :deferred
        )

      {:ok, entry} = ExtRegistry.get(ctx.registry, :deferred_registration_failure)
      Minga.Events.subscribe(:extension_deferred_batch_complete)

      log =
        capture_log(fn ->
          assert :ok =
                   Lazy.schedule_deferred_loads(
                     :missing_deferred_root,
                     ctx.registry,
                     [{:deferred_registration_failure, entry}],
                     start_opts(ctx)
                   )
        end)

      assert log =~ "Extension deferred_registration_failure deferred stub registration failed"

      assert_receive {:minga_event, :extension_deferred_batch_complete,
                      %DeferredBatchCompleteEvent{
                        count: 1,
                        failures: [
                          %{extension: :deferred_registration_failure, reason: _reason}
                        ]
                      }},
                     5_000
    end
  end

  describe "start_all/3 with lazy extensions" do
    test "eager extensions start immediately, lazy register stubs", ctx do
      {eager_path, eager_cleanup} =
        make_extension("EagerStartAll", """
        defmodule Minga.TestExtensions.EagerStartAll do
          use Minga.Extension

          command :eager_start_all_cmd, "Eager start all",
            execute: {Minga.TestExtensions.EagerStartAll, :run}

          @impl true
          def name, do: :eager_start_all

          @impl true
          def description, do: "Eager extension in start_all"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}

          def run(state), do: state
        end
        """)

      {lazy_path, lazy_cleanup} =
        make_extension("LazyStartAll", """
        defmodule Minga.TestExtensions.LazyStartAll do
          use Minga.Extension

          load_policy {:on_command, [:lazy_start_all_cmd]}

          command :lazy_start_all_cmd, "Lazy start all",
            execute: {Minga.TestExtensions.LazyStartAll, :run}

          @impl true
          def name, do: :lazy_start_all

          @impl true
          def description, do: "Lazy extension in start_all"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}

          def run(state), do: state
        end
        """)

      on_exit(fn ->
        eager_cleanup.()
        lazy_cleanup.()
        :code.purge(Minga.TestExtensions.EagerStartAll)
        :code.delete(Minga.TestExtensions.EagerStartAll)
        :code.purge(Minga.TestExtensions.LazyStartAll)
        :code.delete(Minga.TestExtensions.LazyStartAll)
      end)

      :ok = ExtRegistry.register(ctx.registry, :eager_start_all, eager_path, [])

      :ok =
        ExtRegistry.register(ctx.registry, :lazy_start_all, lazy_path,
          load_policy: {:on_command, [:lazy_start_all_cmd]}
        )

      assert :ok = ExtSupervisor.start_all(ctx.supervisor, ctx.registry, start_opts(ctx))

      # Eager extension should be running
      {:ok, eager_entry} = ExtRegistry.get(ctx.registry, :eager_start_all)
      assert eager_entry.status == :running
      assert is_pid(eager_entry.pid)

      # Lazy extension should be stubbed, not running
      {:ok, lazy_entry} = ExtRegistry.get(ctx.registry, :lazy_start_all)
      assert lazy_entry.status == :stub
      assert lazy_entry.pid == nil

      # Both commands should be registered
      assert {:ok, _} = CommandRegistry.lookup(ctx.command_registry, :eager_start_all_cmd)
      assert {:ok, _} = CommandRegistry.lookup(ctx.command_registry, :lazy_start_all_cmd)
    end
  end

  describe "effective_load_policy/1" do
    test "returns explicit non-eager policy from entry" do
      entry = %Minga.Extension.Entry{
        source_type: :path,
        load_policy: {:on_command, [:some_cmd]}
      }

      assert {:on_command, [:some_cmd]} = Lazy.effective_load_policy(entry)
    end

    test "returns :eager for entry with no config override (nil)" do
      entry = %Minga.Extension.Entry{source_type: :path, load_policy: nil}
      assert :eager = Lazy.effective_load_policy(entry)
    end

    test "returns :eager when explicitly set in config" do
      entry = %Minga.Extension.Entry{source_type: :path, load_policy: :eager}
      assert :eager = Lazy.effective_load_policy(entry)
    end

    test "returns :deferred when set" do
      entry = %Minga.Extension.Entry{source_type: :path, load_policy: :deferred}
      assert :deferred = Lazy.effective_load_policy(entry)
    end
  end

  describe "load policy classification" do
    test "eager?" do
      assert Lazy.eager?(:eager)
      refute Lazy.eager?(:deferred)
      refute Lazy.eager?({:on_command, [:cmd]})
    end

    test "deferred?" do
      assert Lazy.deferred?(:deferred)
      refute Lazy.deferred?(:eager)
      refute Lazy.deferred?({:on_command, [:cmd]})
    end

    test "trigger_based?" do
      assert Lazy.trigger_based?({:on_command, [:cmd]})
      assert Lazy.trigger_based?({:on_filetype, [:elixir]})
      assert Lazy.trigger_based?({:on_key, [normal: "SPC m"]})
      refute Lazy.trigger_based?(:eager)
      refute Lazy.trigger_based?(:deferred)
    end
  end

  describe "load_policy DSL macro" do
    test "extensions default to :eager load_policy" do
      {path, cleanup} =
        make_extension("DefaultPolicy", """
        defmodule Minga.TestExtensions.DefaultPolicy do
          use Minga.Extension

          @impl true
          def name, do: :default_policy

          @impl true
          def description, do: "Default policy test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.DefaultPolicy)
        :code.delete(Minga.TestExtensions.DefaultPolicy)
      end)

      compile_extension!(path)
      manifest = Minga.Extension.Manifest.from_module(Minga.TestExtensions.DefaultPolicy, :path)
      assert manifest.load_policy == :eager
    end

    test "load_policy macro sets the policy" do
      {path, cleanup} =
        make_extension("ExplicitPolicy", """
        defmodule Minga.TestExtensions.ExplicitPolicy do
          use Minga.Extension

          load_policy {:on_command, [:explicit_cmd]}

          command :explicit_cmd, "Explicit",
            execute: {Minga.TestExtensions.ExplicitPolicy, :run}

          @impl true
          def name, do: :explicit_policy

          @impl true
          def description, do: "Explicit policy test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}

          def run(state), do: state
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.ExplicitPolicy)
        :code.delete(Minga.TestExtensions.ExplicitPolicy)
      end)

      compile_extension!(path)
      manifest = Minga.Extension.Manifest.from_module(Minga.TestExtensions.ExplicitPolicy, :path)
      assert manifest.load_policy == {:on_command, [:explicit_cmd]}
    end

    test "load_policy :deferred works" do
      {path, cleanup} =
        make_extension("DeferredPolicy", """
        defmodule Minga.TestExtensions.DeferredPolicy do
          use Minga.Extension

          load_policy :deferred

          @impl true
          def name, do: :deferred_policy

          @impl true
          def description, do: "Deferred policy test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.DeferredPolicy)
        :code.delete(Minga.TestExtensions.DeferredPolicy)
      end)

      compile_extension!(path)
      manifest = Minga.Extension.Manifest.from_module(Minga.TestExtensions.DeferredPolicy, :path)
      assert manifest.load_policy == :deferred
    end
  end

  describe "manifest includes load_policy" do
    test "manifest records the declared load_policy" do
      {path, cleanup} =
        make_extension("ManifestPolicy", """
        defmodule Minga.TestExtensions.ManifestPolicy do
          use Minga.Extension

          load_policy {:on_command, [:manifest_cmd]}

          command :manifest_cmd, "Manifest test",
            execute: {Minga.TestExtensions.ManifestPolicy, :run}

          @impl true
          def name, do: :manifest_policy

          @impl true
          def description, do: "Manifest policy test"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}

          def run(state), do: state
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.ManifestPolicy)
        :code.delete(Minga.TestExtensions.ManifestPolicy)
      end)

      compile_extension!(path)

      manifest =
        Minga.Extension.Manifest.from_module(Minga.TestExtensions.ManifestPolicy, :path)

      assert manifest.load_policy == {:on_command, [:manifest_cmd]}
      assert Enum.count(manifest.commands) == 1
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec make_extension(String.t(), String.t()) :: {String.t(), (-> :ok)}
  defp make_extension(dir_name, source) do
    dir =
      Path.join(System.tmp_dir!(), "minga_ext_#{dir_name}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "extension.ex"), source)

    cleanup = fn -> File.rm_rf!(dir) end
    {dir, cleanup}
  end

  @spec compile_extension!(String.t()) :: [module()]
  defp compile_extension!(path) do
    files = Path.wildcard(Path.join(path, "**/*.ex"))

    files
    |> Kernel.ParallelCompiler.compile(return_diagnostics: true)
    |> case do
      {:ok, modules, _} -> modules
      {:error, errors, _} -> raise "Compilation failed: #{inspect(errors)}"
    end
  end
end
