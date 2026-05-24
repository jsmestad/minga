defmodule Minga.Extension.LifecycleContractTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap.Active, as: KeymapActive

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

    assert failed_entry.manifest.capabilities == %{ui: [:modeline]}
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

  @spec make_extension(String.t(), String.t()) :: {String.t(), (-> :ok)}
  defp make_extension(dir_name, source) do
    dir =
      Path.join(System.tmp_dir!(), "minga_ext_#{dir_name}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "extension.ex"), source)
    {dir, fn -> File.rm_rf!(dir) end}
  end
end
