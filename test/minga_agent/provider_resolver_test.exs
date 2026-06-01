defmodule MingaAgent.ProviderResolverTest do
  # Mutates the global :minga Application env to exercise provider resolution without the test override.
  use ExUnit.Case, async: false

  alias MingaAgent.ProviderRegistry
  alias MingaAgent.ProviderResolver
  alias MingaAgent.Providers.Native

  describe "resolve/1" do
    test "returns Native for :native preference" do
      result = ProviderResolver.resolve(:native)
      assert result.id == "native"
      assert result.source == :builtin
      assert result.module == Native
      assert result.name == "native"
    end

    test "returns Native for :auto preference" do
      result = ProviderResolver.resolve(:auto)
      assert result.id == "native"
      assert result.source == :builtin
      assert result.module == Native
      assert result.name == "native (auto)"
    end

    test "returns registered provider ids" do
      registry = start_registry!()

      assert :ok =
               ProviderRegistry.register(registry,
                 id: "demo",
                 source: {:extension, :demo},
                 module: Native,
                 display_name: "Demo Provider"
               )

      result = ProviderResolver.resolve("demo", registry: registry)
      assert result.id == "demo"
      assert result.source == {:extension, :demo}
      assert result.module == Native
      assert result.name == "demo"
      assert result.display_name == "Demo Provider"
    end

    test "rejects disabled registered provider ids" do
      registry = start_registry!()

      assert :ok =
               ProviderRegistry.register(registry,
                 id: "demo",
                 source: :config,
                 module: Native,
                 display_name: "Demo"
               )

      assert :ok = ProviderRegistry.disable(registry, "demo")

      assert_raise ArgumentError, ~r/not available: :disabled/, fn ->
        ProviderResolver.resolve("demo", registry: registry)
      end
    end
  end

  describe "resolve/0" do
    test "uses test_provider_module override when configured" do
      # test.exs sets :test_provider_module, so resolve/0 returns it
      override = Application.get_env(:minga, :test_provider_module)
      assert override != nil, "expected :test_provider_module to be set in test config"

      result = ProviderResolver.resolve()
      assert result.id == "test"
      assert result.source == :config
      assert result.module == override
      assert result.name == "test"
    end

    test "falls back to real resolution when no override is set" do
      # Temporarily clear the override to test the real resolution path
      override = Application.get_env(:minga, :test_provider_module)
      Application.delete_env(:minga, :test_provider_module)

      try do
        result = ProviderResolver.resolve()
        assert result.id == "native"
        assert result.source == :builtin
        assert result.module == Native
        assert result.name == "native (auto)"
      after
        # Restore the override for other tests
        if override, do: Application.put_env(:minga, :test_provider_module, override)
      end
    end
  end

  defp start_registry! do
    name = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: name,
      start: {ProviderRegistry, :start_link, [[name: name, seed_builtin?: true]]}
    })

    name
  end
end
