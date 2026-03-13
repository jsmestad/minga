defmodule Minga.Extension.HexTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Hex, as: ExtHex
  alias Minga.Extension.Registry, as: ExtRegistry

  setup do
    name = :"hex_test_registry_#{System.unique_integer([:positive])}"
    {:ok, _} = ExtRegistry.start_link(name: name)
    {:ok, registry: name}
  end

  describe "collect_hex_deps/1" do
    test "returns empty list when no hex extensions", %{registry: r} do
      ExtRegistry.register(r, :local_ext, "/tmp/ext", [])
      assert ExtHex.collect_hex_deps(r) == []
    end

    test "collects hex deps with version constraints", %{registry: r} do
      ExtRegistry.register_hex(r, :snippets, "minga_snippets", version: "~> 0.3")
      ExtRegistry.register_hex(r, :tools, "minga_tools", version: ">= 1.0.0")

      deps = ExtHex.collect_hex_deps(r) |> Enum.sort()

      assert deps == [
               {:minga_snippets, "~> 0.3"},
               {:minga_tools, ">= 1.0.0"}
             ]
    end

    test "uses >= 0.0.0 for extensions without version constraint", %{registry: r} do
      ExtRegistry.register_hex(r, :snippets, "minga_snippets", [])

      deps = ExtHex.collect_hex_deps(r)
      assert deps == [{:minga_snippets, ">= 0.0.0"}]
    end

    test "ignores path and git extensions", %{registry: r} do
      ExtRegistry.register(r, :local, "/tmp/ext", [])
      ExtRegistry.register_git(r, :git_ext, "https://github.com/user/repo", [])
      ExtRegistry.register_hex(r, :hex_ext, "minga_snippets", version: "~> 0.3")

      deps = ExtHex.collect_hex_deps(r)
      assert deps == [{:minga_snippets, "~> 0.3"}]
    end
  end

  describe "install_all/1" do
    test "returns :ok when no hex extensions registered", %{registry: r} do
      assert :ok = ExtHex.install_all(r)
    end

    test "returns :ok when only path extensions registered", %{registry: r} do
      ExtRegistry.register(r, :local, "/tmp/ext", [])
      assert :ok = ExtHex.install_all(r)
    end

    # NOTE: We can't test actual Mix.install/2 inside a Mix project.
    # The release-level integration test (via `minga eval`) in
    # application_config_test.exs covers the real Mix.install path.
  end
end
