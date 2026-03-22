defmodule Minga.Git.BackendOperationsTest do
  @moduledoc """
  Tests for the unstage, unstage_all, and discard backend callbacks.

  Uses a real temporary git repository (async: false) since these
  operations require actual git state. Each test creates a clean repo
  with committed files and verifies the git CLI-backed operations.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 10_000

  describe "unstage/2" do
    @tag :tmp_dir
    test "removes a staged file from the index", %{tmp_dir: dir} do
      init_git_repo(dir)
      file = Path.join(dir, "file.txt")
      File.write!(file, "content")
      System.cmd("git", ["add", "file.txt"], cd: dir)

      # Verify it's staged
      {output, 0} = System.cmd("git", ["status", "--porcelain"], cd: dir)
      assert output =~ "A  file.txt"

      # Unstage it
      assert :ok = Minga.Git.System.unstage(dir, "file.txt")

      # Verify it's now untracked
      {output, 0} = System.cmd("git", ["status", "--porcelain"], cd: dir)
      assert output =~ "?? file.txt"
    end

    @tag :tmp_dir
    test "unstages multiple files", %{tmp_dir: dir} do
      init_git_repo(dir)
      File.write!(Path.join(dir, "a.txt"), "a")
      File.write!(Path.join(dir, "b.txt"), "b")
      System.cmd("git", ["add", "a.txt", "b.txt"], cd: dir)

      assert :ok = Minga.Git.System.unstage(dir, ["a.txt", "b.txt"])

      {output, 0} = System.cmd("git", ["status", "--porcelain"], cd: dir)
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
      System.cmd("git", ["add", "."], cd: dir)
      System.cmd("git", ["commit", "-m", "init"], cd: dir)

      File.write!(Path.join(dir, "a.txt"), "a")
      File.write!(Path.join(dir, "b.txt"), "b")
      System.cmd("git", ["add", "."], cd: dir)

      # Verify files are staged
      {output, 0} = System.cmd("git", ["status", "--porcelain"], cd: dir)
      assert output =~ "A  a.txt"

      assert :ok = Minga.Git.System.unstage_all(dir)

      {output, 0} = System.cmd("git", ["status", "--porcelain"], cd: dir)
      refute output =~ "A "
    end
  end

  describe "discard/2" do
    @tag :tmp_dir
    test "discards changes to a tracked file", %{tmp_dir: dir} do
      init_git_repo(dir)
      file = Path.join(dir, "file.txt")
      File.write!(file, "original")
      System.cmd("git", ["add", "."], cd: dir)
      System.cmd("git", ["commit", "-m", "init"], cd: dir)

      # Modify the file
      File.write!(file, "modified")
      {output, 0} = System.cmd("git", ["status", "--porcelain"], cd: dir)
      assert output =~ " M file.txt"

      # Discard changes
      assert :ok = Minga.Git.System.discard(dir, "file.txt")

      # Verify content is restored
      assert File.read!(file) == "original"
      {output, 0} = System.cmd("git", ["status", "--porcelain"], cd: dir)
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

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp init_git_repo(dir) do
    System.cmd("git", ["init"], cd: dir)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: dir)
  end
end
