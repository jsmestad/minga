defmodule MingaEditor.Handlers.GuiActionGitAsyncTest do
  @moduledoc """
  GitOps GUI actions return control to the editor immediately and apply their
  result asynchronously, so a slow `git` command never blocks the input path.
  """
  use ExUnit.Case, async: false

  alias MingaEditor.AsyncAction
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State, as: EditorState

  # Stub git backend: returns :ok without touching the real worktree. Tests only
  # assert dispatch/apply behavior, not real git side effects.
  defmodule FakeGit do
    @moduledoc false
    @spec root_for(String.t()) :: {:ok, String.t()}
    def root_for(root), do: {:ok, root}
    @spec stage(String.t(), String.t()) :: :ok
    def stage(_root, _path), do: :ok
    @spec unstage(String.t(), String.t()) :: :ok
    def unstage(_root, _path), do: :ok
    @spec unstage_all(String.t()) :: :ok
    def unstage_all(_root), do: :ok
    @spec discard(String.t(), String.t()) :: :ok
    def discard(_root, _path), do: :ok
    @spec commit(String.t(), String.t(), keyword()) :: {:ok, String.t()}
    def commit(_root, _message, _opts), do: {:ok, "abc1234"}
  end

  setup do
    previous = Application.get_env(:minga, :git_module)
    Application.put_env(:minga, :git_module, FakeGit)

    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:minga, :git_module)
        mod -> Application.put_env(:minga, :git_module, mod)
      end
    end)

    %{state: TestHelpers.base_state(sidebar_registry: table)}
  end

  test "git stage shows a pending status and offloads the work", %{state: state} do
    new_state = GuiActionHandler.dispatch(state, {:git_stage_file, "lib/foo.ex"})

    # Pending, NOT the completed "Staged ..." — the command did not run inline.
    assert EditorState.status_msg(new_state) == "Staging lib/foo.ex…"
    assert map_size(new_state.async_actions) == 1

    # The result arrives as an async message (ran in a Task), tagged for the lane.
    assert_receive {:async_action_result, :git_worktree, _token,
                    {:ok, "Staged lib/foo.ex", _git_root}}
  end

  test "git discard offloads too", %{state: state} do
    new_state = GuiActionHandler.dispatch(state, {:git_discard_file, "lib/bar.ex"})

    assert EditorState.status_msg(new_state) == "Discarding lib/bar.ex…"
    assert_receive {:async_action_result, :git_worktree, _token, {:ok, "Discarded lib/bar.ex", _}}
  end

  test "git commit returns control immediately with a pending status", %{state: state} do
    new_state = GuiActionHandler.dispatch(state, {:git_commit, "fix the thing"})

    # Pending, NOT the completed "Committed …" — git commit did not run inline.
    assert EditorState.status_msg(new_state) == "Committing…"
    assert map_size(new_state.async_actions) == 1

    # The result arrives async (ran in a Task) and carries the commit hash so the
    # success message can name it; this proves control returned before it applied.
    assert_receive {:async_action_result, :git_worktree, _token,
                    {:ok, "Committed abc1234", _git_root}}
  end

  test "git amend offloads and reports the amended hash", %{state: state} do
    new_state = GuiActionHandler.dispatch(state, {:git_commit, "reword", true})

    assert EditorState.status_msg(new_state) == "Amending…"
    assert_receive {:async_action_result, :git_worktree, _token, {:ok, "Amended abc1234", _}}
  end

  test "a stale git commit result is ignored when a newer action superseded it",
       %{state: state} do
    # First commit goes in-flight on the :git_worktree lane.
    state = GuiActionHandler.dispatch(state, {:git_commit, "first"})
    stale_token = state.async_actions[:git_worktree].running

    # A second worktree action supersedes it: advancing past the first op (as the
    # editor does once its result is applied) starts the second under a fresh
    # token, so the first op's token is no longer current.
    state = GuiActionHandler.dispatch(state, {:git_discard_file, "lib/bar.ex"})
    state = AsyncAction.advance(state, :git_worktree)
    fresh_token = state.async_actions[:git_worktree].running

    refute stale_token == fresh_token
    # The editor drops a result whose token is not the in-flight one (AC3/AC5).
    refute AsyncAction.current?(state, :git_worktree, stale_token)
    assert AsyncAction.current?(state, :git_worktree, fresh_token)
  end

  test "applying a current git result posts the success status", %{state: state} do
    applied = GuiActionHandler.apply_git_result(state, {:ok, "Staged lib/foo.ex", "/tmp/repo"})
    assert EditorState.status_msg(applied) == "Staged lib/foo.ex"
  end

  test "applying a git error surfaces it and still refreshes the repo", %{state: state} do
    applied = GuiActionHandler.apply_git_result(state, {:error, "fatal: pathspec", "/tmp/repo"})
    assert EditorState.status_msg(applied) == "Git error: fatal: pathspec"
  end

  test "a generic (2-tuple) error from a raised op is surfaced, not crashed", %{state: state} do
    # AsyncAction.safely/1 hands back {:error, reason} (no git_root) when the work
    # raises/exits/throws; apply_git_result must handle it without FunctionClause.
    applied = GuiActionHandler.apply_git_result(state, {:error, "boom"})
    assert EditorState.status_msg(applied) == "Git error: boom"
  end

  test "an unexpected result shape degrades to a failure status", %{state: state} do
    applied = GuiActionHandler.apply_git_result(state, :weird)
    assert EditorState.status_msg(applied) == "Git action failed"
  end

  test "rapid git actions serialize: the second is queued, not run concurrently",
       %{state: state} do
    state = GuiActionHandler.dispatch(state, {:git_stage_file, "a.ex"})
    state = GuiActionHandler.dispatch(state, {:git_discard_file, "b.ex"})

    lane = state.async_actions[:git_worktree]
    assert is_reference(lane.running)
    # The discard is queued behind the in-flight stage rather than racing it.
    assert length(lane.queue) == 1

    # Only the in-flight stage has reported; the discard waits for advance.
    assert_receive {:async_action_result, :git_worktree, _t, {:ok, "Staged a.ex", _}}
    refute_received {:async_action_result, :git_worktree, _t2, {:ok, "Discarded b.ex", _}}
  end
end
