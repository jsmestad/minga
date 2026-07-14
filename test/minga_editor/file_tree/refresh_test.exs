defmodule MingaEditor.FileTree.RefreshTest do
  @moduledoc "Behavior tests for the typed, coalescing file-tree refresh effect."

  use ExUnit.Case, async: true

  alias Minga.Project.FileTree
  alias Minga.Test.FileTreeRefreshScanner
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileTree.Freshness
  alias MingaEditor.FileTree.Refresh
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  import MingaEditor.RenderPipeline.TestHelpers

  @moduletag :tmp_dir
  @timeout 2_000

  test "request uses stable root identity and one bounded coalesced follow-up", %{tmp_dir: root} do
    tree = tree(root)
    request = Refresh.request(tree, Minga.Events.default_registry())

    assert request.resource == {:file_tree_root, Path.expand(root)}
    assert request.operation_id == nil
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

  test "composed workflow rejects the first completion and applies only the coalesced latest tree",
       %{
         tmp_dir: root
       } do
    scheduler = start_scheduler()
    original = tree(root)
    first_tree = tree(root, ["first.ex"])
    second_tree = tree(root, ["second.ex"])
    latest_tree = tree(root, ["latest.ex"])
    first = request(original, :first_composed, :wait)
    second = request(original, :second_composed, :wait)
    latest = request(original, :latest_composed, :wait)
    state = state_with_tree(original, scheduler)

    assert EffectScheduler.schedule(scheduler, first) == {:ok, first.id, :running}

    {state, %Outcome{status: :running}} =
      Refresh.apply(state, receive_lifecycle(first.id, :running))

    assert_receive {:file_tree_scan_started, :first_composed, first_worker}, @timeout
    state = track(state, first)
    send(first_worker, {:release_file_tree_scan, :first_composed, {:return, first_tree}})
    first_outcome = receive_outcome(scheduler, first.id, :completed)

    state = invalidate_current(state)
    assert EffectScheduler.schedule(scheduler, second) == {:ok, second.id, :queued}

    {state, %Outcome{status: :queued}} =
      Refresh.apply(state, receive_lifecycle(second.id, :queued))

    state = track(state, second)

    state = invalidate_current(state)
    assert EffectScheduler.schedule(scheduler, latest) == {:ok, latest.id, :queued}
    state = track(state, latest)

    {state, %Outcome{status: :stale}} =
      Refresh.apply(state, receive_lifecycle(second.id, :stale))

    {state, %Outcome{status: :queued}} =
      Refresh.apply(state, receive_lifecycle(latest.id, :queued))

    assert :ok = EffectScheduler.claim(scheduler, first_outcome)

    assert {state, %Outcome{status: :stale} = stale_first} =
             Refresh.apply(state, first_outcome)

    assert state |> file_tree() |> then(& &1.tree) == original
    EffectScheduler.finalize(scheduler, stale_first)

    assert_receive {:file_tree_scan_started, :latest_composed, latest_worker}, @timeout
    send(latest_worker, {:release_file_tree_scan, :latest_composed, {:return, latest_tree}})
    latest_outcome = receive_outcome(scheduler, latest.id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, latest_outcome)

    assert {state, %Outcome{status: :completed} = accepted_latest} =
             Refresh.apply(state, latest_outcome)

    EffectScheduler.finalize(scheduler, accepted_latest)
    Process.cancel_timer(state.render.render_correlation.timer)
    assert state |> file_tree() |> then(& &1.tree) == latest_tree
    refute state |> file_tree() |> then(& &1.tree) == second_tree
    assert EffectScheduler.stats(scheduler).admitted == 0
    refute EffectScheduler.active?(scheduler, Refresh)
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

  defp tree(root), do: tree(root, [])

  defp tree(root, names) do
    entries =
      Enum.map(names, fn name ->
        %{
          name: name,
          path: Path.join(root, name),
          dir?: false,
          depth: 0,
          last_child?: true,
          guides: []
        }
      end)

    root |> FileTree.new() |> FileTree.put_entries(entries)
  end

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

  defp state_with_tree(tree, scheduler) do
    file_tree = FileTreeState.open(%FileTreeState{}, tree, nil)

    state = base_state(backend: :tui)
    state = %{state | effect_scheduler: scheduler}

    then(state, fn state ->
      %{
        state
        | workspace:
            then(state.workspace, fn workspace ->
              MingaEditor.Session.State.set_file_tree(workspace, file_tree)
            end)
      }
    end)
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
                  EditorState.file_tree_state(state),
                  request.effect.root,
                  request.id
                )
              )
            end)
      }
    end)
  end

  defp invalidate_current(state) do
    state = Freshness.request_refresh(state, 60_000)
    token = file_tree(state).refresh.debounce

    then(state, fn state ->
      %{
        state
        | workspace:
            then(state.workspace, fn workspace ->
              MingaEditor.Session.State.set_file_tree(
                workspace,
                (fn file_tree ->
                   {:ready, _tree, elapsed} =
                     FileTreeState.refresh_debounce_elapsed(file_tree, token)

                   elapsed
                 end).(EditorState.file_tree_state(state))
              )
            end)
      }
    end)
  end

  defp file_tree(state), do: EditorState.file_tree_state(state)

  defp assert_lifecycle(request_id, status) do
    assert %Outcome{} = receive_lifecycle(request_id, status)
  end

  defp receive_lifecycle(request_id, status) do
    assert_receive {:effect_lifecycle,
                    %Outcome{request: %{id: ^request_id}, status: ^status} = outcome},
                   @timeout

    outcome
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
