defmodule Minga.Git.BackendOperationsTest do
  @moduledoc """
  Tests for the unstage, unstage_all, discard, and stash backend callbacks.

  Uses a real temporary git repository (async: false) since these
  operations require actual git state. Each test creates a clean repo
  with committed files and verifies the git CLI-backed operations.
  """

  # async: false, spawns real git CLI processes, which can hit the BEAM erl_child_setup EPIPE race under concurrency.
  use ExUnit.Case, async: false

  @moduletag timeout: 20_000

  # Isolate from CI runner's global git config
  @git_env [
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_AUTHOR_NAME", "Test"},
    {"GIT_AUTHOR_EMAIL", "test@test.com"},
    {"GIT_COMMITTER_NAME", "Test"},
    {"GIT_COMMITTER_EMAIL", "test@test.com"}
  ]

  describe "unstage/2" do
    @tag :tmp_dir
    test "removes a staged file from the index", %{tmp_dir: dir} do
      init_git_repo(dir)
      file = Path.join(dir, "file.txt")
      File.write!(file, "content")
      git_cmd(dir, ["add", "file.txt"])

      # Verify it's staged
      {output, 0} = git_cmd(dir, ["status", "--porcelain"])
      assert output =~ "A  file.txt"

      # Unstage it
      assert :ok = Minga.Git.System.unstage(dir, "file.txt")

      # Verify it's now untracked
      {output, 0} = git_cmd(dir, ["status", "--porcelain"])
      assert output =~ "?? file.txt"
    end

    @tag :tmp_dir
    test "unstages multiple files", %{tmp_dir: dir} do
      init_git_repo(dir)
      File.write!(Path.join(dir, "a.txt"), "a")
      File.write!(Path.join(dir, "b.txt"), "b")
      git_cmd(dir, ["add", "a.txt", "b.txt"])

      assert :ok = Minga.Git.System.unstage(dir, ["a.txt", "b.txt"])

      {output, 0} = git_cmd(dir, ["status", "--porcelain"])
      assert output =~ "?? a.txt"
      assert output =~ "?? b.txt"
    end
  end

  describe "unstage_all/1" do
    @tag :tmp_dir
    test "unstages all staged files", %{tmp_dir: dir} do
      init_git_repo(dir)
      # Need an initial commit so HEAD exists for `git reset HEAD`
      File.write!(Path.join(dir, "init.txt"), "init")
      git_cmd(dir, ["add", "."])
      git_cmd(dir, ["commit", "-m", "init"])

      File.write!(Path.join(dir, "a.txt"), "a")
      File.write!(Path.join(dir, "b.txt"), "b")
      git_cmd(dir, ["add", "."])

      # Verify files are staged
      {output, 0} = git_cmd(dir, ["status", "--porcelain"])
      assert output =~ "A  a.txt"

      assert :ok = Minga.Git.System.unstage_all(dir)

      {output, 0} = git_cmd(dir, ["status", "--porcelain"])
      refute output =~ "A "
    end
  end

  describe "discard/2" do
    @tag :tmp_dir
    test "discards changes to a tracked file", %{tmp_dir: dir} do
      init_git_repo(dir)
      file = Path.join(dir, "file.txt")
      File.write!(file, "original")
      git_cmd(dir, ["add", "."])
      git_cmd(dir, ["commit", "-m", "init"])

      # Modify the file
      File.write!(file, "modified")
      {output, 0} = git_cmd(dir, ["status", "--porcelain"])
      assert output =~ " M file.txt"

      # Discard changes
      assert :ok = Minga.Git.System.discard(dir, "file.txt")

      # Verify content is restored
      assert File.read!(file) == "original"
      {output, 0} = git_cmd(dir, ["status", "--porcelain"])
      assert output == ""
    end

    @tag :tmp_dir
    test "removes an untracked file", %{tmp_dir: dir} do
      init_git_repo(dir)
      file = Path.join(dir, "new_file.txt")
      File.write!(file, "new content")
      assert File.exists?(file)

      assert :ok = Minga.Git.System.discard(dir, "new_file.txt")
      refute File.exists?(file)
    end

    @tag :tmp_dir
    test "returns error for nonexistent file", %{tmp_dir: dir} do
      init_git_repo(dir)

      result = Minga.Git.System.discard(dir, "nonexistent.txt")
      assert {:error, _} = result
    end
  end

  describe "stash operations" do
    @tag :tmp_dir
    test "saves tracked and untracked changes and pops them back", %{tmp_dir: dir} do
      init_git_repo(dir)
      file = Path.join(dir, "file.txt")
      untracked = Path.join(dir, "new.txt")
      File.write!(file, "original")
      git_cmd(dir, ["add", "."])
      git_cmd(dir, ["commit", "-m", "init"])

      File.write!(file, "modified")
      File.write!(untracked, "new")

      assert :ok = Minga.Git.System.stash(dir, include_untracked: true)
      assert File.read!(file) == "original"
      refute File.exists?(untracked)

      assert {:ok, [entry]} = Minga.Git.System.stash_list(dir)
      assert entry.index == 0
      assert entry.ref == "stash@{0}"
      assert entry.message =~ "WIP on main"

      assert :ok = Minga.Git.System.stash_pop(dir)
      assert File.read!(file) == "modified"
      assert File.read!(untracked) == "new"
    end

    @tag :tmp_dir
    test "returns a no-op error when there are no changes to stash", %{tmp_dir: dir} do
      init_git_repo(dir)
      file = Path.join(dir, "file.txt")
      File.write!(file, "original")
      git_cmd(dir, ["add", "."])
      git_cmd(dir, ["commit", "-m", "init"])

      assert {:error, "No changes to stash"} = Minga.Git.System.stash(dir, include_untracked: true)
      assert {:ok, []} = Minga.Git.System.stash_list(dir)
    end

    @tag :tmp_dir
    test "drops a stash by index", %{tmp_dir: dir} do
      init_git_repo(dir)
      file = Path.join(dir, "file.txt")
      File.write!(file, "original")
      git_cmd(dir, ["add", "."])
      git_cmd(dir, ["commit", "-m", "init"])
      File.write!(file, "modified")

      assert :ok = Minga.Git.System.stash(dir)
      assert {:ok, [_entry]} = Minga.Git.System.stash_list(dir)

      assert :ok = Minga.Git.System.stash_drop(dir, 0)
      assert {:ok, []} = Minga.Git.System.stash_list(dir)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp init_git_repo(dir) do
    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: dir, env: @git_env)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@test.com"], cd: dir, env: @git_env)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: dir, env: @git_env)
  end

  defp git_cmd(dir, args) do
    System.cmd("git", args, cd: dir, env: @git_env)
  end
end
