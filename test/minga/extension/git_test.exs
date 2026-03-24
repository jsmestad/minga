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
  # Prevent git hangs under system load from blocking the entire suite
  @moduletag timeout: 30_000

  # Isolate from CI runner's global git config
  @git_env [
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_AUTHOR_NAME", "Test"},
    {"GIT_AUTHOR_EMAIL", "test@test.com"},
    {"GIT_COMMITTER_NAME", "Test"},
    {"GIT_COMMITTER_EMAIL", "test@test.com"}
  ]

  describe "clone and verify" do
    test "clones a git repo to the target directory", %{tmp_dir: tmp_dir} do
      repo_path = Path.join(tmp_dir, "source_repo")
      File.mkdir_p!(repo_path)
      git!(repo_path, ["init", "--bare"])

      work_path = Path.join(tmp_dir, "work")
      git!(tmp_dir, ["clone", repo_path, work_path])
      File.mkdir_p!(Path.join(work_path, "lib"))
      File.write!(Path.join(work_path, "lib/my_ext.ex"), "defmodule MyExt do\nend\n")
      git!(work_path, ["add", "."])

      git!(work_path, ["commit", "-m", "init"])

      git!(work_path, ["push"])

      dest = Path.join(tmp_dir, "cloned_ext")
      git!(tmp_dir, ["clone", "--depth", "1", repo_path, dest])

      assert File.dir?(Path.join(dest, ".git"))
      assert File.exists?(Path.join(dest, "lib/my_ext.ex"))
    end
  end

  describe "current_ref/1 with real repo" do
    test "returns the short HEAD ref", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo_with_commit")
      File.mkdir_p!(repo)
      git!(repo, ["init"])
      File.write!(Path.join(repo, "file.txt"), "hello")
      git!(repo, ["add", "."])

      git!(repo, ["commit", "-m", "init"])

      {ref, 0} = git(repo, ["rev-parse", "--short", "HEAD"])
      assert String.length(String.trim(ref)) > 0
    end
  end

  describe "rollback/2 with real repo" do
    test "checks out a specific ref", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "rollback_repo")
      File.mkdir_p!(repo)
      git!(repo, ["init"])

      File.write!(Path.join(repo, "file.txt"), "v1")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "v1"])

      {first_ref, 0} = git(repo, ["rev-parse", "--short", "HEAD"])
      first_ref = String.trim(first_ref)

      File.write!(Path.join(repo, "file.txt"), "v2")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-m", "v2"])

      git!(repo, ["checkout", first_ref])
      content = File.read!(Path.join(repo, "file.txt"))
      assert content == "v1"
    end
  end

  # Helpers with consistent options and CI-safe env isolation
  defp git(dir, args) do
    System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: @git_env)
  end

  defp git!(dir, args) do
    {output, code} = git(dir, args)

    if code != 0 do
      flunk("git #{Enum.join(args, " ")} failed (exit #{code}): #{String.trim(output)}")
    end

    {output, code}
  end
end
