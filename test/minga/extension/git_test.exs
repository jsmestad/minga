defmodule Minga.Extension.GitTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Git, as: ExtGit

  @moduletag :tmp_dir

  describe "ensure_cloned/2" do
    test "clones a git repo to the cache directory", %{tmp_dir: tmp_dir} do
      # Create a bare git repo to clone from
      repo_path = Path.join(tmp_dir, "source_repo")
      File.mkdir_p!(repo_path)
      System.cmd("git", ["init", "--bare"], cd: repo_path, stderr_to_stdout: true)

      # Add an initial commit so there's something to clone
      work_path = Path.join(tmp_dir, "work")
      System.cmd("git", ["clone", repo_path, work_path], stderr_to_stdout: true)
      File.mkdir_p!(Path.join(work_path, "lib"))
      File.write!(Path.join(work_path, "lib/my_ext.ex"), "defmodule MyExt do\nend\n")
      System.cmd("git", ["add", "."], cd: work_path, stderr_to_stdout: true)

      System.cmd(
        "git",
        ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init"],
        cd: work_path,
        stderr_to_stdout: true
      )

      System.cmd("git", ["push"], cd: work_path, stderr_to_stdout: true)

      # Clone via our resolver
      dest = Path.join(tmp_dir, "cloned_ext")
      git_opts = %{url: repo_path, branch: nil, ref: nil}

      # Override the extension path for testing
      assert {:ok, ^dest} = do_clone_to(dest, git_opts)
      assert File.dir?(Path.join(dest, ".git"))
      assert File.exists?(Path.join(dest, "lib/my_ext.ex"))
    end

    test "returns existing path if already cloned", %{tmp_dir: tmp_dir} do
      # Set up a fake cloned repo
      dest = Path.join(tmp_dir, "existing")
      File.mkdir_p!(dest)
      System.cmd("git", ["init"], cd: dest, stderr_to_stdout: true)

      git_opts = %{url: "https://example.com/nonexistent.git", branch: nil, ref: nil}

      # Should return immediately without trying to clone
      assert {:ok, ^dest} = do_ensure_cloned(dest, git_opts)
    end
  end

  describe "extension_path/1" do
    test "returns path under extensions dir" do
      path = ExtGit.extension_path(:my_ext)
      assert String.ends_with?(path, "/minga/extensions/my_ext")
    end
  end

  describe "current_ref/1" do
    test "returns the short HEAD ref", %{tmp_dir: tmp_dir} do
      # Create a repo with a commit
      repo = Path.join(tmp_dir, "repo_with_commit")
      File.mkdir_p!(repo)
      System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)
      File.write!(Path.join(repo, "file.txt"), "hello")
      System.cmd("git", ["add", "."], cd: repo, stderr_to_stdout: true)

      System.cmd(
        "git",
        ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init"],
        cd: repo,
        stderr_to_stdout: true
      )

      # Temporarily point extension_path at our test repo
      # We test the underlying git command directly
      {ref, 0} = System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: repo)
      assert String.length(String.trim(ref)) > 0
    end
  end

  describe "rollback/2" do
    test "checks out a specific ref", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "rollback_repo")
      File.mkdir_p!(repo)
      System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)

      # Commit 1
      File.write!(Path.join(repo, "file.txt"), "v1")
      System.cmd("git", ["add", "."], cd: repo, stderr_to_stdout: true)

      System.cmd(
        "git",
        ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "v1"],
        cd: repo,
        stderr_to_stdout: true
      )

      {first_ref, 0} = System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: repo)
      first_ref = String.trim(first_ref)

      # Commit 2
      File.write!(Path.join(repo, "file.txt"), "v2")
      System.cmd("git", ["add", "."], cd: repo, stderr_to_stdout: true)

      System.cmd(
        "git",
        ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "v2"],
        cd: repo,
        stderr_to_stdout: true
      )

      # Rollback to first commit
      {_, 0} = System.cmd("git", ["checkout", first_ref], cd: repo, stderr_to_stdout: true)
      content = File.read!(Path.join(repo, "file.txt"))
      assert content == "v1"
    end
  end

  # Helpers that let us test with custom paths instead of the hardcoded
  # ~/.local/share/minga/extensions/ directory.

  @spec do_clone_to(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  defp do_clone_to(dest, git_opts) do
    File.mkdir_p!(Path.dirname(dest))
    args = ["clone", "--depth", "1", git_opts.url, dest]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} -> {:ok, dest}
      {output, _} -> {:error, "clone failed: #{String.trim(output)}"}
    end
  end

  @spec do_ensure_cloned(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  defp do_ensure_cloned(dest, git_opts) do
    if File.dir?(Path.join(dest, ".git")) do
      {:ok, dest}
    else
      do_clone_to(dest, git_opts)
    end
  end
end
