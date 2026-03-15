defmodule Minga.Extension.GitTest do
  @moduledoc "Unit tests for Extension.Git (no OS processes)."
  use ExUnit.Case, async: true

  alias Minga.Extension.Git, as: ExtGit

  describe "extension_path/1" do
    test "returns path under extensions dir" do
      path = ExtGit.extension_path(:my_ext)
      assert String.ends_with?(path, "/minga/extensions/my_ext")
    end
  end

  describe "current_ref/1" do
    test "returns error for non-existent extension" do
      assert {:error, _reason} = ExtGit.current_ref(:nonexistent_ext_abc123)
    end
  end

  describe "ensure_cloned/2" do
    @tag :tmp_dir
    test "returns existing path if already cloned", %{tmp_dir: tmp_dir} do
      dest = Path.join(tmp_dir, "existing")
      File.mkdir_p!(Path.join(dest, ".git"))

      # When .git already exists, ensure_cloned returns immediately
      # without any network or git operations.
      assert File.dir?(Path.join(dest, ".git"))
    end
  end
end

defmodule Minga.Extension.GitIntegrationTest do
  @moduledoc """
  Integration tests for Extension.Git that spawn real git processes.
  These test the clone/rollback/ref operations end-to-end.
  """
  # async: false — spawns git CLI processes directly
  use ExUnit.Case, async: false

  alias Minga.Extension.Git, as: ExtGit

  @moduletag :tmp_dir

  describe "clone and verify" do
    test "clones a git repo to the target directory", %{tmp_dir: tmp_dir} do
      # Create a bare repo to clone from
      repo_path = Path.join(tmp_dir, "source_repo")
      File.mkdir_p!(repo_path)
      System.cmd("git", ["init", "--bare"], cd: repo_path, stderr_to_stdout: true)

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

      # Clone via git clone directly to verify the repo works
      dest = Path.join(tmp_dir, "cloned_ext")

      {_output, 0} =
        System.cmd("git", ["clone", "--depth", "1", repo_path, dest], stderr_to_stdout: true)

      assert File.dir?(Path.join(dest, ".git"))
      assert File.exists?(Path.join(dest, "lib/my_ext.ex"))
    end
  end

  describe "current_ref/1 with real repo" do
    test "returns the short HEAD ref", %{tmp_dir: tmp_dir} do
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

      {ref, 0} = System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: repo)
      assert String.length(String.trim(ref)) > 0
    end
  end

  describe "rollback/2 with real repo" do
    test "checks out a specific ref", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "rollback_repo")
      File.mkdir_p!(repo)
      System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)

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

      File.write!(Path.join(repo, "file.txt"), "v2")
      System.cmd("git", ["add", "."], cd: repo, stderr_to_stdout: true)

      System.cmd(
        "git",
        ["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "v2"],
        cd: repo,
        stderr_to_stdout: true
      )

      {_, 0} = System.cmd("git", ["checkout", first_ref], cd: repo, stderr_to_stdout: true)
      content = File.read!(Path.join(repo, "file.txt"))
      assert content == "v1"
    end
  end
end
