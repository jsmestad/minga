defmodule Minga.Git.RepoTest do
  @moduledoc "Tests for Minga.Git.Repo: per-repository GenServer lifecycle, caching, and event publication."
  use ExUnit.Case, async: true

  alias Minga.Events
  alias Minga.Git.Repo
  alias Minga.Git.Repo.StatusSnapshot
  alias Minga.Git.StashEntry
  alias Minga.Git.StatusEntry
  alias Minga.Git.Stub, as: GitStub

  @moduletag :tmp_dir

  describe "initial state" do
    setup %{tmp_dir: dir} do
      events_registry = start_events_registry()
      GitStub.set_root(dir, dir)
      GitStub.set_branch(dir, "feat/xyz")

      GitStub.set_status(dir, [
        %StatusEntry{path: "lib/foo.ex", status: :modified, staged: false}
      ])

      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_repo(dir, events_registry: events_registry)
      Repo.await_refresh(repo)
      %{root: dir, repo: repo, events_registry: events_registry}
    end

    test "loads status and branch from backend after start", %{repo: repo} do
      assert [%StatusEntry{path: "lib/foo.ex", status: :modified}] = Repo.status(repo)
      assert Repo.branch(repo) == "feat/xyz"
    end

    test "loads ahead/behind counts after start", %{tmp_dir: dir} do
      events_registry = start_events_registry()
      ab_dir = Path.join(dir, "ab")
      GitStub.set_root(ab_dir, ab_dir)
      GitStub.set_ahead_behind(ab_dir, 3, 1)
      on_exit(fn -> GitStub.clear(ab_dir) end)

      repo = start_repo(ab_dir, events_registry: events_registry)
      Repo.await_refresh(repo)

      summary = Repo.summary(repo)
      assert summary.ahead == 3
      assert summary.behind == 1
    end

    test "loads stash count after start", %{tmp_dir: dir} do
      events_registry = start_events_registry()
      stash_dir = Path.join(dir, "stashes")
      GitStub.set_root(stash_dir, stash_dir)

      GitStub.set_stashes(stash_dir, [
        %StashEntry{index: 0, ref: "stash@{0}", date: "1 minute ago", message: "WIP"}
      ])

      on_exit(fn -> GitStub.clear(stash_dir) end)

      repo = start_repo(stash_dir, events_registry: events_registry)
      Repo.await_refresh(repo)

      assert Repo.summary(repo).stash_count == 1
    end
  end

  describe "read APIs" do
    setup %{tmp_dir: dir} do
      events_registry = start_events_registry()
      GitStub.set_root(dir, dir)
      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_repo(dir, events_registry: events_registry)
      Repo.await_refresh(repo)
      %{root: dir, repo: repo, events_registry: events_registry}
    end

    test "status returns cached entries and does not re-read live stub state", %{
      root: dir,
      repo: repo
    } do
      assert Repo.status(repo) == []

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
      events_registry = start_events_registry()
      GitStub.set_root(dir, dir)
      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_repo(dir, events_registry: events_registry)
      Repo.await_refresh(repo)
      %{root: dir, repo: repo, events_registry: events_registry}
    end

    test "re-reads status and branch from backend", %{root: dir, repo: repo} do
      assert Repo.status(repo) == []
      assert Repo.branch(repo) == "main"

      entry = %StatusEntry{path: "changed.ex", status: :modified, staged: false}
      GitStub.set_status(dir, [entry])
      GitStub.set_branch(dir, "develop")

      Repo.refresh(repo)
      Repo.await_refresh(repo)

      assert Repo.status(repo) == [entry]
      assert Repo.branch(repo) == "develop"
    end

    test "keeps cached status when a later status refresh fails", %{root: dir, repo: repo} do
      entry = %StatusEntry{path: "changed.ex", status: :modified, staged: false}
      GitStub.set_status(dir, [entry])
      Repo.refresh(repo)
      Repo.await_refresh(repo)
      assert Repo.status(repo) == [entry]

      GitStub.set_status_error(dir, "status timed out")
      GitStub.set_branch(dir, "still-updates")

      Repo.refresh(repo)
      Repo.await_refresh(repo)

      assert Repo.status(repo) == [entry]
      assert Repo.branch(repo) == "still-updates"
    end

    test "refresh publishes git_status_changed when status changes", %{
      root: dir,
      repo: repo,
      events_registry: events_registry
    } do
      Events.subscribe(:git_status_changed, events_registry)
      entry = %StatusEntry{path: "new.ex", status: :added, staged: true}
      GitStub.set_status(dir, [entry])

      Repo.refresh(repo)

      assert_receive {:minga_event, :git_status_changed,
                      %Events.GitStatusEvent{git_root: ^dir, entries: [^entry]}}
    end

    test "refresh does not publish event when status is unchanged", %{
      root: dir,
      repo: repo,
      events_registry: events_registry
    } do
      Events.subscribe(:git_status_changed, events_registry)

      Repo.refresh(repo)
      Repo.await_refresh(repo)

      refute_receive {:minga_event, :git_status_changed, %{git_root: ^dir}}, 50
    end

    test "refresh publishes a new HEAD even when the full commit message is unchanged", %{
      root: dir,
      repo: repo,
      events_registry: events_registry
    } do
      Events.subscribe(:git_status_changed, events_registry)
      body = "feat: updated subject\n\nKeep the full body."
      first = String.duplicate("a", 40)
      second = String.duplicate("b", 40)

      for oid <- [first, second] do
        GitStub.set_head_commit(dir, oid, body)
        Repo.refresh(repo)

        assert_receive {:minga_event, :git_status_changed,
                        %Events.GitStatusEvent{
                          git_root: ^dir,
                          head_oid: ^oid,
                          last_commit_message: ^body
                        }}

        assert %StatusSnapshot{head_oid: ^oid, last_commit_message: ^body} =
                 Repo.status_snapshot(repo)

        assert Repo.summary(repo).last_commit_message == body
      end
    end

    test "refresh publishes and caches stash count changes", %{
      root: dir,
      repo: repo,
      events_registry: events_registry
    } do
      Events.subscribe(:git_status_changed, events_registry)

      GitStub.set_stashes(dir, [
        %StashEntry{index: 0, ref: "stash@{0}", date: "1 minute ago", message: "WIP"}
      ])

      Repo.refresh(repo)

      assert_receive {:minga_event, :git_status_changed,
                      %Events.GitStatusEvent{git_root: ^dir, stash_count: 1}}

      assert Repo.summary(repo).stash_count == 1
    end

    test "loose branch and packed ref events both observe the new commit", %{
      root: dir,
      repo: repo,
      events_registry: events_registry
    } do
      Events.subscribe(:git_status_changed, events_registry)

      for {file, digit} <- [{"refs/heads/feature/nested", "a"}, {"packed-refs", "b"}] do
        oid = String.duplicate(digit, 40)
        GitStub.set_head_commit(dir, oid, "same message")
        send(repo, {:file_event, self(), {Path.join([dir, ".git", file]), []}})

        assert_receive {:minga_event, :git_status_changed,
                        %Events.GitStatusEvent{git_root: ^dir, head_oid: ^oid}},
                       1_000
      end
    end

    test "stash ref file events refresh stash count", %{
      root: dir,
      repo: repo,
      events_registry: events_registry
    } do
      Events.subscribe(:git_status_changed, events_registry)

      GitStub.set_stashes(dir, [
        %StashEntry{index: 0, ref: "stash@{0}", date: "1 minute ago", message: "WIP"}
      ])

      send(repo, {:file_event, self(), {Path.join([dir, ".git", "refs", "stash"]), []}})
      send(repo, :debounce_refresh)

      assert_receive {:minga_event, :git_status_changed,
                      %Events.GitStatusEvent{git_root: ^dir, stash_count: 1}}
    end

    test "stash log file events refresh stash count", %{
      root: dir,
      repo: repo,
      events_registry: events_registry
    } do
      Events.subscribe(:git_status_changed, events_registry)

      GitStub.set_stashes(dir, [
        %StashEntry{index: 0, ref: "stash@{0}", date: "1 minute ago", message: "WIP"}
      ])

      send(repo, {:file_event, self(), {Path.join([dir, ".git", "logs", "refs", "stash"]), []}})
      send(repo, :debounce_refresh)

      assert_receive {:minga_event, :git_status_changed,
                      %Events.GitStatusEvent{git_root: ^dir, stash_count: 1}}
    end

    test "refresh publishes git_status_changed when branch changes", %{
      root: dir,
      repo: repo,
      events_registry: events_registry
    } do
      Events.subscribe(:git_status_changed, events_registry)
      GitStub.set_branch(dir, "feature/new")

      Repo.refresh(repo)

      assert_receive {:minga_event, :git_status_changed,
                      %Events.GitStatusEvent{git_root: ^dir, branch: "feature/new"}}
    end
  end

  describe "summary" do
    setup %{tmp_dir: dir} do
      events_registry = start_events_registry()
      GitStub.set_root(dir, dir)

      GitStub.set_status(dir, [
        %StatusEntry{path: "a.ex", status: :modified, staged: true},
        %StatusEntry{path: "b.ex", status: :modified, staged: false},
        %StatusEntry{path: "c.ex", status: :untracked, staged: false},
        %StatusEntry{path: "d.ex", status: :conflict, staged: false},
        %StatusEntry{path: "e.ex", status: :added, staged: true}
      ])

      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_repo(dir, events_registry: events_registry)
      Repo.await_refresh(repo)
      %{root: dir, repo: repo, events_registry: events_registry}
    end

    test "aggregates counts by category", %{repo: repo} do
      summary = Repo.summary(repo)
      assert summary.staged_count == 2
      assert summary.unstaged_count == 1
      assert summary.untracked_count == 1
      assert summary.conflict_count == 1
      assert summary.stash_count == 0
    end

    test "with zero entries returns all-zero counts", %{tmp_dir: dir} do
      events_registry = start_events_registry()
      empty_dir = Path.join(dir, "empty")
      GitStub.set_root(empty_dir, empty_dir)
      on_exit(fn -> GitStub.clear(empty_dir) end)

      repo = start_repo(empty_dir, events_registry: events_registry)
      Repo.await_refresh(repo)
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
      events_registry = start_events_registry()
      conflict_dir = Path.join(dir, "conflict")
      GitStub.set_root(conflict_dir, conflict_dir)

      GitStub.set_status(conflict_dir, [
        %StatusEntry{path: "x.ex", status: :conflict, staged: true}
      ])

      on_exit(fn -> GitStub.clear(conflict_dir) end)

      repo = start_repo(conflict_dir, events_registry: events_registry)
      Repo.await_refresh(repo)
      summary = Repo.summary(repo)

      assert summary.conflict_count == 1
      assert summary.staged_count == 0
    end
  end

  describe "path relativization" do
    test "snapshot and event agree on entries and their nested project base", %{tmp_dir: dir} do
      events_registry = start_events_registry()
      Events.subscribe(:git_status_changed, events_registry)
      git_root = dir
      project_root = Path.join(dir, "apps/myapp")

      GitStub.set_root(git_root, git_root)

      GitStub.set_status(git_root, [
        %StatusEntry{path: "apps/myapp/lib/foo.ex", status: :modified, staged: false},
        %StatusEntry{path: "apps/other/lib/bar.ex", status: :modified, staged: false}
      ])

      GitStub.set_branch(git_root, "feature/nested")
      GitStub.set_ahead_behind(git_root, 3, 1)
      GitStub.set_head_commit(git_root, String.duplicate("a", 40), "feat: nested project")

      GitStub.set_stashes(git_root, [
        %StashEntry{index: 0, ref: "stash@{0}", date: "1 minute ago", message: "WIP"}
      ])

      on_exit(fn -> GitStub.clear(git_root) end)

      repo = start_repo(git_root, project_root: project_root, events_registry: events_registry)
      Repo.await_refresh(repo)

      entry = %StatusEntry{path: "lib/foo.ex", status: :modified, staged: false}
      assert [^entry] = Repo.status(repo)

      assert %StatusSnapshot{
               git_root: ^git_root,
               entry_base_path: ^project_root,
               entries: [^entry],
               branch: "feature/nested",
               ahead: 3,
               behind: 1,
               last_commit_message: "feat: nested project",
               stash_count: 1
             } = Repo.status_snapshot(repo)

      assert_receive {:minga_event, :git_status_changed,
                      %Events.GitStatusEvent{
                        git_root: ^git_root,
                        entry_base_path: ^project_root,
                        entries: [^entry]
                      }}
    end

    test "paths unchanged when project_root equals git_root", %{tmp_dir: dir} do
      events_registry = start_events_registry()
      GitStub.set_root(dir, dir)

      GitStub.set_status(dir, [
        %StatusEntry{path: "lib/foo.ex", status: :modified, staged: false}
      ])

      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_repo(dir, project_root: dir, events_registry: events_registry)
      Repo.await_refresh(repo)

      assert [%StatusEntry{path: "lib/foo.ex"}] = Repo.status(repo)
    end

    test "paths unchanged when project_root is nil", %{tmp_dir: dir} do
      events_registry = start_events_registry()
      GitStub.set_root(dir, dir)

      GitStub.set_status(dir, [
        %StatusEntry{path: "lib/foo.ex", status: :modified, staged: false}
      ])

      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_repo(dir, events_registry: events_registry)
      Repo.await_refresh(repo)

      assert [%StatusEntry{path: "lib/foo.ex"}] = Repo.status(repo)
    end
  end

  describe "lookup" do
    test "returns nil when no repo exists for path" do
      assert Repo.lookup("/nonexistent/path") == nil
    end

    test "returns pid when repo exists", %{tmp_dir: dir} do
      events_registry = start_events_registry()
      GitStub.set_root(dir, dir)
      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_repo(dir, events_registry: events_registry)
      assert Repo.lookup(dir) == repo
    end

    test "cached_status_for_path returns cached entries for containing tracked repo", %{
      tmp_dir: dir
    } do
      events_registry = start_events_registry()
      GitStub.set_root(dir, dir)
      entry = %StatusEntry{path: "lib/foo.ex", status: :modified, staged: false}
      GitStub.set_status(dir, [entry])
      on_exit(fn -> GitStub.clear(dir) end)

      _repo = start_repo(dir, events_registry: events_registry) |> tap(&Repo.await_refresh/1)

      assert {:ok, %StatusSnapshot{git_root: ^dir, entry_base_path: ^dir, entries: [^entry]}} =
               Repo.cached_status_for_path(Path.join(dir, "lib/foo.ex"))
    end

    test "cached reads use the most specific tracked repo for the expanded path", %{tmp_dir: dir} do
      events_registry = start_events_registry()
      parent = Path.join(dir, "parent")
      child = Path.join(parent, "apps/child")
      File.mkdir_p!(child)

      child_entry = %StatusEntry{path: "lib/child.ex", status: :added, staged: true}
      GitStub.set_root(parent, parent)
      GitStub.set_root(child, child)
      GitStub.set_status_error(parent, "git status failed: git command timed out after 4000ms")
      GitStub.set_status(child, [child_entry])
      on_exit(fn -> GitStub.clear(parent) end)
      on_exit(fn -> GitStub.clear(child) end)

      start_repo(parent, events_registry: events_registry) |> Repo.await_refresh()
      start_repo(child, events_registry: events_registry) |> Repo.await_refresh()

      path = parent <> "/apps/../apps/child/lib/child.ex"

      assert {:ok, %StatusSnapshot{git_root: ^child, entries: [^child_entry]}} =
               Repo.cached_status_for_path(path)

      assert Repo.cached_degraded_for_path(parent) == {:ok, {true, :status_timeout}}
      assert Repo.cached_degraded_for_path(path) == {:ok, {false, nil}}

      sibling = Path.join(parent, "apps/childish/lib/sibling.ex")
      assert Repo.cached_degraded_for_path(sibling) == {:ok, {true, :status_timeout}}
    end

    test "cached reads do not start an untracked repo", %{tmp_dir: dir} do
      GitStub.set_root(dir, dir)
      on_exit(fn -> GitStub.clear(dir) end)
      path = Path.join(dir, "missing.ex")

      assert Repo.cached_status_for_path(path) == :not_tracked
      assert Repo.cached_degraded_for_path(path) == :not_tracked
      assert Repo.lookup(dir) == nil
    end

    test "cached degradation requests only the flag and reason and handles a repo exit", %{
      tmp_dir: dir
    } do
      test_pid = self()

      repo =
        Task.async(fn ->
          {:ok, _} = Registry.register(Minga.Git.Repo.Registry, dir, nil)
          send(test_pid, {:registered, self()})

          # Exit after receiving the call, without replying.
          receive do
            {:"$gen_call", _from, request} -> request
          end
        end)

      repo_pid = repo.pid
      assert_receive {:registered, ^repo_pid}
      assert Repo.cached_degraded_for_path(dir) == :not_tracked
      assert Task.await(repo) == :degraded
    end
  end

  describe "degraded status" do
    test "flags degraded and keeps cached entries when status times out on a full checkout", %{
      tmp_dir: dir
    } do
      events_registry = start_events_registry()
      GitStub.set_root(dir, dir)
      entry = %StatusEntry{path: "lib/foo.ex", status: :modified, staged: false}
      GitStub.set_status(dir, [entry])
      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_repo(dir, events_registry: events_registry)
      Repo.await_refresh(repo)

      # Healthy to start.
      assert {false, nil} = Repo.degraded(repo)
      assert [^entry] = Repo.status(repo)

      # A subsequent status times out; the repo (full checkout, untracked :normal)
      # must surface this visibly instead of dropping the cached entries.
      GitStub.set_status_error(dir, "git status failed: git command timed out after 4000ms")
      Repo.refresh(repo)
      Repo.await_refresh(repo)

      assert {true, :status_timeout} = Repo.degraded(repo)
      assert [^entry] = Repo.status(repo)
      assert Repo.summary(repo).degraded?

      assert {:ok, %StatusSnapshot{degraded?: true, degraded_reason: :status_timeout}} =
               Repo.cached_status_for_path(Path.join(dir, "lib/foo.ex"))

      assert Repo.cached_degraded_for_path(Path.join(dir, "lib/foo.ex")) ==
               {:ok, {true, :status_timeout}}
    end

    test "clears the degraded flag once status succeeds again", %{tmp_dir: dir} do
      events_registry = start_events_registry()
      GitStub.set_root(dir, dir)
      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_repo(dir, events_registry: events_registry)
      Repo.await_refresh(repo)

      GitStub.set_status_error(dir, "git status failed: git command timed out after 4000ms")
      Repo.refresh(repo)
      Repo.await_refresh(repo)
      assert {true, :status_timeout} = Repo.degraded(repo)

      GitStub.set_status(dir, [%StatusEntry{path: "a.ex", status: :modified, staged: false}])
      Repo.refresh(repo)
      Repo.await_refresh(repo)

      assert {false, nil} = Repo.degraded(repo)
    end

    test "a non-timeout status error does not flag degraded", %{tmp_dir: dir} do
      events_registry = start_events_registry()
      GitStub.set_root(dir, dir)
      on_exit(fn -> GitStub.clear(dir) end)

      repo = start_repo(dir, events_registry: events_registry)
      Repo.await_refresh(repo)

      GitStub.set_status_error(dir, "git status failed: fatal: not a git repository")
      Repo.refresh(repo)
      Repo.await_refresh(repo)

      assert {false, nil} = Repo.degraded(repo)
    end
  end

  @spec start_events_registry() :: atom()
  defp start_events_registry do
    name = :"repo_events_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({Events, name: name}, id: {Events, name})
    name
  end

  @spec start_repo(String.t(), keyword()) :: pid()
  defp start_repo(git_root, opts) do
    opts = Keyword.put(opts, :git_root, git_root)
    start_supervised!({Repo, opts}, id: {Repo, git_root})
  end
end
