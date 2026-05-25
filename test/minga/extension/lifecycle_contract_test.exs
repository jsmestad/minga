defmodule Minga.Extension.LifecycleContractTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.KeyParser

  setup do
    reg_name = :"ext_lifecycle_reg_#{System.unique_integer([:positive])}"
    sup_name = :"ext_lifecycle_sup_#{System.unique_integer([:positive])}"
    cmd_reg_name = :"ext_lifecycle_cmd_#{System.unique_integer([:positive])}"
    keymap_name = :"ext_lifecycle_keymap_#{System.unique_integer([:positive])}"

    {:ok, _} = ExtRegistry.start_link(name: reg_name)
    {:ok, _} = ExtSupervisor.start_link(name: sup_name)
    {:ok, _} = CommandRegistry.start_link(name: cmd_reg_name)
    {:ok, _} = KeymapActive.start_link(name: keymap_name)

    {:ok,
     registry: reg_name, supervisor: sup_name, command_registry: cmd_reg_name, keymap: keymap_name}
  end

  test "default child stores config and init return is setup-only", ctx do
    {path, cleanup} =
      make_extension("DefaultChildState", """
      defmodule Minga.TestExtensions.DefaultChildState do
        use Minga.Extension

        @impl true
        def name, do: :default_child_state

        @impl true
        def description, do: "Default child state contract"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{runtime_state: true}}
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.DefaultChildState)
      :code.delete(Minga.TestExtensions.DefaultChildState)
    end)

    :ok = ExtRegistry.register(ctx.registry, :default_child_state, path, greeting: "hello")
    {:ok, entry} = ExtRegistry.get(ctx.registry, :default_child_state)

    assert {:ok, pid} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :default_child_state,
               entry
             )

    assert Agent.get(pid, & &1) == [greeting: "hello"]
  end

  test "manifest is recorded before init side effects can fail", ctx do
    {path, cleanup} =
      make_extension("ManifestBeforeInit", """
      defmodule Minga.TestExtensions.ManifestBeforeInit do
        use Minga.Extension

        command :manifest_before_init_cmd, "Manifest command", execute: {__MODULE__, :noop}
        keybind :normal, "SPC m i", :manifest_before_init_cmd, "Manifest keybind"
        modeline_segment :manifest_before_init_segment, side: :right do
          _ = ctx
          nil
        end
        capability :ui, [:modeline]
        capability :ui, [:sidebar]
        capability :ui, [:modeline]

        @impl true
        def name, do: :manifest_before_init

        @impl true
        def description, do: "Manifest before init"

        @impl true
        def version, do: "1.2.3"

        @impl true
        def init(_config), do: {:error, :intentional_failure}

        @spec noop(map()) :: map()
        def noop(state), do: state
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.ManifestBeforeInit)
      :code.delete(Minga.TestExtensions.ManifestBeforeInit)
    end)

    :ok = ExtRegistry.register(ctx.registry, :manifest_before_init, path, [])
    {:ok, entry} = ExtRegistry.get(ctx.registry, :manifest_before_init)

    assert {:error, _reason} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :manifest_before_init,
               entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )

    {:ok, failed_entry} = ExtRegistry.get(ctx.registry, :manifest_before_init)
    assert failed_entry.status == :load_error
    assert failed_entry.manifest.name == :manifest_before_init
    assert failed_entry.manifest.version == "1.2.3"
    assert failed_entry.manifest.source == :path

    assert [{:manifest_before_init_cmd, "Manifest command", _opts}] =
             failed_entry.manifest.commands

    assert [{:normal, "SPC m i", :manifest_before_init_cmd, "Manifest keybind", []}] =
             failed_entry.manifest.keybindings

    assert [{:manifest_before_init_segment, [side: :right], _mfa}] =
             failed_entry.manifest.modeline_segments

    assert failed_entry.manifest.capabilities == [
             ui: [:modeline],
             ui: [:sidebar],
             ui: [:modeline]
           ]
  end

  test "manifest introspection failures become load errors", ctx do
    cases = [
      {"ManifestNameRaise", :name, "raise(\"name boom\")", :manifest_name_raise},
      {"ManifestVersionExit", :version, "exit(:version_boom)", :manifest_version_exit},
      {"ManifestDescriptionThrow", :description, "throw(:description_boom)",
       :manifest_description_throw}
    ]

    for {module_name, callback, body, ext_name} <- cases do
      source =
        case callback do
          :name ->
            """
            defmodule Minga.TestExtensions.#{module_name} do
              use Minga.Extension

              @impl true
              def name, do: #{body}

              @impl true
              def description, do: "Manifest failure #{module_name}"

              @impl true
              def version, do: "1.0.0"

              @impl true
              def init(_config), do: {:ok, %{}}
            end
            """

          :version ->
            """
            defmodule Minga.TestExtensions.#{module_name} do
              use Minga.Extension

              @impl true
              def name, do: :#{ext_name}

              @impl true
              def description, do: "Manifest failure #{module_name}"

              @impl true
              def version, do: #{body}

              @impl true
              def init(_config), do: {:ok, %{}}
            end
            """

          :description ->
            """
            defmodule Minga.TestExtensions.#{module_name} do
              use Minga.Extension

              @impl true
              def name, do: :#{ext_name}

              @impl true
              def description, do: #{body}

              @impl true
              def version, do: "1.0.0"

              @impl true
              def init(_config), do: {:ok, %{}}
            end
            """
        end

      {path, cleanup} = make_extension(module_name, source)

      on_exit(fn ->
        cleanup.()
        :code.purge(Module.concat(Minga.TestExtensions, String.to_atom(module_name)))
        :code.delete(Module.concat(Minga.TestExtensions, String.to_atom(module_name)))
      end)

      :ok = ExtRegistry.register(ctx.registry, ext_name, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, ext_name)

      assert {:error, reason} =
               ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, ext_name, entry)

      assert reason =~ "manifest introspection failed"

      assert {:ok, %{status: :load_error, pid: nil}} = ExtRegistry.get(ctx.registry, ext_name)
    end
  end

  test "direct manifest construction propagates raised declaration failures", _ctx do
    {path, cleanup} =
      make_extension("ManifestDirectRaise", """
      defmodule Minga.TestExtensions.ManifestDirectRaise do
        use Minga.Extension

        @impl true
        def name, do: raise("direct manifest name boom")

        @impl true
        def description, do: "Direct manifest raise"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """)

    Code.compile_file(Path.join(path, "extension.ex"))

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.ManifestDirectRaise)
      :code.delete(Minga.TestExtensions.ManifestDirectRaise)
    end)

    assert_raise RuntimeError, "direct manifest name boom", fn ->
      Minga.Extension.manifest(Minga.TestExtensions.ManifestDirectRaise, :path)
    end
  end

  test "direct manifest construction propagates exit declaration failures", _ctx do
    {path, cleanup} =
      make_extension("ManifestDirectExit", """
      defmodule Minga.TestExtensions.ManifestDirectExit do
        use Minga.Extension

        @impl true
        def name, do: :manifest_direct_exit

        @impl true
        def description, do: "Direct manifest exit"

        @impl true
        def version, do: exit(:direct_manifest_version_boom)

        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """)

    Code.compile_file(Path.join(path, "extension.ex"))

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.ManifestDirectExit)
      :code.delete(Minga.TestExtensions.ManifestDirectExit)
    end)

    assert catch_exit(Minga.Extension.manifest(Minga.TestExtensions.ManifestDirectExit, :path)) ==
             :direct_manifest_version_boom
  end

  test "failed child start removes contributions registered during init", ctx do
    {path, cleanup} =
      make_extension("FailedChildStart", """
      defmodule Minga.TestExtensions.FailedChildStart do
        use Minga.Extension

        @impl true
        def name, do: :failed_child_start

        @impl true
        def description, do: "Failed child start"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(config) do
          source = {:extension, :failed_child_start}
          command_registry = Keyword.fetch!(config, :command_registry)
          command = %Minga.Command{name: :failed_child_start_cmd, description: "Failed child command", execute: &__MODULE__.noop/1}
          :ok = Minga.Command.Registry.register_command(command_registry, source, command)
          {:ok, %{}}
        end

        @impl true
        def child_spec(_config) do
          %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :permanent, type: :worker}
        end

        @spec start_link() :: {:error, atom()}
        def start_link, do: {:error, :intentional_child_failure}

        @spec noop(map()) :: map()
        def noop(state), do: state
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.FailedChildStart)
      :code.delete(Minga.TestExtensions.FailedChildStart)
    end)

    config = [command_registry: ctx.command_registry, keymap: ctx.keymap]
    :ok = ExtRegistry.register(ctx.registry, :failed_child_start, path, config)
    {:ok, entry} = ExtRegistry.get(ctx.registry, :failed_child_start)

    assert {:error, :intentional_child_failure} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :failed_child_start,
               entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )

    assert :error = CommandRegistry.lookup(ctx.command_registry, :failed_child_start_cmd)

    assert {:ok, failed_entry = %{status: :load_error, pid: nil}} =
             ExtRegistry.get(ctx.registry, :failed_child_start)

    assert :ok =
             ExtSupervisor.stop_extension(
               ctx.supervisor,
               ctx.registry,
               :failed_child_start,
               failed_entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )
  end

  test "child_spec exceptions clean contributions registered during init", ctx do
    {path, cleanup} =
      make_extension("ChildSpecRaises", """
      defmodule Minga.TestExtensions.ChildSpecRaises do
        use Minga.Extension

        @impl true
        def name, do: :child_spec_raises

        @impl true
        def description, do: "Child spec raises"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(config) do
          source = {:extension, :child_spec_raises}
          command_registry = Keyword.fetch!(config, :command_registry)
          command = %Minga.Command{name: :child_spec_raises_cmd, description: "Child spec raises command", execute: &__MODULE__.noop/1}
          :ok = Minga.Command.Registry.register_command(command_registry, source, command)
          {:ok, %{}}
        end

        @impl true
        def child_spec(_config), do: raise("boom")

        @spec noop(map()) :: map()
        def noop(state), do: state
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.ChildSpecRaises)
      :code.delete(Minga.TestExtensions.ChildSpecRaises)
    end)

    config = [command_registry: ctx.command_registry, keymap: ctx.keymap]
    :ok = ExtRegistry.register(ctx.registry, :child_spec_raises, path, config)
    {:ok, entry} = ExtRegistry.get(ctx.registry, :child_spec_raises)

    assert {:error, {:child_spec_failed, "boom"}} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :child_spec_raises,
               entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )

    assert :error = CommandRegistry.lookup(ctx.command_registry, :child_spec_raises_cmd)

    assert {:ok, %{status: :load_error, pid: nil}} =
             ExtRegistry.get(ctx.registry, :child_spec_raises)
  end

  test "reload order cleans old source-owned contributions before restart", ctx do
    {path, cleanup} =
      make_extension("ReloadOrder", """
      defmodule Minga.TestExtensions.ReloadOrder do
        use Minga.Extension

        @impl true
        def name, do: :reload_order

        @impl true
        def description, do: "Reload order"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(config) do
          source = {:extension, :reload_order}
          command_registry = Keyword.fetch!(config, :command_registry)
          command = %Minga.Command{name: :reload_order_cmd, description: "Reload order command", execute: &__MODULE__.noop/1}
          :ok = Minga.Command.Registry.register_command(command_registry, source, command)
          {:ok, %{}}
        end

        @spec noop(map()) :: map()
        def noop(state), do: state
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.ReloadOrder)
      :code.delete(Minga.TestExtensions.ReloadOrder)
    end)

    config = [command_registry: ctx.command_registry, keymap: ctx.keymap]
    :ok = ExtRegistry.register(ctx.registry, :reload_order, path, config)
    {:ok, entry} = ExtRegistry.get(ctx.registry, :reload_order)

    assert {:ok, _pid} =
             ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :reload_order, entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )

    assert {:ok, _} = CommandRegistry.lookup(ctx.command_registry, :reload_order_cmd)

    {:ok, running_entry} = ExtRegistry.get(ctx.registry, :reload_order)

    assert :ok =
             ExtSupervisor.stop_extension(
               ctx.supervisor,
               ctx.registry,
               :reload_order,
               running_entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )

    assert :error = CommandRegistry.lookup(ctx.command_registry, :reload_order_cmd)

    {:ok, stopped_entry} = ExtRegistry.get(ctx.registry, :reload_order)

    assert {:ok, _pid} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :reload_order,
               stopped_entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap
             )

    assert {:ok, _} = CommandRegistry.lookup(ctx.command_registry, :reload_order_cmd)
  end

  test "tuple child specs are normalized before monitoring", ctx do
    {path, cleanup} =
      make_extension("TupleChildSpec", """
      defmodule Minga.TestExtensions.TupleChildSpec do
        use Minga.Extension

        @impl true
        def name, do: :tuple_child_spec

        @impl true
        def description, do: "Tuple child spec"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}

        @impl true
        def child_spec(_config), do: {Agent, fn -> :tuple_child_spec end}
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.TupleChildSpec)
      :code.delete(Minga.TestExtensions.TupleChildSpec)
    end)

    :ok = ExtRegistry.register(ctx.registry, :tuple_child_spec, path, [])
    {:ok, entry} = ExtRegistry.get(ctx.registry, :tuple_child_spec)

    assert {:ok, pid} =
             ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :tuple_child_spec, entry)

    assert Agent.get(pid, & &1) == :tuple_child_spec
  end

  test "lifecycle telemetry covers start, stop, cleanup, and restart count", ctx do
    telemetry_id = {__MODULE__, self(), :telemetry}

    :telemetry.attach_many(
      telemetry_id,
      [
        [:minga, :extension, :lifecycle, :stop],
        [:minga, :extension, :lifecycle, :crash_restart_count]
      ],
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    {path, cleanup} =
      make_extension("TelemetryExt", """
      defmodule Minga.TestExtensions.TelemetryExt do
        use Minga.Extension

        @impl true
        def name, do: :telemetry_ext

        @impl true
        def description, do: "Telemetry extension"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.TelemetryExt)
      :code.delete(Minga.TestExtensions.TelemetryExt)
    end)

    :ok = ExtRegistry.register(ctx.registry, :telemetry_ext, path, [])
    {:ok, entry} = ExtRegistry.get(ctx.registry, :telemetry_ext)

    assert {:ok, _pid} =
             ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :telemetry_ext, entry)

    {:ok, running_entry} = ExtRegistry.get(ctx.registry, :telemetry_ext)

    assert :ok =
             ExtSupervisor.stop_extension(
               ctx.supervisor,
               ctx.registry,
               :telemetry_ext,
               running_entry
             )

    assert_receive {:telemetry, [:minga, :extension, :lifecycle, :stop], %{duration: duration},
                    %{extension: :telemetry_ext, phase: :load}}

    assert is_integer(duration)

    assert_receive {:telemetry, [:minga, :extension, :lifecycle, :stop], %{duration: _},
                    %{extension: :telemetry_ext, phase: :init}}

    assert_receive {:telemetry, [:minga, :extension, :lifecycle, :stop], %{duration: _},
                    %{extension: :telemetry_ext, phase: :child_start}}

    assert_receive {:telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                    %{count: 0}, %{extension: :telemetry_ext, phase: :crash_restart_count}}

    assert_receive {:telemetry, [:minga, :extension, :lifecycle, :stop], %{duration: _},
                    %{extension: :telemetry_ext, phase: :stop}}

    assert_receive {:telemetry, [:minga, :extension, :lifecycle, :stop], %{duration: _},
                    %{extension: :telemetry_ext, phase: :cleanup}}
  end

  test "crash restart telemetry increments when a supervised extension child restarts", ctx do
    telemetry_id = {__MODULE__, self(), :restart_telemetry}

    :telemetry.attach_many(
      telemetry_id,
      [[:minga, :extension, :lifecycle, :crash_restart_count]],
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    {path, cleanup} =
      make_extension("RestartTelemetry", """
      defmodule Minga.TestExtensions.RestartTelemetry do
        use Minga.Extension

        @impl true
        def name, do: :restart_telemetry

        @impl true
        def description, do: "Restart telemetry"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.RestartTelemetry)
      :code.delete(Minga.TestExtensions.RestartTelemetry)
    end)

    :ok = ExtRegistry.register(ctx.registry, :restart_telemetry, path, [])
    {:ok, entry} = ExtRegistry.get(ctx.registry, :restart_telemetry)

    assert {:ok, pid} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :restart_telemetry,
               entry
             )

    Process.exit(pid, :kill)

    assert_receive {:telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                    %{count: 0}, %{extension: :restart_telemetry, phase: :crash_restart_count}}

    assert_receive {:telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                    %{count: 1}, %{extension: :restart_telemetry, phase: :crash_restart_count}}

    {:ok, restarted_entry} = ExtRegistry.get(ctx.registry, :restart_telemetry)
    assert restarted_entry.pid != pid

    assert :ok =
             ExtSupervisor.stop_extension(
               ctx.supervisor,
               ctx.registry,
               :restart_telemetry,
               restarted_entry
             )

    assert DynamicSupervisor.count_children(ctx.supervisor).active == 0
  end

  test "intentional stop and restart do not emit crash restart telemetry", ctx do
    telemetry_id = {__MODULE__, self(), :stop_restart_telemetry}

    :telemetry.attach_many(
      telemetry_id,
      [[:minga, :extension, :lifecycle, :crash_restart_count]],
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    {path, cleanup} =
      make_extension("StopRestartTelemetry", """
      defmodule Minga.TestExtensions.StopRestartTelemetry do
        use Minga.Extension

        @impl true
        def name, do: :stop_restart_telemetry

        @impl true
        def description, do: "Stop/restart telemetry"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.StopRestartTelemetry)
      :code.delete(Minga.TestExtensions.StopRestartTelemetry)
    end)

    :ok = ExtRegistry.register(ctx.registry, :stop_restart_telemetry, path, [])
    {:ok, entry} = ExtRegistry.get(ctx.registry, :stop_restart_telemetry)

    assert {:ok, pid1} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :stop_restart_telemetry,
               entry
             )

    assert_receive {:telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                    %{count: 0},
                    %{extension: :stop_restart_telemetry, phase: :crash_restart_count}}

    {:ok, running_entry} = ExtRegistry.get(ctx.registry, :stop_restart_telemetry)

    assert :ok =
             ExtSupervisor.stop_extension(
               ctx.supervisor,
               ctx.registry,
               :stop_restart_telemetry,
               running_entry
             )

    {:ok, stopped_entry} = ExtRegistry.get(ctx.registry, :stop_restart_telemetry)

    assert {:ok, pid2} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :stop_restart_telemetry,
               stopped_entry
             )

    assert_receive {:telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                    %{count: 0},
                    %{extension: :stop_restart_telemetry, phase: :crash_restart_count}}

    refute_receive {:telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                    %{count: 1},
                    %{extension: :stop_restart_telemetry, phase: :crash_restart_count}},
                   150

    {:ok, restarted_entry} = ExtRegistry.get(ctx.registry, :stop_restart_telemetry)
    assert restarted_entry.pid == pid2
    assert restarted_entry.pid != pid1
    assert restarted_entry.status == :running
  end

  test "start uses current registry source type after lifecycle lock", ctx do
    {path, cleanup} =
      make_extension("CurrentSourceTypeWins", """
      defmodule Minga.TestExtensions.CurrentSourceTypeWins do
        use Minga.Extension

        @impl true
        def name, do: :current_source_type_wins

        @impl true
        def description, do: "Current source type wins"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.CurrentSourceTypeWins)
      :code.delete(Minga.TestExtensions.CurrentSourceTypeWins)
    end)

    :ok = ExtRegistry.register_hex(ctx.registry, :current_source_type_wins, "not_installed", [])
    {:ok, stale_hex_entry} = ExtRegistry.get(ctx.registry, :current_source_type_wins)
    assert stale_hex_entry.source_type == :hex

    :ok = ExtRegistry.register(ctx.registry, :current_source_type_wins, path, [])

    assert {:ok, pid} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :current_source_type_wins,
               stale_hex_entry
             )

    {:ok, final_entry} = ExtRegistry.get(ctx.registry, :current_source_type_wins)
    assert final_entry.source_type == :path
    assert final_entry.status == :running
    assert final_entry.pid == pid
    assert final_entry.module == Minga.TestExtensions.CurrentSourceTypeWins
    assert final_entry.manifest.source == :path
  end

  test "concurrent double start with the same stale stopped entry is idempotent", ctx do
    gate_name = :"concurrent_double_start_gate_#{System.unique_integer([:positive])}"
    true = Process.register(self(), gate_name)

    {path, cleanup} =
      make_extension("ConcurrentDoubleStart", """
      defmodule Minga.TestExtensions.ConcurrentDoubleStart do
        use Minga.Extension

        command :concurrent_double_start_cmd, "Concurrent double start command",
          execute: {__MODULE__, :noop}

        @impl true
        def name, do: :concurrent_double_start

        @impl true
        def description, do: "Concurrent double start"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config) do
          send(Process.whereis(#{inspect(gate_name)}), {:concurrent_double_start_init_entered, self()})

          receive do
            :release_concurrent_double_start_init -> {:ok, %{}}
          after
            5_000 -> {:error, :concurrent_double_start_timeout}
          end
        end

        @spec noop(map()) :: map()
        def noop(state), do: state
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.ConcurrentDoubleStart)
      :code.delete(Minga.TestExtensions.ConcurrentDoubleStart)
    end)

    opts = [command_registry: ctx.command_registry, keymap: ctx.keymap]

    :ok = ExtRegistry.register(ctx.registry, :concurrent_double_start, path, [])
    {:ok, stale_stopped_entry} = ExtRegistry.get(ctx.registry, :concurrent_double_start)

    task_a =
      Task.async(fn ->
        ExtSupervisor.start_extension(
          ctx.supervisor,
          ctx.registry,
          :concurrent_double_start,
          stale_stopped_entry,
          opts
        )
      end)

    assert_receive {:concurrent_double_start_init_entered, init_pid}, 1_000

    task_b =
      Task.async(fn ->
        send(Process.whereis(gate_name), {:concurrent_double_start_caller_ready, self()})

        ExtSupervisor.start_extension(
          ctx.supervisor,
          ctx.registry,
          :concurrent_double_start,
          stale_stopped_entry,
          opts
        )
      end)

    assert_receive {:concurrent_double_start_caller_ready, task_b_pid}, 1_000
    assert task_b_pid == task_b.pid
    refute Task.yield(task_b, 50)
    refute_receive {:concurrent_double_start_init_entered, _second_init_pid}, 50

    send(init_pid, :release_concurrent_double_start_init)

    assert [{:ok, pid_a}, {:ok, pid_b}] = [Task.await(task_a), Task.await(task_b)]
    assert pid_a == pid_b
    pid = pid_a

    refute_receive {:concurrent_double_start_init_entered, _second_init_pid}, 50
    assert {:ok, _} = CommandRegistry.lookup(ctx.command_registry, :concurrent_double_start_cmd)

    {:ok, final_entry} = ExtRegistry.get(ctx.registry, :concurrent_double_start)
    assert final_entry.status == :running
    assert final_entry.pid == pid
    assert is_reference(final_entry.lifecycle_ref)

    children = DynamicSupervisor.which_children(ctx.supervisor)

    assert 1 ==
             Enum.count(children, fn
               {_id, child_pid, _type, [Minga.TestExtensions.ConcurrentDoubleStart]} ->
                 child_pid == pid

               _child ->
                 false
             end)
  end

  test "stale stopped-entry stop does not stop or clean a newer lifecycle", ctx do
    {path, cleanup} =
      make_extension("StaleStoppedStop", """
      defmodule Minga.TestExtensions.StaleStoppedStop do
        use Minga.Extension

        command :stale_stopped_stop_cmd, "Stale stopped stop command",
          execute: {__MODULE__, :noop}

        @impl true
        def name, do: :stale_stopped_stop

        @impl true
        def description, do: "Stale stopped stop"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}

        @spec noop(map()) :: map()
        def noop(state), do: state
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.StaleStoppedStop)
      :code.delete(Minga.TestExtensions.StaleStoppedStop)
    end)

    opts = [command_registry: ctx.command_registry, keymap: ctx.keymap]

    :ok = ExtRegistry.register(ctx.registry, :stale_stopped_stop, path, [])
    {:ok, stale_stopped_entry} = ExtRegistry.get(ctx.registry, :stale_stopped_stop)

    assert {:ok, pid} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :stale_stopped_stop,
               stale_stopped_entry,
               opts
             )

    assert :ok =
             ExtSupervisor.stop_extension(
               ctx.supervisor,
               ctx.registry,
               :stale_stopped_stop,
               stale_stopped_entry,
               opts
             )

    assert {:ok, _} = CommandRegistry.lookup(ctx.command_registry, :stale_stopped_stop_cmd)

    {:ok, final_entry} = ExtRegistry.get(ctx.registry, :stale_stopped_stop)
    assert final_entry.status == :running
    assert final_entry.pid == pid
    assert is_reference(final_entry.lifecycle_ref)
  end

  test "terminal child exits clean up source-owned contributions without crash telemetry", ctx do
    for reason <- [:normal, :shutdown] do
      telemetry_id = {__MODULE__, self(), {:terminal_child_cleanup, reason}}

      :telemetry.attach_many(
        telemetry_id,
        [
          [:minga, :extension, :lifecycle, :stop],
          [:minga, :extension, :lifecycle, :crash_restart_count]
        ],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(telemetry_id) end)

      label = Atom.to_string(reason)
      module_name = "TerminalChildCleanup#{String.capitalize(label)}"
      extension_name = String.to_atom("terminal_child_cleanup_#{label}")
      command_name = String.to_atom("terminal_child_cleanup_#{label}_cmd")
      key_str = terminal_cleanup_key(reason)

      {path, cleanup} =
        make_extension(module_name, """
        defmodule Minga.TestExtensions.#{module_name} do
          use Minga.Extension

          command #{inspect(command_name)}, "Terminal child cleanup command",
            execute: {__MODULE__, :noop}

          keybind :insert, #{inspect(key_str)}, #{inspect(command_name)},
            "Terminal child cleanup keybind"

          @impl true
          def name, do: #{inspect(extension_name)}

          @impl true
          def description, do: "Terminal child cleanup #{label}"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}

          @impl true
          def child_spec(_config) do
            %{
              id: __MODULE__,
              start: {Agent, :start_link, [fn -> #{inspect(reason)} end]},
              restart: :temporary,
              type: :worker
            }
          end

          @spec noop(map()) :: map()
          def noop(state), do: state
        end
        """)

      on_exit(fn ->
        cleanup.()
        module = Module.concat(Minga.TestExtensions, String.to_atom(module_name))
        :code.purge(module)
        :code.delete(module)
      end)

      :ok = ExtRegistry.register(ctx.registry, extension_name, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, extension_name)

      assert {:ok, pid} =
               ExtSupervisor.start_extension(
                 ctx.supervisor,
                 ctx.registry,
                 extension_name,
                 entry,
                 command_registry: ctx.command_registry,
                 keymap: ctx.keymap
               )

      assert_receive {:telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                      %{count: 0}, %{extension: ^extension_name, phase: :crash_restart_count}}

      assert {:ok, _} = CommandRegistry.lookup(ctx.command_registry, command_name)
      {:ok, key_sequence} = KeyParser.parse(key_str)

      assert {:command, ^command_name, _description} =
               ctx.keymap
               |> KeymapActive.mode_trie(:insert)
               |> Bindings.lookup_sequence(key_sequence)

      assert :ok = Agent.stop(pid, reason)

      stopped_entry = wait_for_entry_status(ctx.registry, extension_name, :stopped)

      assert_receive {:telemetry, [:minga, :extension, :lifecycle, :stop], %{duration: _},
                      %{extension: ^extension_name, phase: :cleanup}}

      refute_receive {:telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                      %{count: 1}, %{extension: ^extension_name, phase: :crash_restart_count}},
                     200

      assert stopped_entry.pid == nil
      assert stopped_entry.lifecycle_ref == nil
      assert stopped_entry.module == nil
      assert :error = CommandRegistry.lookup(ctx.command_registry, command_name)

      assert :not_found =
               ctx.keymap
               |> KeymapActive.mode_trie(:insert)
               |> Bindings.lookup_sequence(key_sequence)
    end
  end

  test "stale terminal cleanup cannot remove newer lifecycle contributions", ctx do
    test_pid = self()

    {path, cleanup} =
      make_extension("StaleTerminalCleanupRace", """
      defmodule Minga.TestExtensions.StaleTerminalCleanupRace do
        use Minga.Extension

        command :stale_terminal_cleanup_race_cmd, "Stale terminal cleanup race command",
          execute: {__MODULE__, :noop}

        @impl true
        def name, do: :stale_terminal_cleanup_race

        @impl true
        def description, do: "Stale terminal cleanup race"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}

        @impl true
        def child_spec(_config) do
          %{
            id: __MODULE__,
            start: {Agent, :start_link, [fn -> :stale_terminal_cleanup_race end]},
            restart: :temporary,
            type: :worker
          }
        end

        @spec noop(map()) :: map()
        def noop(state), do: state
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.StaleTerminalCleanupRace)
      :code.delete(Minga.TestExtensions.StaleTerminalCleanupRace)
    end)

    callbacks = %{
      blocking_cleanup: fn source ->
        send(test_pid, {:cleanup_started, self(), source})

        receive do
          :release_cleanup -> :ok
        end
      end
    }

    opts = [command_registry: ctx.command_registry, keymap: ctx.keymap, callbacks: callbacks]

    :ok = ExtRegistry.register(ctx.registry, :stale_terminal_cleanup_race, path, [])
    {:ok, entry} = ExtRegistry.get(ctx.registry, :stale_terminal_cleanup_race)

    assert {:ok, pid_a} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :stale_terminal_cleanup_race,
               entry,
               opts
             )

    assert {:ok, _} =
             CommandRegistry.lookup(ctx.command_registry, :stale_terminal_cleanup_race_cmd)

    assert :ok = Agent.stop(pid_a, :normal)

    assert_receive {:cleanup_started, cleanup_pid, {:extension, :stale_terminal_cleanup_race}}

    start_task =
      Task.async(fn ->
        {:ok, current_entry} = ExtRegistry.get(ctx.registry, :stale_terminal_cleanup_race)

        result =
          ExtSupervisor.start_extension(
            ctx.supervisor,
            ctx.registry,
            :stale_terminal_cleanup_race,
            current_entry,
            opts
          )

        send(test_pid, {:new_lifecycle_started, result})
        result
      end)

    refute_receive {:new_lifecycle_started, _result}, 100

    send(cleanup_pid, :release_cleanup)
    assert {:ok, pid_b} = Task.await(start_task)
    assert_receive {:new_lifecycle_started, {:ok, ^pid_b}}

    assert {:ok, _} =
             CommandRegistry.lookup(ctx.command_registry, :stale_terminal_cleanup_race_cmd)

    {:ok, final_entry} = ExtRegistry.get(ctx.registry, :stale_terminal_cleanup_race)
    assert final_entry.pid == pid_b
    assert final_entry.pid != pid_a
    assert final_entry.status == :running
    assert is_reference(final_entry.lifecycle_ref)
  end

  test "terminal cleanup failure is surfaced without clean stopped finalization", ctx do
    telemetry_id = {__MODULE__, self(), :terminal_cleanup_failure_telemetry}

    :telemetry.attach_many(
      telemetry_id,
      [[:minga, :extension, :lifecycle, :stop]],
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    {path, cleanup} =
      make_extension("TerminalCleanupFailure", """
      defmodule Minga.TestExtensions.TerminalCleanupFailure do
        use Minga.Extension

        command :terminal_cleanup_failure_cmd, "Terminal cleanup failure command",
          execute: {__MODULE__, :noop}

        @impl true
        def name, do: :terminal_cleanup_failure

        @impl true
        def description, do: "Terminal cleanup failure"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}

        @impl true
        def child_spec(_config) do
          %{
            id: __MODULE__,
            start: {Agent, :start_link, [fn -> :terminal_cleanup_failure end]},
            restart: :temporary,
            type: :worker
          }
        end

        @spec noop(map()) :: map()
        def noop(state), do: state
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.TerminalCleanupFailure)
      :code.delete(Minga.TestExtensions.TerminalCleanupFailure)
    end)

    callbacks = %{failing_cleanup: fn _source -> {:error, :intentional_cleanup_failure} end}

    :ok = ExtRegistry.register(ctx.registry, :terminal_cleanup_failure, path, [])
    {:ok, entry} = ExtRegistry.get(ctx.registry, :terminal_cleanup_failure)

    assert {:ok, pid} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :terminal_cleanup_failure,
               entry,
               command_registry: ctx.command_registry,
               keymap: ctx.keymap,
               callbacks: callbacks
             )

    assert :ok = Agent.stop(pid, :normal)

    assert_receive {:telemetry, [:minga, :extension, :lifecycle, :stop], %{duration: _},
                    %{extension: :terminal_cleanup_failure, phase: :cleanup}}

    failed_entry = wait_for_entry_status(ctx.registry, :terminal_cleanup_failure, :load_error)
    assert failed_entry.pid == nil
    assert failed_entry.lifecycle_ref == nil
    assert failed_entry.module == Minga.TestExtensions.TerminalCleanupFailure
  end

  test "crashed child without replacement marks the registry crashed", ctx do
    telemetry_id = {__MODULE__, self(), :crash_without_replacement_telemetry}

    :telemetry.attach_many(
      telemetry_id,
      [[:minga, :extension, :lifecycle, :crash_restart_count]],
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    {path, cleanup} =
      make_extension("CrashWithoutReplacement", """
      defmodule Minga.TestExtensions.CrashWithoutReplacement do
        use Minga.Extension

        @impl true
        def name, do: :crash_without_replacement

        @impl true
        def description, do: "Crash without replacement"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}

        @impl true
        def child_spec(_config) do
          %{
            id: __MODULE__,
            start: {Agent, :start_link, [fn -> :crash_without_replacement end]},
            restart: :temporary,
            type: :worker
          }
        end
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.CrashWithoutReplacement)
      :code.delete(Minga.TestExtensions.CrashWithoutReplacement)
    end)

    :ok = ExtRegistry.register(ctx.registry, :crash_without_replacement, path, [])
    {:ok, entry} = ExtRegistry.get(ctx.registry, :crash_without_replacement)

    assert {:ok, pid} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :crash_without_replacement,
               entry
             )

    assert_receive {:telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                    %{count: 0},
                    %{extension: :crash_without_replacement, phase: :crash_restart_count}}

    Process.exit(pid, :kill)

    refute_receive {:telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                    %{count: 1},
                    %{extension: :crash_without_replacement, phase: :crash_restart_count}},
                   150

    {:ok, crashed_entry} = ExtRegistry.get(ctx.registry, :crash_without_replacement)
    assert crashed_entry.status == :crashed
    assert crashed_entry.pid == nil
  end

  test "stale crash monitor does not overwrite a newer lifecycle", ctx do
    telemetry_id = {__MODULE__, self(), :stale_monitor_race_telemetry}
    test_pid = self()

    :telemetry.attach_many(
      telemetry_id,
      [[:minga, :extension, :lifecycle, :crash_restart_count]],
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    stale_monitor_gate = fn ->
      send(test_pid, {:stale_monitor_terminal_exit_blocked, self()})

      receive do
        :release_stale_monitor_terminal_exit -> :ok
      after
        1_000 -> raise "timed out waiting to release stale monitor terminal exit"
      end

      send(test_pid, {:stale_monitor_terminal_exit_released, self()})
      :ok
    end

    {path, cleanup} =
      make_extension("StaleMonitorRace", """
      defmodule Minga.TestExtensions.StaleMonitorRace do
        use Minga.Extension

        @impl true
        def name, do: :stale_monitor_race

        @impl true
        def description, do: "Stale monitor race"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}

        @impl true
        def child_spec(_config) do
          %{
            id: __MODULE__,
            start: {Agent, :start_link, [fn -> :stale_monitor_race end]},
            restart: :temporary,
            type: :worker
          }
        end
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.StaleMonitorRace)
      :code.delete(Minga.TestExtensions.StaleMonitorRace)
    end)

    opts = [test_hooks: %{before_terminal_child_exit: stale_monitor_gate}]

    :ok = ExtRegistry.register(ctx.registry, :stale_monitor_race, path, [])
    {:ok, entry} = ExtRegistry.get(ctx.registry, :stale_monitor_race)

    assert {:ok, pid_a} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :stale_monitor_race,
               entry,
               opts
             )

    assert_receive {:telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                    %{count: 0}, %{extension: :stale_monitor_race, phase: :crash_restart_count}}

    Process.exit(pid_a, :kill)

    assert_receive {:stale_monitor_terminal_exit_blocked, monitor_pid}

    assert {:ok, pid_b} =
             ExtSupervisor.start_extension(
               ctx.supervisor,
               ctx.registry,
               :stale_monitor_race,
               entry
             )

    assert_receive {:telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                    %{count: 0}, %{extension: :stale_monitor_race, phase: :crash_restart_count}}

    send(monitor_pid, :release_stale_monitor_terminal_exit)
    assert_receive {:stale_monitor_terminal_exit_released, ^monitor_pid}

    refute_receive {:telemetry, [:minga, :extension, :lifecycle, :crash_restart_count],
                    %{count: 1}, %{extension: :stale_monitor_race, phase: :crash_restart_count}},
                   200

    {:ok, final_entry} = ExtRegistry.get(ctx.registry, :stale_monitor_race)
    assert final_entry.pid == pid_b
    assert final_entry.status == :running
  end

  test "slow lifecycle phases are logged with extension and phase", ctx do
    {path, cleanup} =
      make_extension("SlowLifecycle", """
      defmodule Minga.TestExtensions.SlowLifecycle do
        use Minga.Extension

        @impl true
        def name, do: :slow_lifecycle

        @impl true
        def description, do: "Slow lifecycle log test"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.SlowLifecycle)
      :code.delete(Minga.TestExtensions.SlowLifecycle)
    end)

    :ok = ExtRegistry.register(ctx.registry, :slow_lifecycle, path, [])
    {:ok, entry} = ExtRegistry.get(ctx.registry, :slow_lifecycle)

    log =
      capture_log(fn ->
        assert {:ok, _pid} =
                 ExtSupervisor.start_extension(
                   ctx.supervisor,
                   ctx.registry,
                   :slow_lifecycle,
                   entry,
                   slow_lifecycle_threshold_ms: 0
                 )
      end)

    assert log =~ "Extension slow_lifecycle lifecycle phase load took"
  end

  @spec terminal_cleanup_key(:normal | :shutdown) :: String.t()
  defp terminal_cleanup_key(:normal), do: "C-t"
  defp terminal_cleanup_key(:shutdown), do: "C-y"

  @spec wait_for_entry_status(GenServer.server(), atom(), Minga.Extension.extension_status()) ::
          ExtRegistry.entry()
  defp wait_for_entry_status(registry, name, status),
    do: wait_for_entry_status(registry, name, status, 20)

  @spec wait_for_entry_status(
          GenServer.server(),
          atom(),
          Minga.Extension.extension_status(),
          non_neg_integer()
        ) ::
          ExtRegistry.entry()
  defp wait_for_entry_status(registry, name, status, attempts_left) do
    case ExtRegistry.get(registry, name) do
      {:ok, %{status: ^status} = entry} ->
        entry

      _other when attempts_left > 0 ->
        receive do
        after
          10 -> wait_for_entry_status(registry, name, status, attempts_left - 1)
        end

      other ->
        flunk("expected #{inspect(name)} to reach #{inspect(status)}, got #{inspect(other)}")
    end
  end

  @spec make_extension(String.t(), String.t()) :: {String.t(), (-> :ok)}
  defp make_extension(dir_name, source) do
    dir =
      Path.join(System.tmp_dir!(), "minga_ext_#{dir_name}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "extension.ex"), source)
    {dir, fn -> File.rm_rf!(dir) end}
  end
end
