defmodule Minga.ApplicationConfigTest do
  @moduledoc """
  Tests that the application is configured correctly for runtime
  extension loading via Mix.install/2 inside Burrito releases.

  These tests verify the mix.exs settings that make dynamic code
  loading work: Mix availability, required OTP applications, and
  protocol consolidation configuration.
  """

  use ExUnit.Case, async: true

  describe "Mix runtime support" do
    test "Mix module is loaded and available" do
      assert Code.ensure_loaded?(Mix)
    end

    test "Mix.install/2 function exists" do
      assert function_exported?(Mix, :install, 2)
    end

    test "Mix.install/1 function exists" do
      assert function_exported?(Mix, :install, 1)
    end
  end

  describe "extra_applications includes required OTP apps" do
    setup do
      apps = Application.spec(:minga, :applications) || []
      {:ok, apps: apps}
    end

    test "includes :mix for runtime package installation", %{apps: apps} do
      assert :mix in apps
    end

    test "includes :inets for HTTP client (Hex API)", %{apps: apps} do
      assert :inets in apps
    end

    test "includes :ssl for HTTPS connections to Hex", %{apps: apps} do
      assert :ssl in apps
    end

    test "includes :public_key for TLS certificate verification", %{apps: apps} do
      assert :public_key in apps
    end

    test "includes :parsetools for extensions that use leex/yecc", %{apps: apps} do
      assert :parsetools in apps
    end

    test "includes :compiler for extension compilation", %{apps: apps} do
      assert :compiler in apps
    end

    test "includes :syntax_tools for code analysis during compilation", %{apps: apps} do
      assert :syntax_tools in apps
    end

    test "includes :xmerl for extensions that parse XML", %{apps: apps} do
      assert :xmerl in apps
    end
  end

  describe "required OTP applications are startable" do
    @required_apps [
      :mix,
      :inets,
      :ssl,
      :public_key,
      :parsetools,
      :compiler,
      :syntax_tools,
      :xmerl
    ]

    for app <- @required_apps do
      test "#{app} can be started" do
        assert match?({:ok, _}, Application.ensure_all_started(unquote(app)))
      end
    end
  end

  describe "protocol consolidation" do
    test "consolidation is disabled in prod builds (Mix.env() != :prod)" do
      config = Mix.Project.config()
      consolidate = config[:consolidate_protocols]

      # In test env this evaluates to true (test != prod), but the
      # important thing is the expression in mix.exs uses Mix.env().
      # In prod, it evaluates to false, disabling consolidation so
      # dynamically loaded extension code can implement protocols.
      assert consolidate == (Mix.env() != :prod)
    end

    test "consolidation is enabled in test env" do
      # In dev/test, protocols are consolidated for fast dispatch.
      # In prod, mix.exs sets `consolidate_protocols: Mix.env() != :prod`
      # which evaluates to false, allowing dynamically loaded extension
      # code to implement protocols at runtime.
      assert Mix.Project.config()[:consolidate_protocols] == true
    end
  end
end
