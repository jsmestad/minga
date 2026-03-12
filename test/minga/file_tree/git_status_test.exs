defmodule Minga.FileTree.GitStatusTest do
  use ExUnit.Case, async: true

  alias Minga.FileTree.GitStatus

  @moduletag :tmp_dir

  describe "compute/1" do
    test "returns empty map for non-git directory" do
      # Use /tmp directly to avoid being inside the worktree's git repo
      dir =
        Path.join(System.tmp_dir!(), "minga_test_no_git_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      assert GitStatus.compute(dir) == %{}
    end

    test "detects untracked files in a git repo", %{tmp_dir: tmp_dir} do
      git_init!(tmp_dir)
      File.write!(Path.join(tmp_dir, "new_file.txt"), "hello")

      status = GitStatus.compute(tmp_dir)
      assert Map.get(status, Path.join(tmp_dir, "new_file.txt")) == :untracked
    end

    test "detects staged files", %{tmp_dir: tmp_dir} do
      git_init!(tmp_dir)
      file_path = Path.join(tmp_dir, "staged.txt")
      File.write!(file_path, "hello")
      System.cmd("git", ["add", "staged.txt"], cd: tmp_dir)

      status = GitStatus.compute(tmp_dir)
      assert Map.get(status, file_path) == :staged
    end

    test "detects modified files", %{tmp_dir: tmp_dir} do
      git_init!(tmp_dir)
      file_path = Path.join(tmp_dir, "tracked.txt")
      File.write!(file_path, "original")
      System.cmd("git", ["add", "tracked.txt"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "init"], cd: tmp_dir)

      # Modify the file
      File.write!(file_path, "modified")

      status = GitStatus.compute(tmp_dir)
      assert Map.get(status, file_path) == :modified
    end

    test "propagates status to parent directories", %{tmp_dir: tmp_dir} do
      git_init!(tmp_dir)
      subdir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "app.ex"), "hello")

      status = GitStatus.compute(tmp_dir)

      # The file is untracked
      assert Map.get(status, Path.join(subdir, "app.ex")) == :untracked
      # The parent directory should also show untracked
      assert Map.get(status, subdir) == :untracked
    end

    test "directory shows worst child status", %{tmp_dir: tmp_dir} do
      git_init!(tmp_dir)
      subdir = Path.join(tmp_dir, "src")
      File.mkdir_p!(subdir)

      # Create one tracked+modified file and one untracked file
      File.write!(Path.join(subdir, "tracked.ex"), "original")
      System.cmd("git", ["add", "src/tracked.ex"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "init"], cd: tmp_dir)
      File.write!(Path.join(subdir, "tracked.ex"), "modified")
      File.write!(Path.join(subdir, "new.ex"), "new")

      status = GitStatus.compute(tmp_dir)

      # modified (severity 5) is worse than untracked (severity 1)
      assert Map.get(status, subdir) == :modified
    end
  end

  describe "symbol/1" do
    test "returns correct symbols for each status" do
      assert GitStatus.symbol(:modified) == "●"
      assert GitStatus.symbol(:staged) == "✚"
      assert GitStatus.symbol(:untracked) == "?"
      assert GitStatus.symbol(:conflict) == "!"
    end
  end

  describe "severity/1" do
    test "modified is more severe than untracked" do
      assert GitStatus.severity(:modified) > GitStatus.severity(:untracked)
    end

    test "conflict is most severe" do
      assert GitStatus.severity(:conflict) > GitStatus.severity(:modified)
      assert GitStatus.severity(:conflict) > GitStatus.severity(:staged)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp git_init!(dir) do
    System.cmd("git", ["init"], cd: dir)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: dir)
  end
end
