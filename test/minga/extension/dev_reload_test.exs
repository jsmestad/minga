defmodule Minga.Extension.DevReloadTest do
  # Uses global extension registry/supervisor because DevReload targets singleton servers.
  use ExUnit.Case, async: false

  alias Minga.Extension.DevReload
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor

  setup do
    ensure_named_process(ExtRegistry, {ExtRegistry, name: ExtRegistry})
    ensure_named_process(ExtSupervisor, {ExtSupervisor, name: ExtSupervisor})
    :ok = ExtRegistry.unregister(ExtRegistry, :dev_reload_contract)

    on_exit(fn ->
      case ExtRegistry.get(ExtRegistry, :dev_reload_contract) do
        {:ok, entry} ->
          ExtSupervisor.stop_extension(ExtSupervisor, ExtRegistry, :dev_reload_contract, entry)

        :error ->
          :ok
      end

      ExtRegistry.unregister(ExtRegistry, :dev_reload_contract)
      :code.purge(Minga.TestExtensions.DevReloadContract)
      :code.delete(Minga.TestExtensions.DevReloadContract)
    end)

    :ok
  end

  test "starts without error" do
    pid = start_supervised!(DevReload)
    assert is_pid(pid)
  end

  test "watch and unwatch do not crash" do
    start_supervised!(DevReload)

    assert :ok = DevReload.watch(:test_ext, System.tmp_dir!())
    assert :ok = DevReload.unwatch(:test_ext)
  end

  test "debounced reload with no pending paths is a no-op" do
    pid = start_supervised!(DevReload)
    send(pid, :debounced_reload)
    state = :sys.get_state(pid)
    assert state.pending_paths == MapSet.new()
  end

  test "debounced reload emits reload telemetry and restarts the extension in order" do
    test_pid = self()

    pid =
      start_supervised!(
        {DevReload,
         recompiler: fn path ->
           send(test_pid, {:reload_event, {:recompiled, path}})
           :ok
         end}
      )

    telemetry_id = {__MODULE__, self(), :dev_reload_contract}

    {path, cleanup} = make_reload_extension()
    on_exit(cleanup)

    :ok = ExtRegistry.register(ExtRegistry, :dev_reload_contract, path, [])
    {:ok, entry} = ExtRegistry.get(ExtRegistry, :dev_reload_contract)

    assert {:ok, old_pid} =
             ExtSupervisor.start_extension(
               ExtSupervisor,
               ExtRegistry,
               :dev_reload_contract,
               entry
             )

    :telemetry.attach(
      telemetry_id,
      [:minga, :extension, :lifecycle, :stop],
      fn _event, _measurements, metadata, test_pid ->
        case metadata do
          %{extension: :dev_reload_contract, phase: phase} ->
            send(test_pid, {:reload_event, phase})

          _other ->
            :ok
        end
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    lib_path = Path.join(path, "lib")
    source_file = Path.join(lib_path, "extension.ex")

    :sys.replace_state(pid, fn state ->
      %{
        state
        | extensions: Map.put(state.extensions, lib_path, :dev_reload_contract),
          pending_paths: MapSet.new([source_file]),
          pending_timer: nil
      }
    end)

    send(pid, :debounced_reload)

    assert_reload_event({:recompiled, path})
    assert_reload_event(:stop)
    assert_reload_event(:cleanup)
    assert_reload_event(:load)
    assert_reload_event(:init)
    assert_reload_event(:child_start)
    assert_reload_event(:reload)

    {:ok, reloaded_entry} = ExtRegistry.get(ExtRegistry, :dev_reload_contract)
    assert reloaded_entry.status == :running
    assert is_pid(reloaded_entry.pid)
    assert reloaded_entry.pid != old_pid
  end

  @spec assert_reload_event(atom() | {:recompiled, String.t()}) ::
          atom() | {:recompiled, String.t()}
  defp assert_reload_event(expected) do
    receive do
      {:reload_event, ^expected} -> expected
      other -> flunk("expected reload event #{inspect(expected)}, got #{inspect(other)}")
    after
      1_000 -> flunk("expected reload event #{inspect(expected)}")
    end
  end

  @spec ensure_named_process(atom(), Supervisor.child_spec()) :: :ok
  defp ensure_named_process(name, child_spec) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> :ok
      nil -> start_supervised!(child_spec) && :ok
    end
  end

  @spec make_reload_extension() :: {String.t(), (-> :ok)}
  defp make_reload_extension do
    dir = Path.join(System.tmp_dir!(), "minga_dev_reload_#{System.unique_integer([:positive])}")
    lib_dir = Path.join(dir, "lib")
    File.mkdir_p!(lib_dir)

    File.write!(Path.join(lib_dir, "extension.ex"), """
    defmodule Minga.TestExtensions.DevReloadContract do
      use Minga.Extension

      @impl true
      def name, do: :dev_reload_contract

      @impl true
      def description, do: "Dev reload contract"

      @impl true
      def version, do: "1.0.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end
    """)

    {dir, fn -> File.rm_rf!(dir) end}
  end
end
