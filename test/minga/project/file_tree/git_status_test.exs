defmodule Minga.Project.FileTree.GitStatusTest do
  use ExUnit.Case, async: true

  alias Minga.Git.StatusEntry
  alias Minga.Project.FileTree.GitStatus

  @moduletag :tmp_dir

  describe "from_entries/3" do
    test "detects untracked files", %{tmp_dir: dir} do
      entries = [%StatusEntry{path: "new_file.txt", status: :untracked, staged: false}]

      status = GitStatus.from_entries(entries, dir, dir)
      assert Map.get(status, Path.join(dir, "new_file.txt")) == :untracked
    end

    test "detects staged files", %{tmp_dir: dir} do
      entries = [%StatusEntry{path: "staged.txt", status: :added, staged: true}]

      status = GitStatus.from_entries(entries, dir, dir)
      assert Map.get(status, Path.join(dir, "staged.txt")) == :staged
    end

    test "detects modified files", %{tmp_dir: dir} do
      entries = [%StatusEntry{path: "tracked.txt", status: :modified, staged: false}]

      status = GitStatus.from_entries(entries, dir, dir)
      assert Map.get(status, Path.join(dir, "tracked.txt")) == :modified
    end

    test "propagates status to parent directories", %{tmp_dir: dir} do
      entries = [%StatusEntry{path: "lib/app.ex", status: :untracked, staged: false}]

      status = GitStatus.from_entries(entries, dir, dir)
      assert Map.get(status, Path.join(dir, "lib/app.ex")) == :untracked
      assert Map.get(status, Path.join(dir, "lib")) == :untracked
    end

    test "directory shows worst child status", %{tmp_dir: dir} do
      entries = [
        %StatusEntry{path: "src/tracked.ex", status: :modified, staged: false},
        %StatusEntry{path: "src/new.ex", status: :untracked, staged: false}
      ]

      status = GitStatus.from_entries(entries, dir, dir)
      assert Map.get(status, Path.join(dir, "src")) == :modified
    end

    test "filters repo status to the requested root path", %{tmp_dir: dir} do
      root_path = Path.join(dir, "app")
      File.mkdir_p!(root_path)

      entries = [
        %StatusEntry{path: "app/lib/inside.ex", status: :modified, staged: false},
        %StatusEntry{path: "application/lib/outside.ex", status: :conflict, staged: false}
      ]

      status = GitStatus.from_entries(entries, dir, root_path)

      assert Map.get(status, Path.join([dir, "app", "lib"])) == :modified
      refute Map.has_key?(status, Path.join([dir, "application", "lib"]))
      refute Map.has_key?(status, Path.join([dir, "application", "lib", "outside.ex"]))
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
