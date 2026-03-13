defmodule Minga.Extension.RegistryTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Entry
  alias Minga.Extension.Registry

  setup do
    name = :"ext_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Registry.start_link(name: name)
    {:ok, registry: name}
  end

  describe "register/4 (path source)" do
    test "registers a path extension and retrieves it", %{registry: r} do
      :ok = Registry.register(r, :my_ext, "/tmp/my_ext", greeting: "hello")

      assert {:ok, %Entry{} = entry} = Registry.get(r, :my_ext)
      assert entry.source_type == :path
      assert entry.path == "/tmp/my_ext"
      assert entry.config == [greeting: "hello"]
      assert entry.status == :stopped
      assert entry.pid == nil
      assert entry.module == nil
      assert entry.git == nil
      assert entry.hex == nil
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

  describe "register_git/4" do
    test "registers a git extension with defaults", %{registry: r} do
      :ok = Registry.register_git(r, :my_ext, "https://github.com/user/repo", [])

      assert {:ok, %Entry{} = entry} = Registry.get(r, :my_ext)
      assert entry.source_type == :git
      assert entry.git == %{url: "https://github.com/user/repo", branch: nil, ref: nil}
      assert entry.path == nil
      assert entry.hex == nil
      assert entry.config == []
    end

    test "registers a git extension with branch", %{registry: r} do
      :ok = Registry.register_git(r, :my_ext, "https://github.com/user/repo", branch: "develop")

      assert {:ok, entry} = Registry.get(r, :my_ext)
      assert entry.git.branch == "develop"
      assert entry.git.ref == nil
    end

    test "registers a git extension with ref", %{registry: r} do
      :ok = Registry.register_git(r, :my_ext, "git@github.com:user/repo.git", ref: "v1.0.0")

      assert {:ok, entry} = Registry.get(r, :my_ext)
      assert entry.git.url == "git@github.com:user/repo.git"
      assert entry.git.ref == "v1.0.0"
      assert entry.git.branch == nil
    end

    test "passes extra options as config", %{registry: r} do
      :ok =
        Registry.register_git(r, :my_ext, "https://github.com/user/repo",
          branch: "main",
          greeting: "hello"
        )

      assert {:ok, entry} = Registry.get(r, :my_ext)
      assert entry.config == [greeting: "hello"]
    end
  end

  describe "register_hex/4" do
    test "registers a hex extension with version constraint", %{registry: r} do
      :ok = Registry.register_hex(r, :my_ext, "minga_snippets", version: "~> 0.3")

      assert {:ok, %Entry{} = entry} = Registry.get(r, :my_ext)
      assert entry.source_type == :hex
      assert entry.hex == %{package: "minga_snippets", version: "~> 0.3"}
      assert entry.path == nil
      assert entry.git == nil
      assert entry.config == []
    end

    test "registers a hex extension without version (defaults to nil)", %{registry: r} do
      :ok = Registry.register_hex(r, :my_ext, "minga_snippets", [])

      assert {:ok, entry} = Registry.get(r, :my_ext)
      assert entry.hex.version == nil
    end

    test "passes extra options as config", %{registry: r} do
      :ok =
        Registry.register_hex(r, :my_ext, "minga_snippets",
          version: "~> 1.0",
          greeting: "hello"
        )

      assert {:ok, entry} = Registry.get(r, :my_ext)
      assert entry.config == [greeting: "hello"]
    end
  end

  describe "mixed source types" do
    test "all three source types can coexist", %{registry: r} do
      :ok = Registry.register(r, :local_ext, "/tmp/local", [])
      :ok = Registry.register_git(r, :git_ext, "https://github.com/user/repo", [])
      :ok = Registry.register_hex(r, :hex_ext, "minga_tools", version: "~> 1.0")

      entries = Registry.all(r)
      types = entries |> Enum.map(fn {_name, entry} -> entry.source_type end) |> Enum.sort()
      assert types == [:git, :hex, :path]
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

      assert {:ok, %Entry{} = entry} = Registry.get(r, :my_ext)
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
