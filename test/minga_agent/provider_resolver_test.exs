defmodule MingaAgent.ProviderResolverTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ProviderResolver
  alias MingaAgent.Providers.Native
  alias MingaAgent.Providers.PiRpc

  describe "resolve/1" do
    test "returns Native for :native preference" do
      result = ProviderResolver.resolve(:native)
      assert result.module == Native
      assert result.name == "native"
    end

    test "returns PiRpc for :pi_rpc preference" do
      result = ProviderResolver.resolve(:pi_rpc)
      assert result.module == PiRpc
      assert result.name == "pi_rpc"
    end

    test "returns a valid provider for :auto" do
      result = ProviderResolver.resolve(:auto)
      assert result.module in [Native, PiRpc]
      assert is_binary(result.name)
    end
  end

  describe "resolve/0" do
    test "uses test_provider_module override when configured" do
      # test.exs sets :test_provider_module, so resolve/0 returns it
      override = Application.get_env(:minga, :test_provider_module)
      assert override != nil, "expected :test_provider_module to be set in test config"

      result = ProviderResolver.resolve()
      assert result.module == override
      assert result.name == "test"
    end

    test "falls back to real resolution when no override is set" do
      # Temporarily clear the override to test the real resolution path
      override = Application.get_env(:minga, :test_provider_module)
      Application.delete_env(:minga, :test_provider_module)

      try do
        result = ProviderResolver.resolve()
        assert result.module in [Native, PiRpc]
        assert is_binary(result.name)
      after
        # Restore the override for other tests
        if override, do: Application.put_env(:minga, :test_provider_module, override)
      end
    end
  end
end
