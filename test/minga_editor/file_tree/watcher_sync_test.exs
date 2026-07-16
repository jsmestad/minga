defmodule MingaEditor.FileTree.WatcherSyncTest do
  @moduledoc "Deterministic watcher serialization, lineage, and workflow tests."

  use ExUnit.Case, async: true

  alias Minga.Project.FileTree
  alias Minga.Test.FileTreeFilterScanner
  alias Minga.Test.FileTreeRefreshScanner
  alias Minga.Test.FileTreeWatcherBackend
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileTree.FilterWalk
  alias MingaEditor.FileTree.FilterWalk.Result, as: FilterResult
  alias MingaEditor.FileTree.Freshness
  alias MingaEditor.FileTree.Refresh
  alias MingaEditor.FileTree.WatcherSync
  alias MingaEditor.State.FileTree, as: FileTreeState

  import ExUnit.CaptureLog
  import MingaEditor.RenderPipeline.TestHelpers

  @moduletag :tmp_dir
  @timeout 2_000

  test "watcher calls execute in the worker and outcome application is service-free", %{
    tmp_dir: root
  } do
    scheduler = start_scheduler()
    state = state_with_tree(root, scheduler)

    state =
      Freshness.synchronize_watchers(state,
        watcher_backend: FileTreeWatcherBackend,
        watcher_context: {self(), :initial, :immediate}
      )

    request_id = file_tree(state).watchers.request.token

    assert_receive {:file_tree_watcher_call, :initial, :watch, ^root, worker}, @timeout
    assert worker != self()

    outcome = receive_outcome(scheduler, request_id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, outcome)
    assert {state, %Outcome{status: :completed} = applied} = WatcherSync.apply(state, outcome)
    refute_receive {:file_tree_watcher_call, :initial, _, _, _}
    EffectScheduler.finalize(scheduler, applied)

    assert file_tree(state).watchers.candidates == MapSet.new([root])
    assert file_tree(state).watchers.target == root
  end

  test "queued watcher intents coalesce full cleanup lineage and retain newest target", %{
    tmp_dir: root
  } do
    a = Path.join(root, "a")
    b = Path.join(root, "b")
    c = Path.join(root, "c")
    scheduler = start_scheduler()

    blocker =
      watcher_request([a], nil, [], :blocker, :wait)

    b_request =
      watcher_request([a, b], b, [b], :b, :immediate)

    c_request =
      watcher_request([a, b, c], c, [c], :c, :immediate)

    assert EffectScheduler.schedule(scheduler, blocker) == {:ok, blocker.id, :running}
    assert_receive {:file_tree_watcher_call, :blocker, :unwatch, ^a, blocker_worker}, @timeout
    assert EffectScheduler.schedule(scheduler, b_request) == {:ok, b_request.id, :queued}
    assert EffectScheduler.schedule(scheduler, c_request) == {:ok, c_request.id, :queued}

    send(blocker_worker, {:release_file_tree_watcher_call, :blocker, :unwatch, a, :ok})
    blocker_outcome = receive_outcome(scheduler, blocker.id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, blocker_outcome)
    EffectScheduler.finalize(scheduler, blocker_outcome)

    assert_receive {:file_tree_watcher_call, :c, :unwatch, ^a, c_worker}, @timeout
    assert_receive {:file_tree_watcher_call, :c, :unwatch, ^b, ^c_worker}, @timeout
    assert_receive {:file_tree_watcher_call, :c, :watch, ^c, ^c_worker}, @timeout

    c_outcome = receive_outcome(scheduler, c_request.id, :completed)
    assert c_outcome.request.effect.candidates == MapSet.new([a, b, c])
    assert c_outcome.request.effect.target == c
  end

  test "an old-root success cannot cancel the current reroot retry", %{tmp_dir: root} do
    a = Path.join(root, "a")
    b = Path.join(root, "b")
    old_token = make_ref()
    retry_token = make_ref()

    file_tree =
      %FileTreeState{}
      |> FileTreeState.open(tree(a), nil)
      |> FileTreeState.track_watcher_request(old_token)
      |> FileTreeState.begin_root_scan(tree(b), :project)

    {1, file_tree} = FileTreeState.schedule_watcher_retry(file_tree, retry_token)

    assert {:stale, retained} = FileTreeState.accept_watcher_result(file_tree, old_token, a)
    assert retained.watchers.target == Path.expand(b)
    assert retained.watchers.candidates == MapSet.new([Path.expand(a), Path.expand(b)])
    assert retained.watchers.retry_token == retry_token
    assert retained.watchers.retry_attempt == 1
  end

  test "partial watcher failure retains lineage and automatically retries", %{tmp_dir: root} do
    a = Path.join(root, "a")
    b = Path.join(root, "b")
    scheduler = start_scheduler()
    state = state_with_tree(a, scheduler) |> establish_owned_root(a, scheduler)
    state = retarget_state(state, b)
    context = {self(), :partial, :wait}

    state =
      Freshness.synchronize_watchers(state,
        watcher_backend: FileTreeWatcherBackend,
        watcher_context: context
      )

    failed_id = file_tree(state).watchers.request.token
    assert_receive {:file_tree_watcher_call, :partial, :unwatch, ^a, failed_worker}, @timeout
    send(failed_worker, {:release_file_tree_watcher_call, :partial, :unwatch, a, :ok})
    assert_receive {:file_tree_watcher_call, :partial, :watch, ^b, ^failed_worker}, @timeout

    send(
      failed_worker,
      {:release_file_tree_watcher_call, :partial, :watch, b, {:error, :unavailable}}
    )

    failed = receive_outcome(scheduler, failed_id, :failed)
    assert :ok = EffectScheduler.claim(scheduler, failed)

    {{state, %Outcome{status: :failed} = applied_failure}, log} =
      with_log(fn -> WatcherSync.apply(state, failed) end)

    EffectScheduler.finalize(scheduler, applied_failure)
    assert log =~ "File tree watcher sync failed"
    assert file_tree(state).watchers.candidates == MapSet.new([a, b])
    assert file_tree(state).watchers.target == b
    assert file_tree(state).watchers.request == nil
    assert file_tree(state).watchers.retry_attempt == 1
    retry_token = file_tree(state).watchers.retry_token

    assert_receive {:file_tree_watcher_retry, ^retry_token, retry_opts}, @timeout

    assert {:noreply, state} =
             MingaEditor.handle_info({:file_tree_watcher_retry, retry_token, retry_opts}, state)

    recovered_id = file_tree(state).watchers.request.token

    assert_receive {:file_tree_watcher_call, :partial, :unwatch, ^a, recovered_worker}, @timeout
    send(recovered_worker, {:release_file_tree_watcher_call, :partial, :unwatch, a, :ok})
    assert_receive {:file_tree_watcher_call, :partial, :watch, ^b, ^recovered_worker}, @timeout
    send(recovered_worker, {:release_file_tree_watcher_call, :partial, :watch, b, :ok})

    recovered = receive_outcome(scheduler, recovered_id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, recovered)

    assert {state, %Outcome{status: :completed} = applied_recovery} =
             WatcherSync.apply(state, recovered)

    EffectScheduler.finalize(scheduler, applied_recovery)
    assert file_tree(state).watchers.candidates == MapSet.new([b])
    assert file_tree(state).watchers.retry_token == nil
    assert file_tree(state).watchers.retry_attempt == 0
  end

  test "watcher recovery stops visibly after the bounded retry budget", %{tmp_dir: root} do
    a = Path.join(root, "a")
    b = Path.join(root, "b")
    scheduler = start_scheduler()

    state =
      state_with_tree(a, scheduler) |> establish_owned_root(a, scheduler) |> retarget_state(b)

    context = {self(), :exhausted, :wait}

    state =
      Enum.reduce(1..6, state, fn attempt, current ->
        current =
          if attempt == 1 do
            Freshness.synchronize_watchers(current,
              watcher_backend: FileTreeWatcherBackend,
              watcher_context: context
            )
          else
            assert_receive {:file_tree_watcher_retry, retry_token, retry_opts}, @timeout

            assert {:noreply, retried} =
                     MingaEditor.handle_info(
                       {:file_tree_watcher_retry, retry_token, retry_opts},
                       current
                     )

            retried
          end

        request_id = file_tree(current).watchers.request.token
        assert_receive {:file_tree_watcher_call, :exhausted, :unwatch, ^a, worker}, @timeout

        send(
          worker,
          {:release_file_tree_watcher_call, :exhausted, :unwatch, a, {:error, :unavailable}}
        )

        failed = receive_outcome(scheduler, request_id, :failed)
        assert :ok = EffectScheduler.claim(scheduler, failed)

        assert {failed_state, %Outcome{status: :failed} = applied} =
                 WatcherSync.apply(current, failed)

        EffectScheduler.finalize(scheduler, applied)
        assert file_tree(failed_state).watchers.retry_attempt == attempt
        failed_state
      end)

    assert file_tree(state).watchers.retry_token == nil

    assert state.shell_runtime.state.notice.message ==
             "File tree watcher recovery stopped after 6 attempts"

    refute_receive {:file_tree_watcher_retry, _token, _opts}, 100
  end

  test "A to B filter-winning reroot followed by C leaves only C owned", %{tmp_dir: root} do
    a = Path.join(root, "a")
    b = Path.join(root, "b")
    c = Path.join(root, "c")
    Enum.each([a, b, c], &File.mkdir_p!/1)

    scheduler = start_scheduler()
    state = state_with_tree(a, scheduler) |> establish_owned_root(a, scheduler)

    state =
      Freshness.reroot(state, b,
        scanner: FileTreeRefreshScanner,
        scanner_context: {self(), :b_refresh, :wait},
        watcher_backend: FileTreeWatcherBackend,
        watcher_context: {self(), :unused_b_refresh, :immediate}
      )

    b_refresh_id = file_tree(state).refresh.current.token
    assert_receive {:file_tree_scan_started, :b_refresh, b_refresh_worker}, @timeout

    b_filter_result = FilterResult.filesystem(b, "needle", [entry(b, "needle.ex")])

    state =
      Freshness.update_filter(state, "needle",
        scanner: FileTreeFilterScanner,
        scanner_context: {self(), :b_filter, {:return, b_filter_result}},
        watcher_backend: FileTreeWatcherBackend,
        watcher_context: {self(), :b_watchers, :wait}
      )

    b_filter_id = file_tree(state).filter_request.token
    assert_receive {:file_tree_filter_scan_started, :b_filter, _worker}, @timeout
    b_filter = receive_outcome(scheduler, b_filter_id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, b_filter)

    assert {state, %Outcome{status: :completed} = applied_filter} =
             FilterWalk.apply(state, b_filter)

    EffectScheduler.finalize(scheduler, applied_filter)
    assert_receive {:file_tree_watcher_call, :b_watchers, :unwatch, ^a, b_watcher}, @timeout

    send(b_refresh_worker, {:release_file_tree_scan, :b_refresh, {:return, tree(b)}})
    stale_refresh = receive_outcome(scheduler, b_refresh_id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, stale_refresh)

    assert {state, %Outcome{status: :stale} = applied_stale_refresh} =
             Refresh.apply(state, stale_refresh)

    EffectScheduler.finalize(scheduler, applied_stale_refresh)

    state =
      Freshness.reroot(state, c,
        scanner: FileTreeRefreshScanner,
        scanner_context: {self(), :c_refresh, {:return, tree(c)}},
        watcher_backend: FileTreeWatcherBackend,
        watcher_context: {self(), :c_watchers, :immediate}
      )

    c_refresh_id = file_tree(state).refresh.current.token
    assert file_tree(state).watchers.candidates == MapSet.new([a, b, c])
    assert_receive {:file_tree_scan_started, :c_refresh, _worker}, @timeout
    c_refresh = receive_outcome(scheduler, c_refresh_id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, c_refresh)

    assert {state, %Outcome{status: :completed} = applied_c_refresh} =
             Refresh.apply(state, c_refresh)

    EffectScheduler.finalize(scheduler, applied_c_refresh)

    send(b_watcher, {:release_file_tree_watcher_call, :b_watchers, :unwatch, a, :ok})
    assert_receive {:file_tree_watcher_call, :b_watchers, :watch, ^b, ^b_watcher}, @timeout
    send(b_watcher, {:release_file_tree_watcher_call, :b_watchers, :watch, b, :ok})

    b_watchers = receive_outcome_by_handler(scheduler, WatcherSync, :completed)
    assert :ok = EffectScheduler.claim(scheduler, b_watchers)

    assert {state, %Outcome{status: :stale} = stale_b_watchers} =
             WatcherSync.apply(state, b_watchers)

    EffectScheduler.finalize(scheduler, stale_b_watchers)

    assert_receive {:file_tree_watcher_call, :c_watchers, :unwatch, ^a, c_watcher}, @timeout
    assert_receive {:file_tree_watcher_call, :c_watchers, :unwatch, ^b, ^c_watcher}, @timeout
    assert_receive {:file_tree_watcher_call, :c_watchers, :watch, ^c, ^c_watcher}, @timeout

    c_watchers = receive_outcome_by_handler(scheduler, WatcherSync, :completed)
    assert :ok = EffectScheduler.claim(scheduler, c_watchers)

    assert {state, %Outcome{status: :completed} = applied_c_watchers} =
             WatcherSync.apply(state, c_watchers)

    EffectScheduler.finalize(scheduler, applied_c_watchers)
    assert file_tree(state).watchers.candidates == MapSet.new([c])
    assert file_tree(state).watchers.target == c
    cancel_render_timer(state)
  end

  test "root-scan failure keeps the visible error and schedules cleanup in a worker", %{
    tmp_dir: root
  } do
    a = Path.join(root, "a")
    missing = Path.join(root, "missing")
    File.mkdir_p!(a)
    scheduler = start_scheduler()
    state = state_with_tree(a, scheduler) |> establish_owned_root(a, scheduler)

    state =
      Freshness.update_project_root(state, missing,
        scanner: FileTreeRefreshScanner,
        scanner_context: {self(), :missing, {:error, {:root_unavailable, :enoent}}},
        watcher_backend: FileTreeWatcherBackend,
        watcher_context: {self(), :cleanup, :immediate}
      )

    refresh_id = file_tree(state).refresh.current.token
    assert_receive {:file_tree_scan_started, :missing, _worker}, @timeout
    failed = receive_outcome(scheduler, refresh_id, :failed)
    assert :ok = EffectScheduler.claim(scheduler, failed)
    assert {state, %Outcome{status: :failed} = applied_failure} = Refresh.apply(state, failed)
    EffectScheduler.finalize(scheduler, applied_failure)

    assert {:error, _reason} = FileTreeState.status(file_tree(state))
    assert file_tree(state).tree.root == missing
    assert_receive {:file_tree_watcher_call, :cleanup, :unwatch, ^a, worker}, @timeout
    assert worker != self()
    assert_receive {:file_tree_watcher_call, :cleanup, :unwatch, ^missing, ^worker}, @timeout

    cleanup = receive_outcome_by_handler(scheduler, WatcherSync, :completed)
    assert :ok = EffectScheduler.claim(scheduler, cleanup)

    assert {state, %Outcome{status: :completed} = applied_cleanup} =
             WatcherSync.apply(state, cleanup)

    EffectScheduler.finalize(scheduler, applied_cleanup)
    assert file_tree(state).watchers.candidates == MapSet.new()
    cancel_render_timer(state)
  end

  defp establish_owned_root(state, root, scheduler) do
    state =
      Freshness.synchronize_watchers(state,
        watcher_backend: FileTreeWatcherBackend,
        watcher_context: {self(), {:establish, root}, :immediate}
      )

    request_id = file_tree(state).watchers.request.token

    assert_receive {:file_tree_watcher_call, {:establish, ^root}, :watch, ^root, _worker},
                   @timeout

    outcome = receive_outcome(scheduler, request_id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, outcome)
    assert {state, %Outcome{status: :completed} = applied} = WatcherSync.apply(state, outcome)
    EffectScheduler.finalize(scheduler, applied)
    state
  end

  defp retarget_state(state, root) do
    file_tree = FileTreeState.begin_root_scan(file_tree(state), tree(root), :reroot)
    put_file_tree(state, file_tree)
  end

  defp watcher_request(candidates, target, expanded_dirs, label, mode) do
    WatcherSync.request(MapSet.new(candidates), target, MapSet.new(expanded_dirs),
      watcher_backend: FileTreeWatcherBackend,
      watcher_context: {self(), label, mode}
    )
  end

  defp state_with_tree(root, scheduler) do
    file_tree = FileTreeState.open(%FileTreeState{}, tree(root), nil)
    state = base_state(backend: :tui)
    state = %{state | effect_scheduler: scheduler}
    put_file_tree(state, file_tree)
  end

  defp put_file_tree(state, file_tree) do
    %{state | workspace: MingaEditor.Session.State.set_file_tree(state.workspace, file_tree)}
  end

  defp tree(root), do: root |> FileTree.new() |> FileTree.put_entries([])

  defp entry(root, name) do
    %{
      path: Path.join(root, name),
      name: name,
      dir?: false,
      depth: 0,
      last_child?: true,
      guides: []
    }
  end

  defp receive_outcome(scheduler, request_id, status) do
    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %{id: ^request_id}, status: ^status} = outcome},
                   @timeout

    outcome
  end

  defp receive_outcome_by_handler(scheduler, handler, status) do
    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %{handler: ^handler}, status: ^status} = outcome},
                   @timeout

    outcome
  end

  defp file_tree(state), do: state.workspace.file_tree

  defp cancel_render_timer(state) do
    case state.render.render_correlation.timer do
      timer when is_reference(timer) -> Process.cancel_timer(timer)
      nil -> :ok
    end
  end

  defp start_scheduler do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec({EffectScheduler, task_supervisor: task_supervisor}, id: make_ref())
      )

    :ok = EffectScheduler.attach(scheduler, self())
    scheduler
  end
end
