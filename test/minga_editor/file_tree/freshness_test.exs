defmodule MingaEditor.FileTree.FreshnessTest do
  @moduledoc "Behavior tests for file-tree refresh workflow coordination."

  use ExUnit.Case, async: true

  alias Minga.Events
  alias Minga.Git.Repo
  alias Minga.Git.StatusEntry
  alias Minga.Git.Stub, as: GitStub
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync
  alias Minga.Test.FileTreeRefreshScanner
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileTree.Freshness
  alias MingaEditor.FileTree.Refresh
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Frontend

  import MingaEditor.RenderPipeline.TestHelpers

  @moduletag :tmp_dir
  @timeout 1_000

  test "cache refresh starts a Git.Repo owner when no cache exists yet", %{tmp_dir: dir} do
    events_registry = start_events_registry()
    entry = %StatusEntry{path: "lib/foo.ex", status: :modified, staged: false}
    GitStub.set_root(dir, dir)
    GitStub.set_status(dir, [entry])

    on_exit(fn ->
      GitStub.clear(dir)
      stop_repo(dir)
    end)

    tree = FileTree.new(dir)

    assert %FileTree{} = Refresh.with_cached_git_status(tree, events_registry)
    assert repo = Repo.lookup(dir)

    Repo.await_refresh(repo)
    assert Repo.status(repo) == [entry]
  end

  test "only the current debounce timer admits a typed scheduler request", %{tmp_dir: root} do
    scheduler = start_scheduler()
    state = state_with_tree(root, scheduler)
    state = Freshness.request_refresh(state, 60_000)
    timer_token = file_tree(state).refresh.debounce

    stale_state = Freshness.begin_refresh(state, make_ref())
    assert stale_state == state
    assert EffectScheduler.stats(scheduler).admitted == 0

    scheduled_state = Freshness.begin_refresh(state, timer_token)
    current = file_tree(scheduled_state).refresh.current

    assert is_reference(current.token)
    assert current.root == Path.expand(root)
    assert EffectScheduler.active?(scheduler, Refresh)
  end

  test "scheduler pressure preserves one pending intent and retries admission", %{tmp_dir: root} do
    blocker_root = Path.join(root, "blocker")
    File.mkdir_p!(blocker_root)
    scheduler = start_scheduler(max_admitted: 1)

    blocker =
      Refresh.request(tree(blocker_root, []), Minga.Events.default_registry(),
        scanner: FileTreeRefreshScanner,
        scanner_context: {self(), :blocker, :wait}
      )

    assert EffectScheduler.schedule(scheduler, blocker) == {:ok, blocker.id, :running}
    assert EffectScheduler.stats(scheduler).admitted == 1

    old_request = Refresh.request(tree(root, []), Minga.Events.default_registry())

    state =
      root
      |> state_with_tree(scheduler)
      |> track(old_request)
      |> Freshness.request_refresh(60_000)

    assert file_tree(state).refresh.current == nil
    timer_token = file_tree(state).refresh.debounce
    retrying = Freshness.begin_refresh(state, timer_token)
    retry_token = file_tree(retrying).refresh.debounce

    assert is_reference(retry_token)
    assert retry_token != timer_token
    assert file_tree(retrying).refresh.retry_attempt == 1
    assert EffectScheduler.stats(scheduler).admitted == 1

    assert :ok = EffectScheduler.cancel(scheduler, blocker.id)

    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %{id: blocker_id}, status: :canceled} = blocker_outcome}

    assert blocker_id == blocker.id
    assert :ok = EffectScheduler.claim(scheduler, blocker_outcome)
    EffectScheduler.finalize(scheduler, blocker_outcome)

    assert_receive {:file_tree_refresh_timer, ^retry_token}
    admitted = Freshness.begin_refresh(retrying, retry_token)

    assert is_reference(file_tree(admitted).refresh.current.token)
    assert file_tree(admitted).refresh.retry_attempt == 0
    assert EffectScheduler.active?(scheduler, Refresh)
  end

  test "accepted completion updates owner, syncs the buffer, then requests rendering", %{
    tmp_dir: root
  } do
    original = tree(root, [])
    buffer = BufferSync.start_buffer(original)

    state = state_with_tree(root, nil, buffer)
    %Frontend{} = frontend = state.frontend
    state = %{state | frontend: %Frontend{frontend | backend: :tui}}
    request = Refresh.request(original, state.extension_surfaces.events_registry)
    tracked = track(state, request)
    refreshed = tree(root, [entry(root, "fresh.ex")])

    assert {accepted, %Outcome{status: :completed}} =
             Refresh.apply(tracked, Outcome.completed(request, refreshed))

    assert file_tree(accepted).tree == refreshed
    assert Minga.Buffer.content(buffer) =~ "fresh.ex"
    assert is_reference(accepted.render.render_correlation.timer)
    Process.cancel_timer(accepted.render.render_correlation.timer)
  end

  test "failed and canceled outcomes clear current correlation without requesting rendering", %{
    tmp_dir: root
  } do
    state = state_with_tree(root)
    %Frontend{} = frontend = state.frontend
    state = %{state | frontend: %Frontend{frontend | backend: :tui}}
    request = Refresh.request(file_tree(state).tree, state.extension_surfaces.events_registry)
    tracked = track(state, request)

    assert {failed, %Outcome{status: :failed}} =
             Refresh.apply(tracked, Outcome.failed(request, :unreadable))

    assert failed.render.render_correlation.timer == nil
    assert failed |> file_tree() |> then(& &1.refresh.current) == nil

    retry = Refresh.request(file_tree(failed).tree, failed.extension_surfaces.events_registry)
    retracked = track(failed, retry)

    assert {canceled, %Outcome{status: :canceled}} =
             Refresh.apply(retracked, Outcome.canceled(retry, :requested))

    assert canceled.render.render_correlation.timer == nil
    assert canceled |> file_tree() |> then(& &1.refresh.current) == nil
  end

  test "closed and rerooted completions are stale and never request rendering", %{tmp_dir: root} do
    old_root = Path.join(root, "old")
    new_root = Path.join(root, "new")
    request = Refresh.request(tree(old_root, []), Minga.Events.default_registry())
    refreshed = tree(old_root, [entry(old_root, "old.ex")])

    closed = state_with_tree(old_root) |> track(request) |> close_tree()

    assert {closed_state, %Outcome{status: :stale, reason: :stale}} =
             Refresh.apply(closed, Outcome.completed(request, refreshed))

    assert file_tree(closed_state).tree == nil
    assert closed_state.render.render_correlation.timer == nil

    rerooted =
      old_root
      |> state_with_tree()
      |> track(request)
      |> then(fn state ->
        file_tree = state |> file_tree() |> FileTreeState.replace_tree(tree(new_root, []))

        then(state, fn state ->
          %{
            state
            | workspace:
                then(state.workspace, fn workspace ->
                  MingaEditor.Session.State.set_file_tree(workspace, file_tree)
                end)
          }
        end)
      end)

    assert {rerooted_state, %Outcome{status: :stale, reason: :stale}} =
             Refresh.apply(rerooted, Outcome.completed(request, refreshed))

    assert file_tree(rerooted_state).tree.root == Path.expand(new_root)
    assert rerooted_state.render.render_correlation.timer == nil
  end

  test "project-root replacement immediately publishes loading before its scan finishes", %{
    tmp_dir: root
  } do
    old_root = Path.join(root, "old")
    new_root = Path.join(root, "new")
    Enum.each([old_root, new_root], &File.mkdir_p!/1)
    scheduler = start_scheduler()
    state = tui_state_with_tree(old_root, scheduler)

    loading =
      Freshness.update_project_root(state, new_root,
        scanner: FileTreeRefreshScanner,
        scanner_context: {self(), :project_root, :wait},
        synchronize_watchers?: false
      )

    request_id = file_tree(loading).refresh.current.token
    assert file_tree(loading).tree.root == Path.expand(new_root)
    assert file_tree(loading).tree.entries == nil
    assert FileTreeState.status(file_tree(loading)) == :loading
    assert is_reference(request_id)
    assert_receive {:file_tree_scan_started, :project_root, worker}, @timeout

    result = tree(new_root, [entry(new_root, "new.ex")])
    send(worker, {:release_file_tree_scan, :project_root, {:return, result}})
    outcome = receive_outcome(scheduler, request_id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, outcome)
    assert {loaded, %Outcome{status: :completed} = applied} = Refresh.apply(loading, outcome)
    EffectScheduler.finalize(scheduler, applied)

    assert file_tree(loaded).tree == result
    Process.cancel_timer(loaded.render.render_correlation.timer)
  end

  test "rerooted project results are stale and only the exact latest root installs", %{
    tmp_dir: root
  } do
    old_root = Path.join(root, "old")
    first_root = Path.join(root, "first")
    latest_root = Path.join(root, "latest")
    Enum.each([old_root, first_root, latest_root], &File.mkdir_p!/1)
    scheduler = start_scheduler()
    state = tui_state_with_tree(old_root, scheduler)

    first_state =
      Freshness.update_project_root(state, first_root,
        scanner: FileTreeRefreshScanner,
        scanner_context: {self(), :first_root, :wait},
        synchronize_watchers?: false
      )

    first_id = file_tree(first_state).refresh.current.token
    assert_receive {:file_tree_scan_started, :first_root, first_worker}, @timeout

    latest_state =
      Freshness.update_project_root(first_state, latest_root,
        scanner: FileTreeRefreshScanner,
        scanner_context: {self(), :latest_root, :wait},
        synchronize_watchers?: false
      )

    latest_id = file_tree(latest_state).refresh.current.token
    assert latest_id != first_id
    assert_receive {:file_tree_scan_started, :latest_root, latest_worker}, @timeout

    first_result = tree(first_root, [entry(first_root, "first.ex")])
    send(first_worker, {:release_file_tree_scan, :first_root, {:return, first_result}})
    first_outcome = receive_outcome(scheduler, first_id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, first_outcome)

    assert {latest_state, %Outcome{status: :stale, reason: :stale} = stale} =
             Refresh.apply(latest_state, first_outcome)

    EffectScheduler.finalize(scheduler, stale)

    latest_result = tree(latest_root, [entry(latest_root, "latest.ex")])
    send(latest_worker, {:release_file_tree_scan, :latest_root, {:return, latest_result}})
    latest_outcome = receive_outcome(scheduler, latest_id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, latest_outcome)

    assert {loaded, %Outcome{status: :completed} = applied} =
             Refresh.apply(latest_state, latest_outcome)

    EffectScheduler.finalize(scheduler, applied)
    assert file_tree(loaded).tree == latest_result
    Process.cancel_timer(loaded.render.render_correlation.timer)
  end

  test "project-root scan failure installs the requested root error and a later scan recovers", %{
    tmp_dir: root
  } do
    old_root = Path.join(root, "old")
    failed_root = Path.join(root, "failed")
    recovered_root = Path.join(root, "recovered")
    Enum.each([old_root, recovered_root], &File.mkdir_p!/1)
    scheduler = start_scheduler()
    state = tui_state_with_tree(old_root, scheduler)

    failing =
      Freshness.update_project_root(state, failed_root,
        scanner: FileTreeRefreshScanner,
        scanner_context: {self(), :failed_root, {:error, {:root_unavailable, :enoent}}},
        synchronize_watchers?: false
      )

    failed_id = file_tree(failing).refresh.current.token
    assert_receive {:file_tree_scan_started, :failed_root, _worker}, @timeout
    failed_outcome = receive_outcome(scheduler, failed_id, :failed)
    assert :ok = EffectScheduler.claim(scheduler, failed_outcome)

    assert {failed, %Outcome{status: :failed} = finalized_failure} =
             Refresh.apply(failing, failed_outcome)

    EffectScheduler.finalize(scheduler, finalized_failure)
    assert file_tree(failed).tree.root == Path.expand(failed_root)
    assert {:error, reason} = FileTreeState.status(file_tree(failed))
    assert reason != ""
    Process.cancel_timer(failed.render.render_correlation.timer)

    recovered_result = tree(recovered_root, [entry(recovered_root, "ok.ex")])

    recovering =
      Freshness.update_project_root(failed, recovered_root,
        scanner: FileTreeRefreshScanner,
        scanner_context: {self(), :recovered_root, {:return, recovered_result}},
        synchronize_watchers?: false
      )

    recovered_id = file_tree(recovering).refresh.current.token
    assert_receive {:file_tree_scan_started, :recovered_root, _worker}, @timeout
    recovered_outcome = receive_outcome(scheduler, recovered_id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, recovered_outcome)

    assert {recovered, %Outcome{status: :completed} = finalized_recovery} =
             Refresh.apply(recovering, recovered_outcome)

    EffectScheduler.finalize(scheduler, finalized_recovery)
    assert file_tree(recovered).tree == recovered_result
    assert FileTreeState.status(file_tree(recovered)) == :ready
    Process.cancel_timer(recovered.render.render_correlation.timer)
  end

  test "git metadata updates preserve an unavailable-root error", %{tmp_dir: root} do
    state = state_with_tree(root)
    file_tree = state |> file_tree() |> FileTreeState.refresh_failed(:enoent)

    state =
      then(state, fn state ->
        %{
          state
          | workspace:
              then(state.workspace, fn workspace ->
                MingaEditor.Session.State.set_file_tree(workspace, file_tree)
              end)
        }
      end)

    event = %Events.GitStatusEvent{
      git_root: root,
      entries: [],
      branch: nil,
      ahead: 0,
      behind: 0
    }

    from_event = Freshness.refresh_git_status(state, event)
    assert {:error, _reason} = FileTreeState.status(file_tree(from_event))

    from_cache = Freshness.refresh_git_status_from_cache(from_event)
    assert {:error, _reason} = FileTreeState.status(file_tree(from_cache))
  end

  test "current root failures preserve the tree and expose an error state", %{tmp_dir: root} do
    state = state_with_tree(root)
    %Frontend{} = frontend = state.frontend
    state = %{state | frontend: %Frontend{frontend | backend: :tui}}
    request = Refresh.request(file_tree(state).tree, state.extension_surfaces.events_registry)
    tracked = track(state, request)

    assert {failed, %Outcome{status: :failed}} =
             Refresh.apply(tracked, Outcome.failed(request, {:root_unavailable, :enoent}))

    assert file_tree(failed).tree.root == Path.expand(root)
    assert {:error, reason} = FileTreeState.status(file_tree(failed))
    assert reason != ""
    assert file_tree(failed).refresh.current == nil
    assert is_reference(failed.render.render_correlation.timer)
    Process.cancel_timer(failed.render.render_correlation.timer)
  end

  defp tui_state_with_tree(root, scheduler) do
    state = state_with_tree(root, scheduler)
    %Frontend{} = frontend = state.frontend
    %{state | frontend: %Frontend{frontend | backend: :tui}}
  end

  defp state_with_tree(root, scheduler \\ nil, buffer \\ nil) do
    file_tree = FileTreeState.open(%FileTreeState{}, tree(root, []), buffer)

    state =
      then(base_state(), fn state ->
        %{
          state
          | workspace:
              then(state.workspace, fn workspace ->
                MingaEditor.Session.State.set_file_tree(workspace, file_tree)
              end)
        }
      end)

    %{state | effect_scheduler: scheduler}
  end

  defp tree(root, entries), do: root |> FileTree.new() |> FileTree.put_entries(entries)

  defp entry(root, name) do
    %{
      name: name,
      path: Path.join(root, name),
      dir?: false,
      depth: 0,
      last_child?: true,
      guides: []
    }
  end

  defp track(state, request) do
    then(state, fn state ->
      %{
        state
        | workspace:
            then(state.workspace, fn workspace ->
              MingaEditor.Session.State.set_file_tree(
                workspace,
                FileTreeState.track_refresh_request(
                  state.workspace.file_tree,
                  request.effect.root,
                  request.id
                )
              )
            end)
      }
    end)
  end

  defp close_tree(state),
    do:
      then(state, fn state ->
        %{
          state
          | workspace:
              then(state.workspace, fn workspace ->
                MingaEditor.Session.State.set_file_tree(
                  workspace,
                  FileTreeState.close(state.workspace.file_tree)
                )
              end)
        }
      end)

  defp receive_outcome(scheduler, request_id, status) do
    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %{id: ^request_id}, status: ^status} = outcome},
                   2_000

    outcome
  end

  defp file_tree(state), do: state.workspace.file_tree

  defp start_scheduler(opts \\ []) do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec(
          {EffectScheduler,
           task_supervisor: task_supervisor, max_admitted: Keyword.get(opts, :max_admitted, 64)},
          id: make_ref()
        )
      )

    :ok = EffectScheduler.attach(scheduler, self())
    scheduler
  end

  @spec start_events_registry() :: atom()
  defp start_events_registry do
    name = :"file_tree_events_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({Events, name: name}, id: {Events, name})
    name
  end

  @spec stop_repo(String.t()) :: :ok
  defp stop_repo(git_root) do
    case Repo.lookup(git_root) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Minga.Git.Repo.Supervisor, pid)
    end
  catch
    :exit, _ -> :ok
  end
end
