defmodule Minga.Extension.UpdaterTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Git, as: ExtGit
  alias Minga.Extension.Registry, as: ExtRegistry

  setup do
    name = :"updater_test_registry_#{System.unique_integer([:positive])}"
    {:ok, _} = ExtRegistry.start_link(name: name)
    {:ok, registry: name}
  end

  describe "fetch_updates/2" do
    test "returns error when extension is not cloned" do
      name = :"uncached_ext_#{System.unique_integer([:positive])}"

      result =
        ExtGit.fetch_updates(name, %{
          url: "https://example.com/repo.git",
          branch: nil,
          ref: nil
        })

      assert {:error, msg} = result
      assert msg =~ "not cloned"
    end

    @tag :tmp_dir
    test "pinned ref extensions are always up to date", %{tmp_dir: _tmp_dir} do
      ext_name = :"pinned_test_#{System.unique_integer([:positive])}"
      dest = ExtGit.extension_path(ext_name)
      File.mkdir_p!(Path.join(dest, ".git"))
      on_exit(fn -> File.rm_rf!(dest) end)

      result =
        ExtGit.fetch_updates(ext_name, %{
          url: "https://example.com/repo.git",
          branch: nil,
          ref: "v1.0.0"
        })

      assert :up_to_date = result
    end
  end

  describe "registry entries" do
    test "path extensions have no update mechanism", %{registry: r} do
      ExtRegistry.register(r, :path_ext, "/tmp/ext", [])
      {:ok, entry} = ExtRegistry.get(r, :path_ext)
      assert entry.source_type == :path
    end

    test "hex extensions track package and version", %{registry: r} do
      ExtRegistry.register_hex(r, :hex_ext, "minga_tools", version: "~> 1.0")
      {:ok, entry} = ExtRegistry.get(r, :hex_ext)
      assert entry.source_type == :hex
      assert entry.hex.package == "minga_tools"
    end

    test "git extensions track url and branch", %{registry: r} do
      ExtRegistry.register_git(r, :git_ext, "https://github.com/user/repo", branch: "develop")
      {:ok, entry} = ExtRegistry.get(r, :git_ext)
      assert entry.source_type == :git
      assert entry.git.url == "https://github.com/user/repo"
      assert entry.git.branch == "develop"
    end
  end
end
