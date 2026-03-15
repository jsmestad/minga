defmodule Minga.Agent.Tools.GitTest do
  @moduledoc "Tests for the agent git tool formatting layer using stub data."
  use ExUnit.Case, async: true

  alias Minga.Agent.Tools.Git, as: GitTools
  alias Minga.Git.LogEntry
  alias Minga.Git.StatusEntry
  alias Minga.Git.Stub, as: GitStub

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    GitStub.set_root(dir, dir)
    on_exit(fn -> GitStub.clear(dir) end)
    %{repo: dir}
  end

  describe "status/1" do
    test "returns clean message when no changes", %{repo: dir} do
      assert {:ok, result} = GitTools.status(dir)
      assert result =~ "clean"
    end

    test "reports modified and untracked files", %{repo: dir} do
      GitStub.set_status(dir, [
        %StatusEntry{path: "tracked.txt", status: :modified, staged: false},
        %StatusEntry{path: "new.txt", status: :untracked, staged: false}
      ])

      assert {:ok, result} = GitTools.status(dir)
      assert result =~ "tracked.txt"
      assert result =~ "new.txt"
    end

    test "reports staged files separately", %{repo: dir} do
      GitStub.set_status(dir, [
        %StatusEntry{path: "file.txt", status: :modified, staged: true}
      ])

      assert {:ok, result} = GitTools.status(dir)
      assert result =~ "Staged"
    end
  end

  describe "diff/2" do
    test "returns no differences when clean", %{repo: dir} do
      assert {:ok, "No differences."} = GitTools.diff(dir)
    end

    test "returns diff output", %{repo: dir} do
      GitStub.set_diff(dir, "-line 2\n+modified line\n")
      assert {:ok, result} = GitTools.diff(dir)
      assert result =~ "-line 2"
      assert result =~ "+modified line"
    end
  end

  describe "log/2" do
    test "returns no commits for empty log", %{repo: dir} do
      assert {:ok, "No commits found."} = GitTools.log(dir)
    end

    test "returns formatted commit entries", %{repo: dir} do
      GitStub.set_log(dir, [
        %LogEntry{
          hash: "abc123",
          short_hash: "abc1",
          author: "Dev",
          date: "2026-03-15",
          message: "first commit"
        },
        %LogEntry{
          hash: "def456",
          short_hash: "def4",
          author: "Dev",
          date: "2026-03-15",
          message: "second commit"
        }
      ])

      assert {:ok, result} = GitTools.log(dir)
      assert result =~ "first commit"
      assert result =~ "second commit"
    end
  end

  describe "stage/2" do
    test "returns success message", %{repo: dir} do
      assert {:ok, result} = GitTools.stage(dir, ["file.txt"])
      assert result =~ "Staged 1 file"
    end
  end

  describe "commit/2" do
    test "returns success message with hash", %{repo: dir} do
      assert {:ok, result} = GitTools.commit(dir, "test message")
      assert result =~ "test message"
    end
  end
end
