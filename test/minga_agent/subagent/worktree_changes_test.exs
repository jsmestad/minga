defmodule MingaAgent.Subagent.WorktreeChangesTest do
  @moduledoc """
  Tests for worktree change collection (AC5).

  These tests create real git repositories in temp directories to verify
  that `collect_changes/1` and `collect_changes_from/2` correctly detect
  committed and uncommitted changes relative to a base SHA.
  """

  # Spawns OS processes (git commands)
  use ExUnit.Case, async: false

  alias MingaAgent.Subagent.Worktree

  @moduletag timeout: 30_000

  setup do
    tmp = Path.join(System.tmp_dir!(), "minga-wt-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    git!(tmp, ["init"])
    # Disable inherited hooks and signing so the fixture does not depend on the host's git setup.
    hooks_dir = Path.join(tmp, ".git/hooks-disabled")
    File.mkdir_p!(hooks_dir)
    git!(tmp, ["config", "core.hooksPath", hooks_dir])
    git!(tmp, ["config", "user.name", "Minga Test"])
    git!(tmp, ["config", "user.email", "test@example.com"])
    git!(tmp, ["config", "commit.gpgsign", "false"])

    File.write!(Path.join(tmp, "existing.ex"), "original content")
    git!(tmp, ["add", "existing.ex"])
    git!(tmp, ["commit", "-m", "initial"])

    {base_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
    base_sha = String.trim(base_sha)

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{tmp: tmp, base_sha: base_sha}
  end

  describe "collect_changes_from/2" do
    test "returns empty list for a clean worktree", %{tmp: tmp, base_sha: base_sha} do
      assert {:ok, []} = Worktree.collect_changes_from(tmp, base_sha)
    end

    test "detects a committed new file as :added", %{tmp: tmp, base_sha: base_sha} do
      File.write!(Path.join(tmp, "new_file.ex"), "new content")
      git!(tmp, ["add", "new_file.ex"])
      git!(tmp, ["commit", "-m", "add file"])

      assert {:ok, changes} = Worktree.collect_changes_from(tmp, base_sha)
      assert {:added, "new_file.ex"} in changes
    end

    test "detects a committed modification as :modified", %{tmp: tmp, base_sha: base_sha} do
      File.write!(Path.join(tmp, "existing.ex"), "modified content")
      git!(tmp, ["add", "existing.ex"])
      git!(tmp, ["commit", "-m", "modify file"])

      assert {:ok, changes} = Worktree.collect_changes_from(tmp, base_sha)
      assert {:modified, "existing.ex"} in changes
    end

    test "detects a committed deletion as :deleted", %{tmp: tmp, base_sha: base_sha} do
      File.rm!(Path.join(tmp, "existing.ex"))
      git!(tmp, ["add", "existing.ex"])
      git!(tmp, ["commit", "-m", "delete file"])

      assert {:ok, changes} = Worktree.collect_changes_from(tmp, base_sha)
      assert {:deleted, "existing.ex"} in changes
    end

    test "detects uncommitted modifications", %{tmp: tmp, base_sha: base_sha} do
      File.write!(Path.join(tmp, "existing.ex"), "dirty content")

      assert {:ok, changes} = Worktree.collect_changes_from(tmp, base_sha)
      assert {:modified, "existing.ex"} in changes
    end

    test "merges committed and uncommitted changes for the same file", %{
      tmp: tmp,
      base_sha: base_sha
    } do
      File.write!(Path.join(tmp, "new_file.ex"), "initial")
      git!(tmp, ["add", "new_file.ex"])
      git!(tmp, ["commit", "-m", "add"])

      # Further modify the same file without committing
      File.write!(Path.join(tmp, "new_file.ex"), "changed again")

      assert {:ok, changes} = Worktree.collect_changes_from(tmp, base_sha)
      paths = Enum.map(changes, fn {_action, path} -> path end)
      assert "new_file.ex" in paths
      # Should appear only once after merge
      assert Enum.count(paths, &(&1 == "new_file.ex")) == 1
    end

    test "detects multiple changes across files", %{tmp: tmp, base_sha: base_sha} do
      File.write!(Path.join(tmp, "added.ex"), "new")
      File.write!(Path.join(tmp, "existing.ex"), "changed")
      git!(tmp, ["add", "added.ex", "existing.ex"])
      git!(tmp, ["commit", "-m", "multi-change"])

      assert {:ok, changes} = Worktree.collect_changes_from(tmp, base_sha)
      actions = Map.new(changes, fn {action, path} -> {path, action} end)
      assert actions["added.ex"] == :added
      assert actions["existing.ex"] == :modified
    end
  end

  describe "collect_changes/1 with struct" do
    test "produces the same result as collect_changes_from/2", %{tmp: tmp, base_sha: base_sha} do
      File.write!(Path.join(tmp, "new.ex"), "content")
      git!(tmp, ["add", "new.ex"])
      git!(tmp, ["commit", "-m", "add"])

      worktree = %Worktree{
        root: tmp,
        path: tmp,
        branch: "test",
        base_sha: base_sha,
        backend: Worktree.System,
        backend_opts: []
      }

      assert {:ok, struct_changes} = Worktree.collect_changes(worktree)
      assert {:ok, path_changes} = Worktree.collect_changes_from(tmp, base_sha)
      assert Enum.sort(struct_changes) == Enum.sort(path_changes)
    end
  end

  describe "read_file/2 and read_base_file/2" do
    test "read_file returns current content from worktree", %{tmp: tmp, base_sha: base_sha} do
      File.write!(Path.join(tmp, "existing.ex"), "current version")

      worktree = %Worktree{
        root: tmp,
        path: tmp,
        branch: "test",
        base_sha: base_sha,
        backend: Worktree.System,
        backend_opts: []
      }

      assert {:ok, "current version"} = Worktree.read_file(worktree, "existing.ex")
    end

    test "read_base_file returns content at base SHA", %{tmp: tmp, base_sha: base_sha} do
      File.write!(Path.join(tmp, "existing.ex"), "modified version")

      worktree = %Worktree{
        root: tmp,
        path: tmp,
        branch: "test",
        base_sha: base_sha,
        backend: Worktree.System,
        backend_opts: []
      }

      assert {:ok, "original content"} = Worktree.read_base_file(worktree, "existing.ex")
    end

    test "read_base_file returns error for new files", %{tmp: tmp, base_sha: base_sha} do
      File.write!(Path.join(tmp, "brand_new.ex"), "new")
      git!(tmp, ["add", "brand_new.ex"])
      git!(tmp, ["commit", "-m", "add"])

      worktree = %Worktree{
        root: tmp,
        path: tmp,
        branch: "test",
        base_sha: base_sha,
        backend: Worktree.System,
        backend_opts: []
      }

      assert {:error, _} = Worktree.read_base_file(worktree, "brand_new.ex")
    end
  end

  @spec git!(String.t(), [String.t()]) :: String.t()
  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end
end
