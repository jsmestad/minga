defmodule MingaEditor.FileTree.FilterWalkTest do
  @moduledoc "Deterministic typed filter-effect and workflow tests."

  use ExUnit.Case, async: true

  alias Minga.Project.FileTree
  alias Minga.Test.FileTreeFilterScanner
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileTree.FilterWalk
  alias MingaEditor.FileTree.FilterWalk.CacheOrFilesystemScanner
  alias MingaEditor.FileTree.FilterWalk.Result
  alias MingaEditor.FileTree.Freshness
  alias MingaEditor.FileTree.ProjectCache.Snapshot
  alias MingaEditor.State.FileTree, as: FileTreeState

  import MingaEditor.RenderPipeline.TestHelpers

  @moduletag :tmp_dir
  @timeout 2_000

  test "request is latest-wins and keyed by the expanded tree root", %{tmp_dir: root} do
    tree = root |> FileTree.new() |> FileTree.set_filter("needle")
    request = FilterWalk.request(tree)

    assert request.resource == {:file_tree_filter, Path.expand(root)}
    assert request.policy.mode == :latest_wins
    assert request.policy.max_queued == 0
    assert request.effect.root == Path.expand(root)
    assert request.effect.filter == "needle"
  end

  test "run uses a controllable scanner and preserves exact failures", %{tmp_dir: root} do
    tree = root |> FileTree.new() |> FileTree.set_filter("needle")
    result = Result.filesystem(root, "needle", [entry(root, "needle.ex")])

    completed = request(tree, :completed, {:return, result})
    assert FilterWalk.run(completed.effect) == {:ok, result}
    assert_receive {:file_tree_filter_scan_started, :completed, _worker}, @timeout

    failed = request(tree, :failed, {:error, :unreadable})
    assert FilterWalk.run(failed.effect) == {:error, :unreadable}
    assert_receive {:file_tree_filter_scan_started, :failed, _worker}, @timeout
  end

  test "cache scanner returns sorted final materialized entries", %{tmp_dir: root} do
    tree = root |> FileTree.new() |> FileTree.set_filter("needle")

    snapshot =
      Snapshot.new(
        root,
        true,
        ["z/needle.ex", "lib/other.ex", "a/needle.ex", ".hidden/needle.ex"],
        false
      )

    assert %Result{source: :project_cache, entries: entries, project_cache: ^snapshot} =
             CacheOrFilesystemScanner.scan(tree, snapshot)

    assert Enum.map(entries, &Path.relative_to(&1.path, root)) == [
             "a/needle.ex",
             "z/needle.ex"
           ]
  end

  test "repeated filters cancel old work and install only the exact latest outcome", %{
    tmp_dir: root
  } do
    scheduler = start_scheduler()
    state = state_with_tree(root, scheduler)

    state =
      Freshness.update_filter(state, "older",
        scanner: FileTreeFilterScanner,
        scanner_context: {self(), :older, :wait}
      )

    older_id = file_tree(state).filter_request.token
    assert_receive {:file_tree_filter_scan_started, :older, older_worker}, @timeout
    older_monitor = Process.monitor(older_worker)

    latest_result = Result.filesystem(root, "newer", [entry(root, "newer.ex")])

    state =
      Freshness.update_filter(state, "newer",
        scanner: FileTreeFilterScanner,
        scanner_context: {self(), :newer, :wait}
      )

    newer_id = file_tree(state).filter_request.token
    assert newer_id != older_id
    assert_receive {:DOWN, ^older_monitor, :process, ^older_worker, _reason}, @timeout

    assert_receive {:effect_lifecycle,
                    %Outcome{request: %{id: ^older_id}, status: :canceled} = canceled},
                   @timeout

    assert {state, %Outcome{status: :stale}} = FilterWalk.apply(state, canceled)
    assert_receive {:file_tree_filter_scan_started, :newer, newer_worker}, @timeout

    send(newer_worker, {:release_file_tree_filter_scan, :newer, {:return, latest_result}})
    outcome = receive_outcome(scheduler, newer_id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, outcome)
    assert {state, %Outcome{status: :completed} = applied} = FilterWalk.apply(state, outcome)
    EffectScheduler.finalize(scheduler, applied)

    assert Enum.map(FileTree.visible_entries(tree(state)), & &1.name) == ["newer.ex"]
    assert FileTreeState.status(file_tree(state)) == :ready
    Process.cancel_timer(state.render.render_correlation.timer)
  end

  test "a failed filter exposes an error and the next exact request recovers", %{tmp_dir: root} do
    scheduler = start_scheduler()
    state = state_with_tree(root, scheduler)

    state =
      Freshness.update_filter(state, "broken",
        scanner: FileTreeFilterScanner,
        scanner_context: {self(), :broken, {:error, :unreadable}}
      )

    broken_id = file_tree(state).filter_request.token
    assert_receive {:file_tree_filter_scan_started, :broken, _worker}, @timeout
    broken = receive_outcome(scheduler, broken_id, :failed)
    assert broken.reason == :unreadable
    assert :ok = EffectScheduler.claim(scheduler, broken)
    assert {state, %Outcome{status: :failed} = failed} = FilterWalk.apply(state, broken)
    EffectScheduler.finalize(scheduler, failed)
    assert {:error, _reason} = FileTreeState.status(file_tree(state))
    Process.cancel_timer(state.render.render_correlation.timer)

    recovered_result = Result.filesystem(root, "fixed", [entry(root, "fixed.ex")])

    state =
      Freshness.update_filter(state, "fixed",
        scanner: FileTreeFilterScanner,
        scanner_context: {self(), :fixed, {:return, recovered_result}}
      )

    fixed_id = file_tree(state).filter_request.token
    assert_receive {:file_tree_filter_scan_started, :fixed, _worker}, @timeout
    fixed = receive_outcome(scheduler, fixed_id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, fixed)
    assert {state, %Outcome{status: :completed} = applied} = FilterWalk.apply(state, fixed)
    EffectScheduler.finalize(scheduler, applied)

    assert FileTreeState.status(file_tree(state)) == :ready
    assert Enum.map(FileTree.visible_entries(tree(state)), & &1.name) == ["fixed.ex"]
    Process.cancel_timer(state.render.render_correlation.timer)
  end

  defp request(tree, label, action) do
    FilterWalk.request(tree,
      scanner: FileTreeFilterScanner,
      scanner_context: {self(), label, action}
    )
  end

  defp state_with_tree(root, scheduler) do
    tree = root |> FileTree.new() |> FileTree.put_entries([])
    file_tree = FileTreeState.open(%FileTreeState{}, tree, nil)
    state = base_state(backend: :tui)
    state = %{state | effect_scheduler: scheduler}

    %{
      state
      | workspace: MingaEditor.Session.State.set_file_tree(state.workspace, file_tree)
    }
  end

  defp start_scheduler do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec(
          {EffectScheduler, task_supervisor: task_supervisor, observer: self()},
          id: make_ref()
        )
      )

    :ok = EffectScheduler.attach(scheduler, self())
    scheduler
  end

  defp receive_outcome(scheduler, request_id, status) do
    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %{id: ^request_id}, status: ^status} = outcome},
                   @timeout

    outcome
  end

  defp file_tree(state), do: state.workspace.file_tree
  defp tree(state), do: state |> file_tree() |> FileTreeState.tree()

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
end
