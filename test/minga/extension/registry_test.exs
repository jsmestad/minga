defmodule Minga.Extension.RegistryTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Registry

  setup do
    name = :"ext_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Registry.start_link(name: name)
    {:ok, registry: name}
  end

  describe "register/4 and get/2" do
    test "registers an extension and retrieves it", %{registry: r} do
      :ok = Registry.register(r, :my_ext, "/tmp/my_ext", greeting: "hello")

      assert {:ok, entry} = Registry.get(r, :my_ext)
      assert entry.path == "/tmp/my_ext"
      assert entry.config == [greeting: "hello"]
      assert entry.status == :stopped
      assert entry.pid == nil
      assert entry.module == nil
    end

    test "returns :error for unregistered extension", %{registry: r} do
      assert :error = Registry.get(r, :nonexistent)
    end

    test "overwrites existing registration", %{registry: r} do
      :ok = Registry.register(r, :my_ext, "/tmp/v1", [])
      :ok = Registry.register(r, :my_ext, "/tmp/v2", [])

      assert {:ok, entry} = Registry.get(r, :my_ext)
      assert entry.path == "/tmp/v2"
    end
  end

  describe "unregister/2" do
    test "removes a registered extension", %{registry: r} do
      :ok = Registry.register(r, :my_ext, "/tmp/ext", [])
      :ok = Registry.unregister(r, :my_ext)

      assert :error = Registry.get(r, :my_ext)
    end

    test "no-op for unregistered name", %{registry: r} do
      :ok = Registry.unregister(r, :nonexistent)
    end
  end

  describe "all/1" do
    test "returns empty list when no extensions registered", %{registry: r} do
      assert Registry.all(r) == []
    end

    test "returns all registered extensions", %{registry: r} do
      :ok = Registry.register(r, :ext_a, "/tmp/a", [])
      :ok = Registry.register(r, :ext_b, "/tmp/b", [])

      entries = Registry.all(r)
      names = Enum.map(entries, &elem(&1, 0)) |> Enum.sort()
      assert names == [:ext_a, :ext_b]
    end
  end

  describe "update/3" do
    test "updates fields on an existing entry", %{registry: r} do
      :ok = Registry.register(r, :my_ext, "/tmp/ext", [])
      :ok = Registry.update(r, :my_ext, status: :running, pid: self())

      assert {:ok, entry} = Registry.get(r, :my_ext)
      assert entry.status == :running
      assert entry.pid == self()
      assert entry.path == "/tmp/ext"
    end

    test "no-op for nonexistent extension", %{registry: r} do
      :ok = Registry.update(r, :nonexistent, status: :running)
      assert :error = Registry.get(r, :nonexistent)
    end
  end

  describe "reset/1" do
    test "clears all extensions", %{registry: r} do
      :ok = Registry.register(r, :ext_a, "/tmp/a", [])
      :ok = Registry.register(r, :ext_b, "/tmp/b", [])
      :ok = Registry.reset(r)

      assert Registry.all(r) == []
    end
  end
end
