defmodule MingaEditor.FileTree.FreshnessTest do
  @moduledoc "Behavior tests for file-tree refresh workflow coordination."

  use ExUnit.Case, async: true

  alias Minga.Events
  alias Minga.Git.Repo
  alias Minga.Git.StatusEntry
  alias Minga.Git.Stub, as: GitStub
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileTree.Freshness
  alias MingaEditor.FileTree.Refresh
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  import MingaEditor.RenderPipeline.TestHelpers

  @moduletag :tmp_dir

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

  test "accepted completion updates owner, syncs the buffer, then requests rendering", %{
    tmp_dir: root
  } do
    original = tree(root, [])
    buffer = BufferSync.start_buffer(original)

    state = state_with_tree(root, nil, buffer)
    state = %{state | backend: :tui}
    request = Refresh.request(original, EditorState.events_registry(state))
    tracked = track(state, request)
    refreshed = tree(root, [entry(root, "fresh.ex")])

    assert {accepted, %Outcome{status: :completed}} =
             Refresh.apply(tracked, Outcome.completed(request, refreshed))

    assert file_tree(accepted).tree == refreshed
    assert Minga.Buffer.content(buffer) =~ "fresh.ex"
    assert is_reference(accepted.render_timer)
    Process.cancel_timer(accepted.render_timer)
  end

  test "failed and canceled outcomes clear current correlation without requesting rendering", %{
    tmp_dir: root
  } do
    state = state_with_tree(root)
    state = %{state | backend: :tui}
    request = Refresh.request(file_tree(state).tree, EditorState.events_registry(state))
    tracked = track(state, request)

    assert {failed, %Outcome{status: :failed}} =
             Refresh.apply(tracked, Outcome.failed(request, :unreadable))

    assert failed.render_timer == nil
    assert failed |> file_tree() |> then(& &1.refresh.current) == nil

    retry = Refresh.request(file_tree(failed).tree, EditorState.events_registry(failed))
    retracked = track(failed, retry)

    assert {canceled, %Outcome{status: :canceled}} =
             Refresh.apply(retracked, Outcome.canceled(retry, :requested))

    assert canceled.render_timer == nil
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
    assert closed_state.render_timer == nil

    rerooted =
      state_with_tree(old_root)
      |> track(request)
      |> EditorState.update_file_tree(&FileTreeState.replace_tree(&1, tree(new_root, [])))

    assert {rerooted_state, %Outcome{status: :stale, reason: :stale}} =
             Refresh.apply(rerooted, Outcome.completed(request, refreshed))

    assert file_tree(rerooted_state).tree.root == Path.expand(new_root)
    assert rerooted_state.render_timer == nil
  end

  test "project-root replacement exposes unavailable roots as errors", %{tmp_dir: root} do
    old_root = Path.join(root, "old")
    missing_root = Path.join(root, "missing")
    File.mkdir_p!(old_root)

    updated = old_root |> state_with_tree() |> Freshness.update_project_root(missing_root)

    assert file_tree(updated).tree.root == Path.expand(missing_root)
    assert {:error, reason} = FileTreeState.status(file_tree(updated))
    assert reason != ""
  end

  test "current root failures preserve the tree and expose an error state", %{tmp_dir: root} do
    state = %{state_with_tree(root) | backend: :tui}
    request = Refresh.request(file_tree(state).tree, EditorState.events_registry(state))
    tracked = track(state, request)

    assert {failed, %Outcome{status: :failed}} =
             Refresh.apply(tracked, Outcome.failed(request, {:root_unavailable, :enoent}))

    assert file_tree(failed).tree.root == Path.expand(root)
    assert {:error, reason} = FileTreeState.status(file_tree(failed))
    assert reason != ""
    assert file_tree(failed).refresh.current == nil
    assert is_reference(failed.render_timer)
    Process.cancel_timer(failed.render_timer)
  end

  defp state_with_tree(root, scheduler \\ nil, buffer \\ nil) do
    file_tree = FileTreeState.open(%FileTreeState{}, tree(root, []), buffer)
    state = EditorState.set_file_tree(base_state(), file_tree)
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
    EditorState.update_file_tree(
      state,
      &FileTreeState.track_refresh_request(&1, request.effect.root, request.id)
    )
  end

  defp close_tree(state), do: EditorState.update_file_tree(state, &FileTreeState.close/1)
  defp file_tree(state), do: EditorState.file_tree_state(state)

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
