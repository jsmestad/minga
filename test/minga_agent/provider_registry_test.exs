defmodule MingaAgent.ProviderRegistryTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ProviderRegistry
  alias MingaAgent.Provider.Spec
  alias MingaAgent.Providers.Native

  setup do
    name = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: name,
      start: {ProviderRegistry, :start_link, [[name: name, seed_builtin?: false]]}
    })

    {:ok, registry: name}
  end

  test "registers and looks up source-owned provider specs", %{registry: registry} do
    spec = spec(id: "custom", source: {:extension, :demo})

    assert :ok = ProviderRegistry.register(registry, spec)
    assert {:ok, entry} = ProviderRegistry.lookup(registry, "custom")
    assert entry.spec == spec
    assert entry.enabled?
  end

  test "same-source registration replaces an existing provider", %{registry: registry} do
    first = spec(id: "custom", source: {:extension, :demo}, display_name: "First")
    second = spec(id: "custom", source: {:extension, :demo}, display_name: "Second")

    assert :ok = ProviderRegistry.register(registry, first)
    assert :ok = ProviderRegistry.register(registry, second)
    assert {:ok, entry} = ProviderRegistry.lookup(registry, "custom")
    assert entry.spec.display_name == "Second"
  end

  test "cross-source duplicate ids fail deterministically", %{registry: registry} do
    assert :ok =
             ProviderRegistry.register(registry, spec(id: "custom", source: {:extension, :first}))

    assert {:error,
            {:duplicate_provider_id, "custom", {:extension, :first}, {:extension, :second}}} =
             ProviderRegistry.register(
               registry,
               spec(id: "custom", source: {:extension, :second})
             )
  end

  test "direct spec structs are validated before registration", %{registry: registry} do
    invalid = %Spec{source: :config, id: "", module: Native, display_name: "Invalid"}

    assert {:error, {:invalid_spec, {:invalid_id, ""}}} =
             ProviderRegistry.register(registry, invalid)

    assert {:error, :not_found} = ProviderRegistry.lookup(registry, "")
  end

  test "disabled providers are rejected by lookup", %{registry: registry} do
    assert :ok = ProviderRegistry.register(registry, spec(id: "custom"))
    assert :ok = ProviderRegistry.disable(registry, "custom")

    assert {:error, :disabled} = ProviderRegistry.lookup(registry, "custom")
    assert {:ok, entry} = ProviderRegistry.get(registry, "custom")
    refute entry.enabled?
  end

  test "unregister_source removes all providers owned by that source", %{registry: registry} do
    source = {:extension, :demo}
    assert :ok = ProviderRegistry.register(registry, spec(id: "one", source: source))
    assert :ok = ProviderRegistry.register(registry, spec(id: "two", source: source))

    assert :ok =
             ProviderRegistry.register(registry, spec(id: "other", source: {:extension, :other}))

    assert :ok = ProviderRegistry.unregister_source(registry, source)

    assert {:error, :not_found} = ProviderRegistry.lookup(registry, "one")
    assert {:error, :not_found} = ProviderRegistry.lookup(registry, "two")
    assert {:ok, _entry} = ProviderRegistry.lookup(registry, "other")
  end

  test "seeds the native built-in provider when requested" do
    name = Module.concat(__MODULE__, "Seeded#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: name,
      start: {ProviderRegistry, :start_link, [[name: name, seed_builtin?: true]]}
    })

    assert {:ok, entry} = ProviderRegistry.lookup(name, "native")
    assert entry.spec.source == :builtin
    assert entry.spec.module == Native
  end

  defp spec(attrs) do
    attrs
    |> Keyword.put_new(:id, "custom")
    |> Keyword.put_new(:source, {:extension, :demo})
    |> Keyword.put_new(:module, Native)
    |> Keyword.put_new(:display_name, "Custom")
    |> Spec.new!()
  end
end
