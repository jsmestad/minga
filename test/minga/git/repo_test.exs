defmodule Minga.Git.RepoTest do
  @moduledoc "Tests for Minga.Git.Repo: per-repository GenServer lifecycle, caching, and event publication."
  use ExUnit.Case, async: true

  alias Minga.Events
  alias Minga.Git.Repo
  alias Minga.Git.StatusEntry
  alias Minga.Git.Stub, as: GitStub

  @moduletag :tmp_dir

  describe "initial state" do
    setup %{tmp_dir: dir} do
      GitStub.set_root(dir, dir)
      GitStub.set_branch(dir, "feat/xyz")

      GitStub.set_status(dir, [
        %StatusEntry{path: "lib/foo.ex", status: :modified, staged: false}
      ])

      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_supervised!({Repo, git_root: dir}, id: {Repo, dir})
      %{root: dir, repo: repo}
    end

    test "loads status and branch from backend on start", %{repo: repo} do
      assert [%StatusEntry{path: "lib/foo.ex", status: :modified}] = Repo.status(repo)
      assert Repo.branch(repo) == "feat/xyz"
    end

    test "loads ahead/behind counts on start", %{tmp_dir: dir} do
      ab_dir = dir <> "/ab"
      GitStub.set_root(ab_dir, ab_dir)
      GitStub.set_ahead_behind(ab_dir, 3, 1)
      on_exit(fn -> GitStub.clear(ab_dir) end)

      repo = start_supervised!({Repo, git_root: ab_dir}, id: {Repo, ab_dir})

      summary = Repo.summary(repo)
      assert summary.ahead == 3
      assert summary.behind == 1
    end
  end

  describe "read APIs" do
    setup %{tmp_dir: dir} do
      GitStub.set_root(dir, dir)
      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_supervised!({Repo, git_root: dir}, id: {Repo, dir})
      %{root: dir, repo: repo}
    end

    test "status returns cached entries (not live)", %{root: dir, repo: repo} do
      assert Repo.status(repo) == []

      # Change the stub after start; cached result should not change
      GitStub.set_status(dir, [
        %StatusEntry{path: "new.ex", status: :added, staged: true}
      ])

      assert Repo.status(repo) == []
    end

    test "branch returns cached branch name", %{repo: repo} do
      assert Repo.branch(repo) == "main"
    end
  end

  describe "refresh" do
    setup %{tmp_dir: dir} do
      GitStub.set_root(dir, dir)
      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_supervised!({Repo, git_root: dir}, id: {Repo, dir})
      %{root: dir, repo: repo}
    end

    test "re-reads status and branch from backend", %{root: dir, repo: repo} do
      assert Repo.status(repo) == []
      assert Repo.branch(repo) == "main"

      entry = %StatusEntry{path: "changed.ex", status: :modified, staged: false}
      GitStub.set_status(dir, [entry])
      GitStub.set_branch(dir, "develop")

      Repo.refresh(repo)
      :sys.get_state(repo)

      assert Repo.status(repo) == [entry]
      assert Repo.branch(repo) == "develop"
    end

    test "refresh publishes git_status_changed when status changes", %{root: dir, repo: repo} do
      Events.subscribe(:git_status_changed)
      entry = %StatusEntry{path: "new.ex", status: :added, staged: true}
      GitStub.set_status(dir, [entry])

      Repo.refresh(repo)
      :sys.get_state(repo)

      # Pin ^dir to only match events from this test's Repo (async-safe)
      assert_receive {:minga_event, :git_status_changed,
                      %Events.GitStatusEvent{git_root: ^dir, entries: [^entry]}}
    end

    test "refresh does not publish event when status is unchanged", %{root: dir, repo: repo} do
      Events.subscribe(:git_status_changed)

      Repo.refresh(repo)
      :sys.get_state(repo)

      # Pin ^dir so we only refute events from this test's Repo
      refute_receive {:minga_event, :git_status_changed, %{git_root: ^dir}}, 50
    end

    test "refresh publishes git_status_changed when branch changes", %{root: dir, repo: repo} do
      Events.subscribe(:git_status_changed)
      GitStub.set_branch(dir, "feature/new")

      Repo.refresh(repo)
      :sys.get_state(repo)

      assert_receive {:minga_event, :git_status_changed,
                      %Events.GitStatusEvent{git_root: ^dir, branch: "feature/new"}}
    end
  end

  describe "summary" do
    setup %{tmp_dir: dir} do
      GitStub.set_root(dir, dir)

      GitStub.set_status(dir, [
        %StatusEntry{path: "a.ex", status: :modified, staged: true},
        %StatusEntry{path: "b.ex", status: :modified, staged: false},
        %StatusEntry{path: "c.ex", status: :untracked, staged: false},
        %StatusEntry{path: "d.ex", status: :conflict, staged: false},
        %StatusEntry{path: "e.ex", status: :added, staged: true}
      ])

      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_supervised!({Repo, git_root: dir}, id: {Repo, dir})
      %{root: dir, repo: repo}
    end

    test "aggregates counts by category", %{repo: repo} do
      summary = Repo.summary(repo)
      assert summary.staged_count == 2
      assert summary.unstaged_count == 1
      assert summary.untracked_count == 1
      assert summary.conflict_count == 1
    end

    test "with zero entries returns all-zero counts", %{tmp_dir: dir} do
      # Start a separate repo with empty status
      empty_dir = dir <> "/empty"
      GitStub.set_root(empty_dir, empty_dir)
      on_exit(fn -> GitStub.clear(empty_dir) end)

      repo = start_supervised!({Repo, git_root: empty_dir}, id: {Repo, empty_dir})
      summary = Repo.summary(repo)

      assert summary.staged_count == 0
      assert summary.unstaged_count == 0
      assert summary.untracked_count == 0
      assert summary.conflict_count == 0
      assert summary.branch == "main"
      assert summary.ahead == 0
      assert summary.behind == 0
    end

    test "conflict entries counted as conflicts regardless of staged flag", %{tmp_dir: dir} do
      conflict_dir = dir <> "/conflict"
      GitStub.set_root(conflict_dir, conflict_dir)

      GitStub.set_status(conflict_dir, [
        %StatusEntry{path: "x.ex", status: :conflict, staged: true}
      ])

      on_exit(fn -> GitStub.clear(conflict_dir) end)

      repo = start_supervised!({Repo, git_root: conflict_dir}, id: {Repo, conflict_dir})
      summary = Repo.summary(repo)

      assert summary.conflict_count == 1
      assert summary.staged_count == 0
    end
  end

  describe "path relativization" do
    test "relativizes paths when project_root differs from git_root", %{tmp_dir: dir} do
      git_root = dir
      project_root = Path.join(dir, "apps/myapp")

      GitStub.set_root(git_root, git_root)

      GitStub.set_status(git_root, [
        %StatusEntry{path: "apps/myapp/lib/foo.ex", status: :modified, staged: false},
        %StatusEntry{path: "apps/other/lib/bar.ex", status: :modified, staged: false}
      ])

      on_exit(fn -> GitStub.clear(git_root) end)

      repo =
        start_supervised!(
          {Repo, git_root: git_root, project_root: project_root},
          id: {Repo, git_root}
        )

      entries = Repo.status(repo)
      assert length(entries) == 1
      assert hd(entries).path == "lib/foo.ex"
    end

    test "paths unchanged when project_root equals git_root", %{tmp_dir: dir} do
      GitStub.set_root(dir, dir)

      GitStub.set_status(dir, [
        %StatusEntry{path: "lib/foo.ex", status: :modified, staged: false}
      ])

      on_exit(fn -> GitStub.clear(dir) end)

      repo =
        start_supervised!(
          {Repo, git_root: dir, project_root: dir},
          id: {Repo, dir}
        )

      assert [%StatusEntry{path: "lib/foo.ex"}] = Repo.status(repo)
    end

    test "paths unchanged when project_root is nil", %{tmp_dir: dir} do
      GitStub.set_root(dir, dir)

      GitStub.set_status(dir, [
        %StatusEntry{path: "lib/foo.ex", status: :modified, staged: false}
      ])

      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_supervised!({Repo, git_root: dir}, id: {Repo, dir})

      assert [%StatusEntry{path: "lib/foo.ex"}] = Repo.status(repo)
    end
  end

  describe "lookup" do
    test "returns nil when no repo exists for path" do
      assert Repo.lookup("/nonexistent/path") == nil
    end

    test "returns pid when repo exists", %{tmp_dir: dir} do
      GitStub.set_root(dir, dir)
      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_supervised!({Repo, git_root: dir}, id: {Repo, dir})
      assert Repo.lookup(dir) == repo
    end
  end
end
