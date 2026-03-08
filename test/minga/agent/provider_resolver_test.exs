defmodule Minga.Agent.ProviderResolverTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.ProviderResolver
  alias Minga.Agent.Providers.Native
  alias Minga.Agent.Providers.PiRpc

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
    test "returns a valid provider when config agent is not running" do
      # When the Options agent isn't started, resolve/0 should still work
      # by falling back to :auto
      result = ProviderResolver.resolve()
      assert result.module in [Native, PiRpc]
    end
  end
end
