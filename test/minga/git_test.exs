defmodule Minga.GitTest do
  @moduledoc "Tests for the Git delegator and pure calculations."
  use ExUnit.Case, async: true

  alias Minga.Git
  alias Minga.Git.Stub, as: GitStub

  describe "delegator with stub" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      GitStub.set_root(dir, dir)
      on_exit(fn -> GitStub.clear(dir) end)
      %{root: dir}
    end

    test "root_for returns registered root", %{root: dir} do
      assert {:ok, ^dir} = Git.root_for(dir)
    end

    test "root_for returns :not_git for unregistered path" do
      assert :not_git = Git.root_for("/tmp/nowhere_#{System.unique_integer()}")
    end

    test "root_for walks ancestor directories", %{root: dir} do
      subdir = Path.join(dir, "lib/deep/nested")
      assert {:ok, ^dir} = Git.root_for(subdir)
    end

    test "show_head returns configured content", %{root: dir} do
      GitStub.set_head(dir, "lib/app.ex", "defmodule App do\nend\n")
      assert {:ok, "defmodule App do\nend\n"} = Git.show_head(dir, "lib/app.ex")
    end

    test "show_head returns :error for unconfigured file", %{root: dir} do
      assert :error = Git.show_head(dir, "nonexistent.ex")
    end

    test "status returns configured entries", %{root: dir} do
      entries = [%Git.StatusEntry{path: "a.ex", status: :modified, staged: false}]
      GitStub.set_status(dir, entries)
      assert {:ok, ^entries} = Git.status(dir)
    end

    test "status returns empty list by default", %{root: dir} do
      assert {:ok, []} = Git.status(dir)
    end

    test "diff returns configured text", %{root: dir} do
      GitStub.set_diff(dir, "+new line")
      assert {:ok, "+new line"} = Git.diff(dir)
    end

    test "diff returns commit-specific text", %{root: dir} do
      GitStub.set_diff(dir, [commit: "abc123"], "+commit line")
      assert {:ok, "+commit line"} = Git.diff(dir, commit: "abc123")
    end

    test "diff returns commit-specific text when staged is explicitly false", %{root: dir} do
      GitStub.set_diff(dir, [commit: "abc123", staged: false], "+commit line")
      assert {:ok, "+commit line"} = Git.diff(dir, commit: "abc123", staged: false)
    end

    test "diff returns path-specific commit text", %{root: dir} do
      GitStub.set_diff(dir, [commit: "abc123", path: "lib/app.ex"], "+file line")
      assert {:ok, "+file line"} = Git.diff(dir, commit: "abc123", path: "lib/app.ex")
    end

    test "diff rejects commit and staged together", %{root: dir} do
      assert {:error, reason} = Git.diff(dir, commit: "abc123", staged: true)
      assert reason =~ "cannot be combined"
    end

    test "diff rejects unknown option keys", %{root: dir} do
      assert {:error, reason} = Git.diff(dir, foo: "bar")
      assert reason =~ "not supported"
    end

    test "diff rejects duplicate option keys", %{root: dir} do
      assert {:error, reason} = Git.diff(dir, [commit: "abc123", commit: "def456"])
      assert reason =~ "duplicate keys"
    end

    test "diff rejects non-binary path, commit, and non-boolean staged values", %{root: dir} do
      assert {:error, path_reason} = Git.diff(dir, path: :path)
      assert path_reason =~ ":path"

      assert {:error, commit_reason} = Git.diff(dir, commit: :commit)
      assert commit_reason =~ ":commit"

      assert {:error, staged_reason} = Git.diff(dir, staged: :staged)
      assert staged_reason =~ ":staged"
    end

    test "log returns configured entries", %{root: dir} do
      entry = %Git.LogEntry{
        hash: "abc",
        short_hash: "ab",
        author: "X",
        date: "today",
        message: "hi"
      }

      GitStub.set_log(dir, [entry])
      assert {:ok, [^entry]} = Git.log(dir)
    end

    test "stash_list returns configured entries", %{root: dir} do
      entry = %Git.StashEntry{index: 0, ref: "stash@{0}", message: "WIP", date: "2 hours ago"}

      GitStub.set_stashes(dir, [entry])
      assert {:ok, [^entry]} = Git.stash_list(dir)
    end

    test "stash returns :ok when there are changes to save", %{root: dir} do
      GitStub.set_status(dir, [%Git.StatusEntry{path: "a.ex", status: :modified, staged: false}])

      assert :ok = Git.stash(dir, include_untracked: true)
    end

    test "stash_pop returns :ok when stashes exist", %{root: dir} do
      GitStub.set_stashes(dir, [
        %Git.StashEntry{index: 0, ref: "stash@{0}", message: "WIP", date: "2 hours ago"}
      ])

      assert :ok = Git.stash_pop(dir)
    end

    test "stash_drop returns :ok when the requested index exists", %{root: dir} do
      GitStub.set_stashes(dir, [
        %Git.StashEntry{index: 0, ref: "stash@{0}", message: "WIP", date: "2 hours ago"}
      ])

      assert :ok = Git.stash_drop(dir, 0)
    end

    test "stashing on top of an existing stash keeps the newest entry at stash@{0}", %{root: dir} do
      GitStub.set_status(dir, [%Git.StatusEntry{path: "a.ex", status: :modified, staged: false}])

      GitStub.set_stashes(dir, [
        %Git.StashEntry{index: 0, ref: "stash@{0}", message: "older", date: "2 hours ago"}
      ])

      assert :ok = Git.stash(dir, include_untracked: true)

      assert {:ok,
              [
                %Git.StashEntry{index: 0, ref: "stash@{0}", message: "WIP on main"},
                %Git.StashEntry{index: 1, ref: "stash@{1}", message: "older"}
              ]} =
               Git.stash_list(dir)

      assert :ok = Git.stash_drop(dir, 0)
      assert {:ok, [remaining]} = Git.stash_list(dir)
      assert remaining.index == 0
      assert remaining.ref == "stash@{0}"
      assert remaining.message == "older"
    end

    test "stage returns :ok", %{root: dir} do
      assert :ok = Git.stage(dir, ["file.txt"])
    end

    test "commit returns stub hash", %{root: dir} do
      assert {:ok, "stub000"} = Git.commit(dir, "msg")
    end

    test "current_branch returns default 'main' when not configured", %{root: dir} do
      assert {:ok, "main"} = Git.current_branch(dir)
    end

    test "current_branch returns configured branch name", %{root: dir} do
      GitStub.set_branch(dir, "feat/modeline-git")
      assert {:ok, "feat/modeline-git"} = Git.current_branch(dir)
    end
  end

  describe "relative_path (pure calculation)" do
    test "returns path relative to git root" do
      assert Git.relative_path("/home/user/project", "/home/user/project/lib/foo.ex") ==
               "lib/foo.ex"
    end
  end
end
