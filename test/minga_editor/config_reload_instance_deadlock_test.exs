defmodule MingaEditor.ConfigReloadInstanceDeadlockTest do
  # Mutates the production extension declaration registry used by Config.Loader.
  use Minga.Test.EditorCase, async: false, rendering: :disabled

  alias Minga.Config.Loader
  alias Minga.Config.Options
  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ArtifactGenerationState
  alias Minga.Extension.CallbackRegistry
  alias Minga.Extension.CodeLease
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.RootSupervisor
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap.Active, as: KeymapActive
  alias MingaEditor.Commands.BufferManagement

  @timeout 15_000

  test "EffectScheduler worker can reload Config through Instance stop and asynchronous Editor ack" do
    ctx = start_editor("reload ack")
    suffix = System.unique_integer([:positive])
    name = :config_reload_instance_ack
    config_home = Path.join(System.tmp_dir!(), "minga_reload_ack_#{suffix}")
    config_dir = Path.join(config_home, "minga")
    extension_dir = Path.join(config_home, "extension")
    File.mkdir_p!(config_dir)
    File.mkdir_p!(extension_dir)
    File.write!(Path.join(config_dir, "config.exs"), "use Minga.Config\n")

    module = Minga.TestExtensions.ConfigReloadInstanceAck

    File.write!(Path.join(extension_dir, "extension.ex"), """
    defmodule #{inspect(module)} do
      use Minga.Extension

      @impl true
      def name, do: :config_reload_instance_ack
      @impl true
      def description, do: "Config reload Instance ack"
      @impl true
      def version, do: "1.0.0"
      @impl true
      def init(_config), do: {:ok, %{}}
    end
    """)

    File.write!(Path.join(config_dir, "config.exs"), """
    use Minga.Config
    extension #{inspect(name)}, path: #{inspect(extension_dir)}
    """)

    previous_load_extensions = Application.get_env(:minga, :load_extensions)
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    Application.put_env(:minga, :load_extensions, false)

    on_exit(fn ->
      case previous_load_extensions do
        nil ->
          # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
          Application.delete_env(:minga, :load_extensions)

        value ->
          # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
          Application.put_env(:minga, :load_extensions, value)
      end
    end)

    owner = :"reload_ack_artifacts_#{suffix}"
    persistence_key = {__MODULE__, suffix}

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
    callbacks = :"reload_ack_callbacks_#{suffix}"
    start_supervised!({CallbackRegistry, name: callbacks})
    options = start_supervised!({Options, name: nil})
    keymap = :"reload_ack_keymap_#{suffix}"
    start_supervised!({KeymapActive, name: keymap})

    loader =
      start_supervised!(
        {Loader,
         name: nil,
         config_home: config_home,
         options_server: options,
         keymap_server: keymap,
         artifact_admission: admission},
        id: {Loader, suffix}
      )

    {:ok, declaration} = ExtRegistry.get(name)

    opts = [
      artifact_admission: admission,
      code_lease: code_lease,
      callback_registry: callbacks,
      keymap: keymap
    ]

    assert {:ok, runtime} =
             ExtSupervisor.start_extension(
               Minga.Extension.Supervisor,
               ExtRegistry,
               name,
               declaration,
               opts
             )

    runtime_ref = Process.monitor(runtime)

    :sys.replace_state(
      ctx.editor,
      &BufferManagement.reload_config(&1, Loader, [loader])
    )

    assert_receive {:DOWN, ^runtime_ref, :process, ^runtime, _reason}, @timeout
    assert_registry_stopped(name)

    on_exit(fn ->
      ExtSupervisor.stop_all()
      ExtRegistry.unregister(name)
      RootSupervisor.terminate_root(Minga.Extension.RootSupervisor, name)
      ArtifactGenerationState.reset_for_test(persistence_key)
      File.rm_rf!(config_home)
      :code.purge(module)
      :code.delete(module)
    end)
  end

  @spec assert_registry_stopped(atom(), non_neg_integer()) :: :ok
  defp assert_registry_stopped(name, attempts \\ 1_000)

  defp assert_registry_stopped(name, attempts) when attempts > 0 do
    case ExtRegistry.get(name) do
      {:ok, %{status: :stopped, pid: nil, last_error: nil}} ->
        :ok

      _projection ->
        receive do
        after
          10 -> assert_registry_stopped(name, attempts - 1)
        end
    end
  end

  defp assert_registry_stopped(name, 0) do
    flunk("expected stopped extension projection, got #{inspect(ExtRegistry.get(name))}")
  end
end
