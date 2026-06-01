defmodule Minga.Extension.CodeLeaseTest do
  use ExUnit.Case, async: true

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Extension.CodeLease
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap.Active, as: KeymapActive

  setup do
    lease_name = :"ext_code_lease_#{System.unique_integer([:positive])}"
    {:ok, _lease} = CodeLease.start_link(name: lease_name)
    {:ok, code_lease: lease_name}
  end

  test "leases block module purge until explicitly released", ctx do
    module = Minga.TestExtensions.LeasedCallback

    {:ok, lease} =
      CodeLease.lease({:extension, :leased_callback}, module, :tool, server: ctx.code_lease)

    assert {:error, {:leased_modules, [summary]}} =
             CodeLease.ensure_purge_allowed({:extension, :leased_callback}, module,
               server: ctx.code_lease
             )

    assert summary.source == {:extension, :leased_callback}
    assert summary.module == module
    assert summary.reason == :tool

    assert :ok = CodeLease.release(lease)

    assert :ok =
             CodeLease.ensure_purge_allowed({:extension, :leased_callback}, module,
               server: ctx.code_lease
             )
  end

  test "purge checks fail closed when lease service is unavailable" do
    assert {:error, {:lease_service_unavailable, :missing_code_lease}} =
             CodeLease.ensure_purge_allowed(
               {:extension, :missing},
               Minga.TestExtensions.MissingLeaseService,
               server: :missing_code_lease
             )

    assert {:error, {:lease_service_unavailable, :missing_code_lease}} =
             CodeLease.purge_module(
               {:extension, :missing},
               Minga.TestExtensions.MissingLeaseService,
               server: :missing_code_lease
             )
  end

  test "owner exit releases leases for provider tool hook mcp and ui action owners", ctx do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    module = Minga.TestExtensions.OwnerReleased

    for reason <- [:provider, :tool, :hook, :mcp, :ui_action] do
      assert {:ok, _lease} =
               CodeLease.lease({:extension, :owner_released}, module, reason,
                 owner: owner,
                 server: ctx.code_lease
               )
    end

    assert length(CodeLease.active_leases(module: module, server: ctx.code_lease)) == 5

    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    assert_eventually_no_leases(module, ctx.code_lease, 20)
  end

  test "registered command callback holds a lease while executing", ctx do
    ext_ctx = start_extension_context()
    callback_name = :"leased_command_callback_#{System.unique_integer([:positive])}"
    Process.register(self(), callback_name)

    {path, cleanup} =
      make_extension("LeasedCommand", """
      defmodule Minga.TestExtensions.LeasedCommand do
        use Minga.Extension

        command :leased_command_run, "Run leased command", execute: {__MODULE__, :run}

        @impl true
        def name, do: :leased_command

        @impl true
        def description, do: "Leased command"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}

        @spec run(map()) :: map()
        def run(state) do
          send(Process.whereis(#{inspect(callback_name)}), {:callback_entered, self()})

          receive do
            :continue -> state
          end
        end
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.LeasedCommand)
      :code.delete(Minga.TestExtensions.LeasedCommand)
    end)

    :ok = ExtRegistry.register(ext_ctx.registry, :leased_command, path, [])
    {:ok, entry} = ExtRegistry.get(ext_ctx.registry, :leased_command)

    assert {:ok, _pid} =
             ExtSupervisor.start_extension(
               ext_ctx.supervisor,
               ext_ctx.registry,
               :leased_command,
               entry,
               command_registry: ext_ctx.command_registry,
               keymap: ext_ctx.keymap,
               code_lease: ctx.code_lease
             )

    {:ok, running_entry} = ExtRegistry.get(ext_ctx.registry, :leased_command)
    {:ok, command} = CommandRegistry.lookup(ext_ctx.command_registry, :leased_command_run)

    task = Task.async(fn -> command.execute.(%{}) end)
    assert_receive {:callback_entered, callback_pid}
    assert_eventually_lease_count(running_entry.module, ctx.code_lease, 1, 20)

    assert {:error, {:leased_modules, [_summary]}} =
             ExtSupervisor.stop_extension(
               ext_ctx.supervisor,
               ext_ctx.registry,
               :leased_command,
               running_entry,
               command_registry: ext_ctx.command_registry,
               keymap: ext_ctx.keymap,
               code_lease: ctx.code_lease
             )

    send(callback_pid, :continue)
    assert %{} = Task.await(task)
    assert_eventually_no_leases(running_entry.module, ctx.code_lease, 20)
  end

  test "extension stop rejects unload while callback module is leased", ctx do
    ext_ctx = start_extension_context()

    {path, cleanup} =
      make_extension("LeasedStop", """
      defmodule Minga.TestExtensions.LeasedStop do
        use Minga.Extension

        @impl true
        def name, do: :leased_stop

        @impl true
        def description, do: "Leased stop"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """)

    on_exit(fn ->
      cleanup.()
      :code.purge(Minga.TestExtensions.LeasedStop)
      :code.delete(Minga.TestExtensions.LeasedStop)
    end)

    :ok = ExtRegistry.register(ext_ctx.registry, :leased_stop, path, [])
    {:ok, entry} = ExtRegistry.get(ext_ctx.registry, :leased_stop)

    assert {:ok, _pid} =
             ExtSupervisor.start_extension(
               ext_ctx.supervisor,
               ext_ctx.registry,
               :leased_stop,
               entry,
               command_registry: ext_ctx.command_registry,
               keymap: ext_ctx.keymap,
               code_lease: ctx.code_lease
             )

    {:ok, running_entry} = ExtRegistry.get(ext_ctx.registry, :leased_stop)

    assert {:ok, lease} =
             CodeLease.lease({:extension, :leased_stop}, running_entry.module, :tool,
               server: ctx.code_lease
             )

    assert {:error, {:leased_modules, [_summary]}} =
             ExtSupervisor.stop_extension(
               ext_ctx.supervisor,
               ext_ctx.registry,
               :leased_stop,
               running_entry,
               command_registry: ext_ctx.command_registry,
               keymap: ext_ctx.keymap,
               code_lease: ctx.code_lease
             )

    {:ok, still_running} = ExtRegistry.get(ext_ctx.registry, :leased_stop)
    assert still_running.status == :running
    assert is_pid(still_running.pid)

    assert :ok = CodeLease.release(lease)

    assert :ok =
             ExtSupervisor.stop_extension(
               ext_ctx.supervisor,
               ext_ctx.registry,
               :leased_stop,
               still_running,
               command_registry: ext_ctx.command_registry,
               keymap: ext_ctx.keymap,
               code_lease: ctx.code_lease
             )

    {:ok, stopped} = ExtRegistry.get(ext_ctx.registry, :leased_stop)
    assert stopped.status == :stopped
    assert stopped.module == nil
  end

  @spec start_extension_context() :: map()
  defp start_extension_context do
    reg_name = :"ext_code_lease_reg_#{System.unique_integer([:positive])}"
    sup_name = :"ext_code_lease_sup_#{System.unique_integer([:positive])}"
    cmd_reg_name = :"ext_code_lease_cmd_#{System.unique_integer([:positive])}"
    keymap_name = :"ext_code_lease_keymap_#{System.unique_integer([:positive])}"

    {:ok, _registry} = ExtRegistry.start_link(name: reg_name)
    {:ok, _supervisor} = ExtSupervisor.start_link(name: sup_name)
    {:ok, _command_registry} = CommandRegistry.start_link(name: cmd_reg_name)
    {:ok, _keymap} = KeymapActive.start_link(name: keymap_name)

    %{
      registry: reg_name,
      supervisor: sup_name,
      command_registry: cmd_reg_name,
      keymap: keymap_name
    }
  end

  @spec assert_eventually_lease_count(
          module(),
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          :ok
  defp assert_eventually_lease_count(module, code_lease, expected, attempts_left) do
    case CodeLease.active_leases(module: module, server: code_lease) do
      leases when length(leases) == expected ->
        :ok

      _leases when attempts_left > 0 ->
        receive do
        after
          10 -> assert_eventually_lease_count(module, code_lease, expected, attempts_left - 1)
        end

      leases ->
        flunk("expected #{expected} lease(s), got #{inspect(leases)}")
    end
  end

  @spec assert_eventually_no_leases(module(), GenServer.server(), non_neg_integer()) :: :ok
  defp assert_eventually_no_leases(module, code_lease, attempts_left) do
    case CodeLease.active_leases(module: module, server: code_lease) do
      [] ->
        :ok

      _leases when attempts_left > 0 ->
        receive do
        after
          10 -> assert_eventually_no_leases(module, code_lease, attempts_left - 1)
        end

      leases ->
        flunk("expected leases to be released, got #{inspect(leases)}")
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
