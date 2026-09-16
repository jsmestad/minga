defmodule MingaAgent.SessionSourceLeaseTest do
  use Minga.Test.SessionCase, async: true

  defmodule ControlledStopProvider do
    @behaviour MingaAgent.Provider

    @impl MingaAgent.Provider
    def start_link(opts) do
      caller = self()
      test_pid = Keyword.fetch!(opts, :test_pid)
      mode = Keyword.fetch!(opts, :stop_mode)

      pid =
        spawn_link(fn ->
          Process.flag(:trap_exit, true)
          send(caller, {:controlled_provider_ready, self()})
          send(test_pid, {:controlled_provider_started, self()})
          provider_loop(test_pid, mode)
        end)

      receive do
        {:controlled_provider_ready, ^pid} -> {:ok, pid}
      end
    end

    @impl MingaAgent.Provider
    def send_prompt(_pid, _text), do: :ok

    @impl MingaAgent.Provider
    def abort(_pid), do: :ok

    @impl MingaAgent.Provider
    def new_session(_pid), do: :ok

    @impl MingaAgent.Provider
    def seed_messages(_pid, _messages), do: :ok

    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: nil}}

    defp provider_loop(test_pid, mode) do
      receive do
        {:EXIT, _from, :shutdown} ->
          send(test_pid, {:controlled_provider_shutdown, self(), mode})
          provider_loop(test_pid, mode)

        :allow_stop when mode == :cooperative ->
          :ok
      end
    end
  end

  describe "source-owned provider leases" do
    test "active sessions keep extension provider modules leased" do
      assert_provider_source_leased({:extension, :lease_provider_test})
    end

    test "active sessions keep bundled provider modules leased" do
      assert_provider_source_leased({:bundle, :lease_provider_test})
    end

    test "cooperative stop keeps the lease until the monitored provider terminates" do
      assert_ordered_provider_stop(:cooperative)
    end

    test "the stop deadline kills an uncooperative provider before releasing its lease" do
      assert_ordered_provider_stop(:ignore_shutdown)
    end
  end

  @spec assert_ordered_provider_stop(:cooperative | :ignore_shutdown) :: :ok
  defp assert_ordered_provider_stop(mode) do
    source = {:extension, ordered_stop_source(mode)}
    provider_id = "ordered-stop-#{System.unique_integer([:positive])}"

    assert :ok =
             ProviderRegistry.register(
               id: provider_id,
               source: source,
               module: ControlledStopProvider,
               display_name: "Controlled Stop Provider"
             )

    on_exit(fn -> ProviderRegistry.unregister_source(source) end)

    session =
      start_test_session(
        provider: ControlledStopProvider,
        provider_id: provider_id,
        provider_source: source,
        provider_opts: [test_pid: self(), stop_mode: mode]
      )

    assert_receive {:controlled_provider_started, provider}
    assert [_lease] = CodeLease.active_leases(source: source, module: ControlledStopProvider)

    provider_ref = Process.monitor(provider)
    session_ref = Process.monitor(session)
    stopper = Task.async(fn -> GenServer.stop(session) end)

    assert_receive {:controlled_provider_shutdown, ^provider, ^mode}
    assert Process.alive?(provider)
    assert [_lease] = CodeLease.active_leases(source: source, module: ControlledStopProvider)

    if mode == :cooperative, do: send(provider, :allow_stop)

    expected_reason = if mode == :cooperative, do: :normal, else: :killed
    assert_receive {:DOWN, ^provider_ref, :process, ^provider, ^expected_reason}, 2_000
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}
    assert :ok = Task.await(stopper)
    assert [] = CodeLease.active_leases(source: source, module: ControlledStopProvider)

    :ok
  end

  defp ordered_stop_source(:cooperative), do: :ordered_provider_stop_cooperative
  defp ordered_stop_source(:ignore_shutdown), do: :ordered_provider_stop_ignore_shutdown

  @spec assert_provider_source_leased(Minga.Extension.ContributionCleanup.contribution_source()) ::
          :ok
  defp assert_provider_source_leased(source) do
    provider_id = "leased-#{System.unique_integer([:positive])}"

    assert :ok =
             ProviderRegistry.register(
               id: provider_id,
               source: source,
               module: Minga.Test.SessionSlowMockProvider,
               display_name: "Leased Provider"
             )

    on_exit(fn -> ProviderRegistry.unregister_source(source) end)

    session =
      start_test_session(
        provider: Minga.Test.SessionSlowMockProvider,
        provider_id: provider_id,
        provider_source: source,
        provider_opts: []
      )

    assert [lease] =
             CodeLease.active_leases(source: source, module: Minga.Test.SessionSlowMockProvider)

    assert lease.reason == :provider

    session_ref = Process.monitor(session)
    GenServer.stop(session)
    assert_receive {:DOWN, ^session_ref, :process, ^session, _reason}

    assert [] =
             CodeLease.active_leases(source: source, module: Minga.Test.SessionSlowMockProvider)

    :ok
  end
end
