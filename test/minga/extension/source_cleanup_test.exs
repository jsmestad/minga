defmodule Minga.Extension.SourceCleanupTest do
  # Exercises global source-owned registries that use ETS or persistent_term.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Extension.ContributionCleanup
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.KeyParser

  setup do
    reg_name = :"ext_cleanup_reg_#{System.unique_integer([:positive])}"
    sup_name = :"ext_cleanup_sup_#{System.unique_integer([:positive])}"
    cmd_reg_name = :"ext_cleanup_cmd_#{System.unique_integer([:positive])}"
    keymap_name = :"ext_cleanup_keymap_#{System.unique_integer([:positive])}"

    {:ok, _} = ExtRegistry.start_link(name: reg_name)
    {:ok, _} = ExtSupervisor.start_link(name: sup_name)
    {:ok, _} = CommandRegistry.start_link(name: cmd_reg_name)
    {:ok, _} = KeymapActive.start_link(name: keymap_name)

    on_exit(fn ->
      for source <- [
            {:extension, :source_cleanup},
            {:extension, :source_cleanup_fails},
            {:extension, :command_collision},
            {:extension, :keybind_collision}
          ] do
        Minga.Keymap.Scope.unregister_source(source)
        MingaEditor.Input.unregister_source(source)
        Minga.Language.Registry.unregister_source(source)
        MingaEditor.UI.Theme.unregister_source(source)
        Minga.Tool.Recipe.Registry.unregister_source(source)
        Minga.Config.ModelineSegments.unregister_source(source)
      end
    end)

    {:ok,
     registry: reg_name, supervisor: sup_name, command_registry: cmd_reg_name, keymap: keymap_name}
  end

  test "failed init removes source-owned contributions registered before the error", ctx do
    {path, cleanup} =
      make_extension("SourceCleanupFails", """
      defmodule Minga.TestExtensions.SourceCleanupFails do
        use Minga.Extension

        @impl true
        def name, do: :source_cleanup_fails

        @impl true
        def description, do: "Source cleanup failure test"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(config) do
          source = {:extension, :source_cleanup_fails}
          command_registry = Keyword.fetch!(config, :command_registry)
          command = %Minga.Command{name: :source_cleanup_failed_cmd, description: "Failed cleanup", execute: &__MODULE__.noop/1}
          :ok = Minga.Command.Registry.register_command(command_registry, source, command)
          :ok = Minga.Language.Registry.register(%Minga.Language{name: :source_cleanup_failed_lang, label: "Failed Cleanup", comment_token: "// ", extensions: ["source_cleanup_failed"]}, source)
          {:error, :intentional_failure}
        end

        @spec noop(map()) :: map()
        def noop(state), do: state
      end
      """)

    on_exit(fn ->
      cleanup.()
      Minga.Language.Registry.unregister_source({:extension, :source_cleanup_fails})
      :code.purge(Minga.TestExtensions.SourceCleanupFails)
      :code.delete(Minga.TestExtensions.SourceCleanupFails)
    end)

    config = [command_registry: ctx.command_registry, keymap: ctx.keymap]
    :ok = ExtRegistry.register(ctx.registry, :source_cleanup_fails, path, config)
    {:ok, entry} = ExtRegistry.get(ctx.registry, :source_cleanup_fails)

    assert {:error, _reason} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :source_cleanup_fails,
               entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )

    assert :error = CommandRegistry.lookup(ctx.command_registry, :source_cleanup_failed_cmd)
    assert Minga.Language.Registry.get(:source_cleanup_failed_lang) == nil
  end

  test "failed init reports cleanup failures and still runs later cleanup callbacks",
       ctx do
    assert :ok =
             ContributionCleanup.register(:aaa_cleanup_failure, fn _source ->
               raise "cleanup failure"
             end)

    assert :ok =
             ContributionCleanup.register(:zzz_cleanup_followup, fn source ->
               send(self(), {:cleanup_followup, source})
               :ok
             end)

    {path, cleanup} =
      make_extension("CleanupFailure", """
      defmodule Minga.TestExtensions.CleanupFailure do
        use Minga.Extension

        @impl true
        def name, do: :cleanup_failure

        @impl true
        def description, do: "Cleanup failure test"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(config) do
          source = {:extension, :cleanup_failure}
          command_registry = Keyword.fetch!(config, :command_registry)
          command = %Minga.Command{name: :cleanup_failure_cmd, description: "Cleanup failure", execute: &__MODULE__.noop/1}
          :ok = Minga.Command.Registry.register_command(command_registry, source, command)
          :ok = Minga.Language.Registry.register(%Minga.Language{name: :cleanup_failure_lang, label: "Cleanup Failure", comment_token: "// ", extensions: ["cleanup_failure"]}, source)
          {:error, :intentional_failure}
        end

        @spec noop(map()) :: map()
        def noop(state), do: state
      end
      """)

    on_exit(fn ->
      cleanup.()
      ContributionCleanup.unregister(:aaa_cleanup_failure)
      ContributionCleanup.unregister(:zzz_cleanup_followup)
      :code.purge(Minga.TestExtensions.CleanupFailure)
      :code.delete(Minga.TestExtensions.CleanupFailure)
    end)

    config = [command_registry: ctx.command_registry, keymap: ctx.keymap]
    :ok = ExtRegistry.register(ctx.registry, :cleanup_failure, path, config)
    {:ok, entry} = ExtRegistry.get(ctx.registry, :cleanup_failure)

    log =
      capture_log(fn ->
        assert {:error, {:cleanup_failed, "init failed: :intentional_failure", failures}} =
                 ExtSupervisor.start_extension(
                   ctx.supervisor,
                   ctx.registry,
                   :cleanup_failure,
                   entry,
                   command_registry: ctx.command_registry,
                   keymap: ctx.keymap
                 )

        assert Enum.any?(failures, fn
                 %{family: :aaa_cleanup_failure, source: {:extension, :cleanup_failure}} -> true
                 _ -> false
               end)
      end)

    assert log =~ "contribution cleanup failed"
    assert_receive {:cleanup_followup, {:extension, :cleanup_failure}}
    assert Minga.Language.Registry.get(:cleanup_failure_lang) == nil
    assert :error = CommandRegistry.lookup(ctx.command_registry, :cleanup_failure_cmd)
  end

  test "stop_extension returns cleanup failure after successful termination", ctx do
    {path, cleanup} =
      make_extension("StopCleanupFailure", """
      defmodule Minga.TestExtensions.StopCleanupFailure do
        use Minga.Extension

        @impl true
        def name, do: :stop_cleanup_failure

        @impl true
        def description, do: "Stop cleanup failure test"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.StopCleanupFailure)
      :code.delete(Minga.TestExtensions.StopCleanupFailure)
    end)

    config = [command_registry: ctx.command_registry, keymap: ctx.keymap]
    :ok = ExtRegistry.register(ctx.registry, :stop_cleanup_failure, path, config)
    {:ok, entry} = ExtRegistry.get(ctx.registry, :stop_cleanup_failure)

    {:ok, pid} =
      ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :stop_cleanup_failure, entry)

    {:ok, running_entry} = ExtRegistry.get(ctx.registry, :stop_cleanup_failure)

    pid_ref = Process.monitor(pid)

    assert {:error, {:cleanup_failed, failures}} =
             ExtSupervisor.stop_extension(
               ctx.supervisor,
               ctx.registry,
               :stop_cleanup_failure,
               running_entry,
               command_registry: :missing_cleanup_registry,
               keymap: ctx.keymap
             )

    assert Enum.any?(failures, fn
             %{family: :command_registry, source: {:extension, :stop_cleanup_failure}} -> true
             _ -> false
           end)

    assert_receive {:DOWN, ^pid_ref, :process, ^pid, _reason}, 1_000

    {:ok, stopped_entry} = ExtRegistry.get(ctx.registry, :stop_cleanup_failure)
    assert stopped_entry.status == :load_error
    assert stopped_entry.pid == nil
    assert stopped_entry.module == Minga.TestExtensions.StopCleanupFailure
  end

  test "stop_extension cleans source-owned contributions even when the pid is stale", ctx do
    {path, cleanup} =
      make_extension("StopAggregateFailure", """
      defmodule Minga.TestExtensions.StopAggregateFailure do
        use Minga.Extension

        @impl true
        def name, do: :stop_aggregate_failure

        @impl true
        def description, do: "Stop aggregate failure test"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(config) do
          source = {:extension, :stop_aggregate_failure}
          command_registry = Keyword.fetch!(config, :command_registry)
          keymap = Keyword.fetch!(config, :keymap)

          command = %Minga.Command{
            name: :stop_aggregate_failure_cmd,
            description: "Stop aggregate failure command",
            execute: &__MODULE__.noop/1
          }

          :ok = Minga.Command.Registry.register_command(command_registry, source, command)
          :ok = Minga.Language.Registry.register(%Minga.Language{
            name: :stop_aggregate_failure_lang,
            label: "Stop Aggregate Failure Language",
            comment_token: "// ",
            extensions: ["stop_aggregate_failure"]
          }, source)

          {:ok, %{keymap: keymap}}
        end

        @spec noop(map()) :: map()
        def noop(state), do: state
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.StopAggregateFailure)
      :code.delete(Minga.TestExtensions.StopAggregateFailure)
    end)

    config = [command_registry: ctx.command_registry, keymap: ctx.keymap]
    :ok = ExtRegistry.register(ctx.registry, :stop_aggregate_failure, path, config)
    {:ok, entry} = ExtRegistry.get(ctx.registry, :stop_aggregate_failure)

    {:ok, pid} =
      ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :stop_aggregate_failure, entry)

    {:ok, running_entry} = ExtRegistry.get(ctx.registry, :stop_aggregate_failure)

    bogus_pid =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    ref = Process.monitor(pid)
    on_exit(fn -> Process.exit(bogus_pid, :kill) end)

    assert :ok =
             ExtSupervisor.stop_extension(
               ctx.supervisor,
               ctx.registry,
               :stop_aggregate_failure,
               %{running_entry | pid: bogus_pid},
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )

    {:ok, stopped_entry} = ExtRegistry.get(ctx.registry, :stop_aggregate_failure)
    assert stopped_entry.status == :stopped
    assert stopped_entry.pid == nil
    assert stopped_entry.module == nil
    assert :error = CommandRegistry.lookup(ctx.command_registry, :stop_aggregate_failure_cmd)
    assert Minga.Language.Registry.get(:stop_aggregate_failure_lang) == nil
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  test "command registration failure stops keybind registration and marks the extension failed",
       ctx do
    :ok =
      CommandRegistry.register(
        ctx.command_registry,
        :config,
        :shared_cmd,
        "Foreign shared command",
        fn state -> state end
      )

    {path, cleanup} =
      make_extension("CommandCollision", """
      defmodule Minga.TestExtensions.CommandCollision do
        use Minga.Extension

        @impl true
        def name, do: :command_collision

        @impl true
        def description, do: "Command collision test"

        @impl true
        def version, do: "1.0.0"

        command :shared_cmd, "Rejected shared command", execute: {__MODULE__, :noop}
        keybind :insert, "C-j", :shared_cmd, "Rejected shared keybind"

        @impl true
        def init(_config), do: {:ok, %{}}

        @spec noop(map()) :: map()
        def noop(state), do: state
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.CommandCollision)
      :code.delete(Minga.TestExtensions.CommandCollision)
    end)

    config = [command_registry: ctx.command_registry, keymap: ctx.keymap]
    :ok = ExtRegistry.register(ctx.registry, :command_collision, path, config)
    {:ok, entry} = ExtRegistry.get(ctx.registry, :command_collision)

    assert {:error, {:duplicate_name, :shared_cmd, :config, {:extension, :command_collision}}} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :command_collision,
               entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )

    assert {:ok, %{status: :load_error, pid: nil}} =
             ExtRegistry.get(ctx.registry, :command_collision)

    assert {:ok, _} = CommandRegistry.lookup(ctx.command_registry, :shared_cmd)

    {:ok, keys} = KeyParser.parse("C-j")

    assert :not_found =
             ctx.keymap |> KeymapActive.mode_trie(:insert) |> Bindings.lookup_sequence(keys)
  end

  test "keybind registration failure reports cleanup failures and still cleans up the child",
       ctx do
    assert :ok =
             Minga.Keymap.Active.bind(ctx.keymap, :insert, "C-j", :config_cmd, "Config binding")

    assert :ok =
             ContributionCleanup.register(:aaa_cleanup_failure, fn _source ->
               raise "cleanup failure"
             end)

    on_exit(fn -> ContributionCleanup.unregister(:aaa_cleanup_failure) end)

    {path, cleanup} =
      make_extension("KeybindCleanupFailure", """
      defmodule Minga.TestExtensions.KeybindCleanupFailure do
        use Minga.Extension

        @impl true
        def name, do: :keybind_cleanup_failure

        @impl true
        def description, do: "Keybind cleanup failure test"

        @impl true
        def version, do: "1.0.0"

        command :keybind_cleanup_failure_cmd, "Extension command", execute: {__MODULE__, :noop}
        keybind :insert, "C-j", :keybind_cleanup_failure_cmd, "Rejected shared keybind"

        @impl true
        def init(_config), do: {:ok, %{}}

        @spec noop(map()) :: map()
        def noop(state), do: state
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.KeybindCleanupFailure)
      :code.delete(Minga.TestExtensions.KeybindCleanupFailure)
    end)

    config = [command_registry: ctx.command_registry, keymap: ctx.keymap]
    :ok = ExtRegistry.register(ctx.registry, :keybind_cleanup_failure, path, config)
    {:ok, entry} = ExtRegistry.get(ctx.registry, :keybind_cleanup_failure)

    assert {:error, {:cleanup_failed, {:keybind_registration_failed, "C-j", reason}, failures}} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :keybind_cleanup_failure,
               entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )

    assert reason =~ "already"

    assert Enum.any?(failures, fn
             %{family: :aaa_cleanup_failure, source: {:extension, :keybind_cleanup_failure}} ->
               true

             _ ->
               false
           end)

    assert {:ok, %{status: :load_error, pid: nil}} =
             ExtRegistry.get(ctx.registry, :keybind_cleanup_failure)

    assert :error = CommandRegistry.lookup(ctx.command_registry, :keybind_cleanup_failure_cmd)

    {:ok, keys} = KeyParser.parse("C-j")

    assert {:command, :config_cmd, _desc} =
             ctx.keymap |> KeymapActive.mode_trie(:insert) |> Bindings.lookup_sequence(keys)
  end

  test "stop_all aggregates failures and still stops healthy extensions", ctx do
    {healthy_path, healthy_cleanup} =
      make_extension("StopAllHealthy", """
      defmodule Minga.TestExtensions.StopAllHealthy do
        use Minga.Extension

        @impl true
        def name, do: :stop_all_healthy

        @impl true
        def description, do: "Healthy stop all test"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """)

    on_exit(fn ->
      healthy_cleanup.()
      :code.purge(Minga.TestExtensions.StopAllHealthy)
      :code.delete(Minga.TestExtensions.StopAllHealthy)
    end)

    :ok = ExtRegistry.register(ctx.registry, :stop_all_healthy, healthy_path, [])
    {:ok, healthy_entry} = ExtRegistry.get(ctx.registry, :stop_all_healthy)

    {:ok, healthy_pid} =
      ExtSupervisor.start_extension(
        ctx.supervisor,
        ctx.registry,
        :stop_all_healthy,
        healthy_entry
      )

    bogus_pid =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(bogus_pid) do
        Process.exit(bogus_pid, :kill)
      end
    end)

    :ok = ExtRegistry.register(ctx.registry, :stop_all_broken, healthy_path, [])

    :ok =
      ExtRegistry.update(ctx.registry, :stop_all_broken,
        pid: bogus_pid,
        module: nil,
        status: :running
      )

    healthy_ref = Process.monitor(healthy_pid)
    assert {:error, failures} = ExtSupervisor.stop_all(ctx.supervisor, ctx.registry)

    assert Enum.any?(failures, fn
             %{extension: :stop_all_broken, reason: reason} -> reason != nil
             _ -> false
           end)

    {:ok, healthy_stopped} = ExtRegistry.get(ctx.registry, :stop_all_healthy)
    assert healthy_stopped.status == :stopped
    assert healthy_stopped.pid == nil
    assert_receive {:DOWN, ^healthy_ref, :process, ^healthy_pid, _reason}, 1_000

    {:ok, broken_entry} = ExtRegistry.get(ctx.registry, :stop_all_broken)
    assert broken_entry.status == :stopped
    assert broken_entry.pid == nil

    ExtRegistry.unregister(ctx.registry, :stop_all_broken)
  end

  test "stopping an extension removes every source-owned contribution type", ctx do
    {path, cleanup} =
      make_extension("SourceCleanup", """
      defmodule Minga.TestExtensions.SourceCleanup do
        use Minga.Extension

        @impl true
        def name, do: :source_cleanup

        @impl true
        def description, do: "Source cleanup test"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(config) do
          source = {:extension, :source_cleanup}
          command_registry = Keyword.fetch!(config, :command_registry)
          keymap = Keyword.fetch!(config, :keymap)

          command = %Minga.Command{name: :source_cleanup_cmd, description: "Source cleanup", execute: &__MODULE__.noop/1}
          :ok = Minga.Command.Registry.register_command(command_registry, source, command)
          :ok = Minga.Keymap.Active.bind(keymap, :normal, "SPC m c", :source_cleanup_cmd, "Source cleanup", source: source)
          :ok = Minga.Keymap.Scope.register(source, :source_cleanup_scope, Minga.Keymap.Scope.Editor)
          :ok = MingaEditor.Input.register_handler(source, MingaEditor.Input.GlobalBindings, phase: :surface, priority: -20)

          :ok = Minga.Language.Registry.register(%Minga.Language{name: :source_cleanup_lang, label: "Source Cleanup", comment_token: "// ", extensions: ["source_cleanup"]}, source)

          doom = MingaEditor.UI.Theme.get!(:doom_one)
          :ok = MingaEditor.UI.Theme.register_themes(%{source_cleanup_theme: %{doom | name: :source_cleanup_theme}}, source)

          recipe = %Minga.Tool.Recipe{name: :source_cleanup_recipe, label: "Source Cleanup Recipe", description: "Recipe", provides: ["source-cleanup-recipe"], method: :npm, package: "source-cleanup-recipe", homepage: "https://example.invalid/source-cleanup", category: :formatter, languages: [:elixir]}
          :ok = Minga.Tool.Recipe.Registry.register(recipe, source)

          :ok = Minga.Config.ModelineSegments.register(:source_cleanup_segment, [side: :right], fn _ctx -> nil end, source)
          {:ok, %{}}
        end

        @spec noop(map()) :: map()
        def noop(state), do: state
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.SourceCleanup)
      :code.delete(Minga.TestExtensions.SourceCleanup)
    end)

    config = [command_registry: ctx.command_registry, keymap: ctx.keymap]
    :ok = ExtRegistry.register(ctx.registry, :source_cleanup, path, config)
    {:ok, entry} = ExtRegistry.get(ctx.registry, :source_cleanup)

    assert {:ok, _pid} =
             ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :source_cleanup, entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )

    assert {:ok, _} = CommandRegistry.lookup(ctx.command_registry, :source_cleanup_cmd)
    assert {:command, :source_cleanup_cmd, _desc} = leader_lookup(ctx.keymap, "m c")
    assert Minga.Keymap.Scope.module_for(:source_cleanup_scope) == Minga.Keymap.Scope.Editor

    assert Enum.count(
             MingaEditor.Input.surface_handlers(%{editing_model: Minga.Editing.Model.Vim}),
             &(&1 == MingaEditor.Input.GlobalBindings)
           ) == 2

    assert %Minga.Language{name: :source_cleanup_lang} =
             Minga.Language.Registry.get(:source_cleanup_lang)

    assert {:ok, %MingaEditor.UI.Theme{name: :source_cleanup_theme}} =
             MingaEditor.UI.Theme.get(:source_cleanup_theme)

    assert %Minga.Tool.Recipe{name: :source_cleanup_recipe} =
             Minga.Tool.Recipe.Registry.get(:source_cleanup_recipe)

    assert %{name: :source_cleanup_segment} =
             Minga.Config.ModelineSegments.lookup(:source_cleanup_segment)

    {:ok, running_entry} = ExtRegistry.get(ctx.registry, :source_cleanup)

    assert :ok =
             ExtSupervisor.stop_extension(
               ctx.supervisor,
               ctx.registry,
               :source_cleanup,
               running_entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )

    assert :error = CommandRegistry.lookup(ctx.command_registry, :source_cleanup_cmd)
    assert :not_found = leader_lookup(ctx.keymap, "m c")
    assert Minga.Keymap.Scope.module_for(:source_cleanup_scope) == nil

    assert Enum.count(
             MingaEditor.Input.surface_handlers(%{editing_model: Minga.Editing.Model.Vim}),
             &(&1 == MingaEditor.Input.GlobalBindings)
           ) == 1

    assert Minga.Language.Registry.get(:source_cleanup_lang) == nil
    assert :error = MingaEditor.UI.Theme.get(:source_cleanup_theme)
    assert Minga.Tool.Recipe.Registry.get(:source_cleanup_recipe) == nil
    assert Minga.Config.ModelineSegments.lookup(:source_cleanup_segment) == nil
  end

  @spec leader_lookup(GenServer.server(), String.t()) :: term()
  defp leader_lookup(keymap, key_string) do
    leader_trie = KeymapActive.leader_trie(keymap)
    {:ok, keys} = KeyParser.parse(key_string)
    Bindings.lookup_sequence(leader_trie, keys)
  end

  @spec make_extension(String.t(), String.t()) :: {String.t(), (-> :ok)}
  defp make_extension(dir_name, source) do
    dir =
      Path.join(System.tmp_dir!(), "minga_ext_#{dir_name}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, "extension.ex")
    File.write!(path, source)
    {dir, fn -> File.rm_rf!(dir) end}
  end
end
