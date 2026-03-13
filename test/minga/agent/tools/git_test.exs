defmodule Minga.Agent.Tools.GitTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.Git, as: GitTools

  @moduletag :tmp_dir

  # Creates a temporary git repo for testing
  defp init_git_repo(dir) do
    System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test User"], cd: dir)
    dir
  end

  defp create_and_commit(dir, filename, content, message) do
    File.write!(Path.join(dir, filename), content)
    System.cmd("git", ["add", filename], cd: dir)
    System.cmd("git", ["commit", "-m", message], cd: dir, stderr_to_stdout: true)
  end

  describe "status/1" do
    test "returns clean status for a clean repo", %{tmp_dir: dir} do
      init_git_repo(dir)
      create_and_commit(dir, "initial.txt", "hello", "initial commit")

      assert {:ok, result} = GitTools.status(dir)
      assert result =~ "clean"
    end

    test "reports modified and untracked files", %{tmp_dir: dir} do
      init_git_repo(dir)
      create_and_commit(dir, "tracked.txt", "hello", "initial")

      # Modify tracked file
      File.write!(Path.join(dir, "tracked.txt"), "changed")
      # Create untracked file
      File.write!(Path.join(dir, "new.txt"), "new")

      assert {:ok, result} = GitTools.status(dir)
      assert result =~ "tracked.txt"
      assert result =~ "new.txt"
      assert result =~ "M"
      assert result =~ "?"
    end

    test "reports staged files separately", %{tmp_dir: dir} do
      init_git_repo(dir)
      create_and_commit(dir, "file.txt", "v1", "initial")

      File.write!(Path.join(dir, "file.txt"), "v2")
      System.cmd("git", ["add", "file.txt"], cd: dir)

      assert {:ok, result} = GitTools.status(dir)
      assert result =~ "Staged"
    end
  end

  describe "diff/2" do
    test "returns no differences for a clean repo", %{tmp_dir: dir} do
      init_git_repo(dir)
      create_and_commit(dir, "file.txt", "content", "initial")

      assert {:ok, "No differences."} = GitTools.diff(dir)
    end

    test "returns diff for modified files", %{tmp_dir: dir} do
      init_git_repo(dir)
      create_and_commit(dir, "file.txt", "line 1\nline 2\n", "initial")
      File.write!(Path.join(dir, "file.txt"), "line 1\nmodified line\n")

      assert {:ok, result} = GitTools.diff(dir)
      assert result =~ "-line 2"
      assert result =~ "+modified line"
    end

    test "diffs a specific file", %{tmp_dir: dir} do
      init_git_repo(dir)
      create_and_commit(dir, "a.txt", "aaa", "first")
      create_and_commit(dir, "b.txt", "bbb", "second")

      File.write!(Path.join(dir, "a.txt"), "changed_a")
      File.write!(Path.join(dir, "b.txt"), "changed_b")

      assert {:ok, result} = GitTools.diff(dir, path: "a.txt")
      assert result =~ "a.txt"
      refute result =~ "b.txt"
    end
  end

  describe "log/2" do
    test "returns recent commits", %{tmp_dir: dir} do
      init_git_repo(dir)
      create_and_commit(dir, "file.txt", "v1", "first commit")
      create_and_commit(dir, "file.txt", "v2", "second commit")

      assert {:ok, result} = GitTools.log(dir)
      assert result =~ "first commit"
      assert result =~ "second commit"
    end

    test "limits commit count", %{tmp_dir: dir} do
      init_git_repo(dir)
      create_and_commit(dir, "file.txt", "v1", "commit one")
      create_and_commit(dir, "file.txt", "v2", "commit two")
      create_and_commit(dir, "file.txt", "v3", "commit three")

      assert {:ok, result} = GitTools.log(dir, count: 1)
      assert result =~ "commit three"
      refute result =~ "commit one"
    end
  end

  describe "stage/2" do
    test "stages files", %{tmp_dir: dir} do
      init_git_repo(dir)
      create_and_commit(dir, "initial.txt", "hi", "init")
      File.write!(Path.join(dir, "new.txt"), "content")

      assert {:ok, result} = GitTools.stage(dir, ["new.txt"])
      assert result =~ "Staged 1 file"
    end
  end

  describe "commit/2" do
    test "creates a commit", %{tmp_dir: dir} do
      init_git_repo(dir)
      File.write!(Path.join(dir, "file.txt"), "content")
      System.cmd("git", ["add", "file.txt"], cd: dir)

      assert {:ok, result} = GitTools.commit(dir, "test commit message")
      assert result =~ "test commit message"
    end

    test "fails when nothing is staged", %{tmp_dir: dir} do
      init_git_repo(dir)
      create_and_commit(dir, "initial.txt", "hi", "init")

      assert {:error, reason} = GitTools.commit(dir, "empty commit")
      assert reason =~ "nothing to commit" or reason =~ "git commit failed"
    end
  end
end
