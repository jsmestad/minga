defmodule MingaEditor.FileTree.RefreshTest do
  @moduledoc "Behavior tests for the typed, coalescing file-tree refresh effect."

  use ExUnit.Case, async: true

  alias Minga.Project.FileTree
  alias Minga.Test.FileTreeRefreshScanner
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileTree.Refresh

  @moduletag :tmp_dir
  @timeout 2_000

  test "request uses stable root identity and one bounded coalesced follow-up", %{tmp_dir: root} do
    tree = tree(root)
    request = Refresh.request(tree, Minga.Events.default_registry())

    assert request.resource == {:file_tree_root, Path.expand(root)}
    assert request.policy.mode == :coalescing
    assert request.policy.max_queued == 1
    assert request.effect.root == Path.expand(root)
  end

  test "run rescans through the typed effect and returns a completed tree", %{tmp_dir: root} do
    File.write!(Path.join(root, "alpha.ex"), "")
    request = request(tree(root), :completed, {:return, tree(root)})

    assert {:ok, %FileTree{root: refreshed_root}} = Refresh.run(request.effect)
    assert refreshed_root == Path.expand(root)
    assert_receive {:file_tree_scan_started, :completed, _worker}, @timeout
  end

  test "run preserves scanner failures as domain failures", %{tmp_dir: root} do
    request = request(tree(root), :failed, {:error, :unreadable})

    assert Refresh.run(request.effect) == {:error, :unreadable}
    assert_receive {:file_tree_scan_started, :failed, _worker}, @timeout
  end

  test "filesystem scanner reports an unavailable root instead of an empty tree", %{tmp_dir: root} do
    missing_root = Path.join(root, "missing")
    request = Refresh.request(tree(missing_root), Minga.Events.default_registry())

    assert Refresh.run(request.effect) == {:error, {:root_unavailable, :enoent}}
  end

  test "scheduler exposes running, queued, and exactly one coalesced follow-up", %{tmp_dir: root} do
    scheduler = start_scheduler()
    tree = tree(root)
    first = request(tree, :first, :wait)
    second = request(tree, :second, :wait)
    third = request(tree, :third, :wait)

    assert EffectScheduler.schedule(scheduler, first) == {:ok, first.id, :running}
    assert_lifecycle(first.id, :running)
    assert_receive {:file_tree_scan_started, :first, first_worker}, @timeout

    assert EffectScheduler.schedule(scheduler, second) == {:ok, second.id, :queued}
    assert_lifecycle(second.id, :queued)

    assert EffectScheduler.schedule(scheduler, third) == {:ok, third.id, :queued}
    assert_lifecycle(second.id, :stale)
    assert_lifecycle(third.id, :queued)
    assert_terminal(second.id, :stale)
    assert EffectScheduler.stats(scheduler).queued == 1

    send(first_worker, {:release_file_tree_scan, :first, {:return, tree}})
    first_outcome = receive_outcome(scheduler, first.id, :completed)
    :ok = EffectScheduler.claim(scheduler, first_outcome)
    EffectScheduler.finalize(scheduler, first_outcome)

    assert_receive {:file_tree_scan_started, :third, third_worker}, @timeout
    send(third_worker, {:release_file_tree_scan, :third, {:return, tree}})
    third_outcome = receive_outcome(scheduler, third.id, :completed)
    :ok = EffectScheduler.claim(scheduler, third_outcome)
    EffectScheduler.finalize(scheduler, third_outcome)
    assert_terminal(third.id, :completed)
  end

  test "failed work terminalizes and leaves the root schedulable", %{tmp_dir: root} do
    scheduler = start_scheduler()
    failed = request(tree(root), :failed_work, {:error, :gone})

    assert EffectScheduler.schedule(scheduler, failed) == {:ok, failed.id, :running}
    assert_lifecycle(failed.id, :running)
    assert_receive {:file_tree_scan_started, :failed_work, _worker}, @timeout
    outcome = receive_outcome(scheduler, failed.id, :failed)
    assert outcome.reason == :gone
    :ok = EffectScheduler.claim(scheduler, outcome)
    EffectScheduler.finalize(scheduler, outcome)
    assert_terminal(failed.id, :failed)

    retry = request(tree(root), :retry, {:return, tree(root)})
    assert EffectScheduler.schedule(scheduler, retry) == {:ok, retry.id, :running}
    assert_lifecycle(retry.id, :running)
    assert_receive {:file_tree_scan_started, :retry, _worker}, @timeout
    retry_outcome = receive_outcome(scheduler, retry.id, :completed)
    :ok = EffectScheduler.claim(scheduler, retry_outcome)
    EffectScheduler.finalize(scheduler, retry_outcome)
  end

  test "canceled work terminalizes and leaves the root schedulable", %{tmp_dir: root} do
    scheduler = start_scheduler()
    canceled = request(tree(root), :canceled, :wait)

    assert EffectScheduler.schedule(scheduler, canceled) == {:ok, canceled.id, :running}
    assert_lifecycle(canceled.id, :running)
    assert_receive {:file_tree_scan_started, :canceled, worker}, @timeout
    monitor = Process.monitor(worker)

    assert :ok = EffectScheduler.cancel(scheduler, canceled.id)
    outcome = receive_outcome(scheduler, canceled.id, :canceled)
    assert outcome.reason == :requested
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
    :ok = EffectScheduler.claim(scheduler, outcome)
    EffectScheduler.finalize(scheduler, outcome)
    assert_terminal(canceled.id, :canceled)

    retry = request(tree(root), :after_cancel, {:return, tree(root)})
    assert EffectScheduler.schedule(scheduler, retry) == {:ok, retry.id, :running}
    assert_lifecycle(retry.id, :running)
    assert_receive {:file_tree_scan_started, :after_cancel, _worker}, @timeout
  end

  defp tree(root), do: root |> FileTree.new() |> FileTree.put_entries([])

  defp request(tree, label, action) do
    Refresh.request(tree, Minga.Events.default_registry(),
      scanner: FileTreeRefreshScanner,
      scanner_context: {self(), label, action}
    )
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

  defp assert_lifecycle(request_id, status) do
    assert_receive {:effect_lifecycle, %Outcome{request: %{id: ^request_id}, status: ^status}},
                   @timeout
  end

  defp receive_outcome(scheduler, request_id, status) do
    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %{id: ^request_id}, status: ^status} = outcome},
                   @timeout

    outcome
  end

  defp assert_terminal(request_id, status) do
    assert_receive {:effect_terminal, %Outcome{request: %{id: ^request_id}, status: ^status}},
                   @timeout
  end
end
