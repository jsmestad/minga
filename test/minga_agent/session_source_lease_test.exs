defmodule MingaAgent.SessionSourceLeaseTest do
  use Minga.Test.SessionCase, async: true

  describe "source-owned provider leases" do
    test "active sessions keep extension provider modules leased" do
      assert_provider_source_leased({:extension, :lease_provider_test})
    end

    test "active sessions keep bundled provider modules leased" do
      assert_provider_source_leased({:bundle, :lease_provider_test})
    end
  end

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

    :sys.get_state(session)

    assert [lease] =
             CodeLease.active_leases(source: source, module: Minga.Test.SessionSlowMockProvider)

    assert lease.reason == :provider

    GenServer.stop(session)

    assert [] =
             CodeLease.active_leases(source: source, module: Minga.Test.SessionSlowMockProvider)

    :ok
  end
end
