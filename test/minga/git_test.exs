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
