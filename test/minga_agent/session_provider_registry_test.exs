defmodule MingaAgent.SessionProviderRegistryTest do
  # Mutates global provider registry and :minga Application env to verify production default-provider resolution.
  use ExUnit.Case, async: false

  alias Minga.Extension.CodeLease
  alias MingaAgent.ProviderPacks.Native, as: NativeProviderPack
  alias MingaAgent.ProviderRegistry
  alias MingaAgent.Session

  defmodule RegistryProvider do
    @behaviour MingaAgent.Provider

    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl MingaAgent.Provider
    def send_prompt(_pid, _text), do: :ok

    @impl MingaAgent.Provider
    def abort(_pid), do: :ok

    @impl MingaAgent.Provider
    def new_session(_pid), do: :ok

    @impl MingaAgent.Provider
    def seed_messages(_pid, _messages), do: :ok

    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: nil, is_streaming: false, token_usage: nil}}

    @impl GenServer
    def init(opts), do: {:ok, opts}
  end

  setup do
    override = Application.get_env(:minga, :test_provider_module)
    trap_exit? = Process.flag(:trap_exit, true)

    on_exit(fn ->
      Process.flag(:trap_exit, trap_exit?)
      restore_test_provider_module(override)
      ProviderRegistry.unregister_source(NativeProviderPack.source())
      NativeProviderPack.register()
    end)

    :ok
  end

  test "default native sessions fail through the registry when the bundled provider is removed" do
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    Application.delete_env(:minga, :test_provider_module)
    ProviderRegistry.unregister_source(NativeProviderPack.source())

    assert {:error, {%ArgumentError{message: message}, _stack}} =
             Session.start_link(
               model_name: "anthropic:test",
               provider_opts: [provider: "anthropic", model: "anthropic:test"],
               persist?: false
             )

    assert message =~ ~s(agent provider "native" is not available: :not_found)
  end

  test "source-owned sessions do not restart providers after source cleanup" do
    source = {:extension, :session_provider_registry_test}
    provider_id = "registry-provider-#{System.unique_integer([:positive])}"

    assert :ok =
             ProviderRegistry.register(
               id: provider_id,
               source: source,
               module: RegistryProvider,
               display_name: "Registry Provider"
             )

    {:ok, session} =
      Session.start_link(
        provider: RegistryProvider,
        provider_id: provider_id,
        provider_source: source,
        provider_opts: [],
        persist?: false
      )

    provider = Session.get_provider(session)
    assert is_pid(provider)
    assert [_lease] = CodeLease.active_leases(source: source, module: RegistryProvider)

    assert :ok = ProviderRegistry.unregister_source(source)
    provider_ref = Process.monitor(provider)
    GenServer.stop(provider, :normal)
    assert_receive {:DOWN, ^provider_ref, :process, ^provider, :normal}
    :sys.get_state(session)

    send(session, :start_provider)
    :sys.get_state(session)
    snapshot = Session.editor_snapshot(session)

    assert Session.get_provider(session) == nil
    assert snapshot.status == :error
    assert snapshot.error =~ "provider_not_found"
    assert snapshot.error =~ provider_id
    assert [] = CodeLease.active_leases(source: source, module: RegistryProvider)
  end

  defp restore_test_provider_module(nil),
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    do: Application.delete_env(:minga, :test_provider_module)

  defp restore_test_provider_module(module),
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    do: Application.put_env(:minga, :test_provider_module, module)
end
