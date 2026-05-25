defmodule Minga.Extension.SupervisorTest do
  # Runtime code compilation and fixed Minga.TestExtensions module names are global.
  use ExUnit.Case, async: false

  # Runtime code compilation makes these inherently slow (~250ms).
  # Excluded from test.llm; runs in test.heavy and full suite.
  @moduletag :heavy

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor

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

      children = DynamicSupervisor.which_children(ctx.supervisor)

      assert Enum.count(children, fn {_id, child_pid, _type, _modules} -> child_pid == pid end) ==
               1
    end

    test "reuses supervised child when registry running pid is stale", ctx do
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

      children = DynamicSupervisor.which_children(ctx.supervisor)

      assert Enum.count(children, fn {_id, child_pid, _type, _modules} -> child_pid == pid end) ==
               1
    end

    test "restarts when registry has stale running pid outside supervisor", ctx do
      {path, cleanup} =
        make_extension("StaleRunningExt", """
        defmodule Minga.TestExtensions.StaleRunningExt do
          use Minga.Extension

          @impl true
          def name, do: :stale_running_ext

          @impl true
          def description, do: "Stale running test extension"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.StaleRunningExt)
        :code.delete(Minga.TestExtensions.StaleRunningExt)
      end)

      :ok = ExtRegistry.register(ctx.registry, :stale_running_ext, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :stale_running_ext)
      stale_pid = self()

      ExtRegistry.update(ctx.registry, :stale_running_ext,
        status: :running,
        pid: stale_pid,
        module: Minga.TestExtensions.StaleRunningExt
      )

      assert {:ok, pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 :stale_running_ext,
                 entry
               )

      assert pid != stale_pid
      {:ok, updated} = ExtRegistry.get(ctx.registry, :stale_running_ext)
      assert updated.status == :running
      assert updated.pid == pid
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
    test "preserves supervisor lookup failures instead of reporting not found", ctx do
      :ok = ExtRegistry.register(ctx.registry, :lookup_failure, System.tmp_dir!(), [])

      :ok =
        ExtRegistry.update(ctx.registry, :lookup_failure,
          module: Minga.TestExtensions.LookupFailure,
          status: :running,
          pid: nil
        )

      {:ok, entry} = ExtRegistry.get(ctx.registry, :lookup_failure)

      assert {:error, {:which_children_failed, _reason}} =
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

    test "stops a running extension and purges the module", ctx do
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
      assert stopped.module == nil
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

      assert Enum.any?(failures, fn
               %{extension: :git_start_fail, reason: reason} ->
                 is_binary(reason) and reason =~ "git clone failed"

               _ ->
                 false
             end)

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

      assert stopped_entry.module == nil
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
