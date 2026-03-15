defmodule Minga.FileTree.GitStatusTest do
  use ExUnit.Case, async: true

  alias Minga.FileTree.GitStatus
  alias Minga.Git.StatusEntry
  alias Minga.Git.Stub, as: GitStub

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    GitStub.set_root(dir, dir)
    on_exit(fn -> GitStub.clear(dir) end)
    %{root: dir}
  end

  describe "compute/1" do
    test "returns empty map for non-git directory" do
      assert GitStatus.compute("/tmp/not_a_repo_#{System.unique_integer()}") == %{}
    end

    test "detects untracked files", %{root: dir} do
      GitStub.set_status(dir, [
        %StatusEntry{path: "new_file.txt", status: :untracked, staged: false}
      ])

      status = GitStatus.compute(dir)
      assert Map.get(status, Path.join(dir, "new_file.txt")) == :untracked
    end

    test "detects staged files", %{root: dir} do
      GitStub.set_status(dir, [
        %StatusEntry{path: "staged.txt", status: :added, staged: true}
      ])

      status = GitStatus.compute(dir)
      assert Map.get(status, Path.join(dir, "staged.txt")) == :staged
    end

    test "detects modified files", %{root: dir} do
      GitStub.set_status(dir, [
        %StatusEntry{path: "tracked.txt", status: :modified, staged: false}
      ])

      status = GitStatus.compute(dir)
      assert Map.get(status, Path.join(dir, "tracked.txt")) == :modified
    end

    test "propagates status to parent directories", %{root: dir} do
      GitStub.set_status(dir, [
        %StatusEntry{path: "lib/app.ex", status: :untracked, staged: false}
      ])

      status = GitStatus.compute(dir)
      assert Map.get(status, Path.join(dir, "lib/app.ex")) == :untracked
      assert Map.get(status, Path.join(dir, "lib")) == :untracked
    end

    test "directory shows worst child status", %{root: dir} do
      GitStub.set_status(dir, [
        %StatusEntry{path: "src/tracked.ex", status: :modified, staged: false},
        %StatusEntry{path: "src/new.ex", status: :untracked, staged: false}
      ])

      status = GitStatus.compute(dir)
      assert Map.get(status, Path.join(dir, "src")) == :modified
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
end
