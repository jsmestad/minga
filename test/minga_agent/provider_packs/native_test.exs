defmodule MingaAgent.ProviderPacks.NativeTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ProviderPacks.Native, as: NativeProviderPack
  alias MingaAgent.ProviderRegistry
  alias MingaAgent.Providers.Native

  setup do
    registry = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: registry,
      start: {ProviderRegistry, :start_link, [[name: registry, seed_builtin?: false]]}
    })

    {:ok, registry: registry}
  end

  test "spec declares the existing native provider as a bundled source-owned provider" do
    spec = NativeProviderPack.spec()

    assert spec.source == {:bundle, :native_provider}
    assert spec.id == "native"
    assert spec.module == Native
    assert spec.model_prefixes == ["anthropic:", "openai:", "ollama:", "groq:", "bedrock:"]
    assert :streaming in spec.capabilities
    assert :model_switching in spec.capabilities
    assert spec.credential_requirements == [:llm]
  end

  test "registers the native provider through the provider registry", %{registry: registry} do
    assert :ok = NativeProviderPack.register(registry)

    assert {:ok, entry} = ProviderRegistry.lookup(registry, "native")
    assert entry.enabled?
    assert entry.spec.source == NativeProviderPack.source()
    assert entry.spec.module == Native
  end

  test "pack startup contributes the native provider", %{registry: registry} do
    pack = Module.concat(__MODULE__, "Pack#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: pack,
      start: {NativeProviderPack, :start_link, [[name: pack, registry: registry]]}
    })

    assert {:ok, entry} = ProviderRegistry.lookup(registry, "native")
    assert entry.spec.source == NativeProviderPack.source()
  end

  test "cleanup unregisters the bundled provider for new sessions", %{registry: registry} do
    assert :ok = NativeProviderPack.register(registry)
    assert :ok = ProviderRegistry.unregister_source(registry, NativeProviderPack.source())

    assert {:error, :not_found} = ProviderRegistry.lookup(registry, "native")
  end
end
