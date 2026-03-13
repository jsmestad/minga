defmodule Minga.Extension.UpdaterTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Git, as: ExtGit
  alias Minga.Extension.Registry, as: ExtRegistry

  @moduletag :tmp_dir

  setup do
    name = :"updater_test_registry_#{System.unique_integer([:positive])}"
    {:ok, _} = ExtRegistry.start_link(name: name)
    {:ok, registry: name}
  end

  describe "update_single/1" do
    test "path extensions are always up to date", %{registry: r} do
      ExtRegistry.register(r, :local_ext, "/tmp/nonexistent", [])
      {:ok, entry} = ExtRegistry.get(r, :local_ext)
      assert entry.source_type == :path
    end
  end

  describe "update flow integration" do
    test "git update handles missing clone gracefully", %{tmp_dir: tmp_dir} do
      # Create a repo with one commit (simulating a cloned extension)
      repo = Path.join(tmp_dir, "ext_repo")
      File.mkdir_p!(Path.join(repo, "lib"))
      System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)
      File.write!(Path.join(repo, "lib/ext.ex"), "defmodule Ext do\nend\n")
      System.cmd("git", ["add", "."], cd: repo, stderr_to_stdout: true)

      System.cmd(
        "git",
        ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init"],
        cd: repo,
        stderr_to_stdout: true
      )

      # The extension_path doesn't exist yet, so fetch_updates returns error
      result =
        ExtGit.fetch_updates(:test_ext, %{
          url: repo,
          branch: nil,
          ref: nil
        })

      assert {:error, _} = result
    end

    test "pinned ref extensions are always up to date", %{tmp_dir: tmp_dir} do
      # Create and clone a repo, then check that pinned refs skip fetch
      bare = Path.join(tmp_dir, "bare")
      work = Path.join(tmp_dir, "work")
      File.mkdir_p!(bare)
      System.cmd("git", ["init", "--bare"], cd: bare, stderr_to_stdout: true)
      System.cmd("git", ["clone", bare, work], stderr_to_stdout: true)
      File.write!(Path.join(work, "f.txt"), "hi")
      System.cmd("git", ["add", "."], cd: work, stderr_to_stdout: true)

      System.cmd(
        "git",
        ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init"],
        cd: work,
        stderr_to_stdout: true
      )

      System.cmd("git", ["push"], cd: work, stderr_to_stdout: true)

      # Clone to the extension cache path
      dest = ExtGit.extension_path(:pinned_test)
      File.mkdir_p!(Path.dirname(dest))
      System.cmd("git", ["clone", bare, dest], stderr_to_stdout: true)

      # Fetch with pinned ref always returns :up_to_date
      result =
        ExtGit.fetch_updates(:pinned_test, %{
          url: bare,
          branch: nil,
          ref: "abc123"
        })

      assert :up_to_date = result
    after
      # Clean up the extension path we created
      dest = ExtGit.extension_path(:pinned_test)
      File.rm_rf!(dest)
    end
  end

  describe "registry entries for different source types" do
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
      assert entry.hex.version == "~> 1.0"
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
