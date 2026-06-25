defmodule MingaEditor.Handlers.GuiActionGitAsyncTest do
  @moduledoc """
  GitOps GUI actions return control to the editor immediately and apply their
  result asynchronously, so a slow `git` command never blocks the input path.
  """
  use ExUnit.Case, async: true

  alias Minga.Events
  alias Minga.Git.Stub
  alias MingaEditor.AsyncAction
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State, as: EditorState

  setup do
    git_root = Path.join(System.tmp_dir!(), "stub_git_#{System.unique_integer([:positive])}")
    Stub.set_root(git_root, git_root)
    Stub.set_commit_notify(git_root, self())

    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})

    on_exit(fn -> Stub.clear(git_root) end)

    state = TestHelpers.base_state(sidebar_registry: table)
    dispatch_opts = [resolve_git_root: fn -> git_root end]

    %{state: state, git_root: git_root, dispatch_opts: dispatch_opts}
  end

  test "git commit forwards message, keeps amend off, and applies the async result", %{
    state: state,
    git_root: git_root,
    dispatch_opts: opts
  } do
    new_state = GuiActionHandler.dispatch(state, {:git_commit, "fix the thing"}, opts)

    assert EditorState.status_msg(new_state) == "Committing…"
    assert map_size(new_state.async_actions) == 1
    assert_receive {:stub_git_commit, ^git_root, "fix the thing", []}

    assert_receive {:async_action_result, :git_worktree, token,
                    {:ok, "Committed stub000", ^git_root}}

    applied_state =
      apply_async_result(
        new_state,
        {:async_action_result, :git_worktree, token, {:ok, "Committed stub000", git_root}}
      )

    assert EditorState.status_msg(applied_state) == "Committed stub000"
    assert applied_state.async_actions == %{}
  end

  test "git amend forwards amend: true and applies the async result", %{
    state: state,
    git_root: git_root,
    dispatch_opts: opts
  } do
    new_state = GuiActionHandler.dispatch(state, {:git_commit, "reword", true}, opts)

    assert EditorState.status_msg(new_state) == "Amending…"
    assert_receive {:stub_git_commit, ^git_root, "reword", [amend: true]}

    assert_receive {:async_action_result, :git_worktree, token,
                    {:ok, "Amended stub000", ^git_root}}

    applied_state =
      apply_async_result(
        new_state,
        {:async_action_result, :git_worktree, token, {:ok, "Amended stub000", git_root}}
      )

    assert EditorState.status_msg(applied_state) == "Amended stub000"
    assert applied_state.async_actions == %{}
  end

  test "git commit failure preserves the legacy failure status", %{
    state: state,
    git_root: git_root,
    dispatch_opts: opts
  } do
    Stub.set_commit_result(git_root, {:error, "boom commit"})

    new_state = GuiActionHandler.dispatch(state, {:git_commit, "fail commit"}, opts)

    assert EditorState.status_msg(new_state) == "Committing…"
    assert_receive {:stub_git_commit, ^git_root, "fail commit", []}

    assert_receive {:async_action_result, :git_worktree, token,
                    {:error, "boom commit", ^git_root, "Commit failed: boom commit"}}

    applied_state =
      apply_async_result(
        new_state,
        {:async_action_result, :git_worktree, token,
         {:error, "boom commit", git_root, "Commit failed: boom commit"}}
      )

    assert EditorState.status_msg(applied_state) == "Commit failed: boom commit"
    assert applied_state.async_actions == %{}
  end

  test "git amend failure preserves the legacy failure status", %{
    state: state,
    git_root: git_root,
    dispatch_opts: opts
  } do
    Stub.set_commit_result(git_root, {:error, "boom amend"})

    new_state = GuiActionHandler.dispatch(state, {:git_commit, "fail amend", true}, opts)

    assert EditorState.status_msg(new_state) == "Amending…"
    assert_receive {:stub_git_commit, ^git_root, "fail amend", [amend: true]}

    assert_receive {:async_action_result, :git_worktree, token,
                    {:error, "boom amend", ^git_root, "Amend failed: boom amend"}}

    applied_state =
      apply_async_result(
        new_state,
        {:async_action_result, :git_worktree, token,
         {:error, "boom amend", git_root, "Amend failed: boom amend"}}
      )

    assert EditorState.status_msg(applied_state) == "Amend failed: boom amend"
    assert applied_state.async_actions == %{}
  end

  test "a stale git commit result is ignored by the editor handler", %{
    state: state,
    git_root: git_root,
    dispatch_opts: opts
  } do
    state = GuiActionHandler.dispatch(state, {:git_commit, "first"}, opts)
    assert_receive {:stub_git_commit, ^git_root, "first", []}

    assert_receive {:async_action_result, :git_worktree, stale_token,
                    {:ok, "Committed stub000", ^git_root}}

    state = GuiActionHandler.dispatch(state, {:git_discard_file, "lib/bar.ex"}, opts)
    state = AsyncAction.advance(state, :git_worktree)
    current_status = EditorState.status_msg(state)
    current_async_actions = state.async_actions

    stale_state =
      apply_async_result(
        state,
        {:async_action_result, :git_worktree, stale_token, {:ok, "Committed stub000", git_root}}
      )

    assert stale_state == state
    assert EditorState.status_msg(stale_state) == current_status
    assert stale_state.async_actions == current_async_actions
  end

  test "queued git failure is logged while a commit keeps its pending status", %{
    state: state,
    git_root: git_root,
    dispatch_opts: opts
  } do
    Events.subscribe(:log_message)
    Stub.set_stage_result(git_root, {:error, "boom stage"})

    state = GuiActionHandler.dispatch(state, {:git_stage_file, "a.ex"}, opts)
    state = GuiActionHandler.dispatch(state, {:git_commit, "keep pending"}, opts)

    assert EditorState.status_msg(state) == "Committing…"
    assert Enum.count(state.async_actions[:git_worktree].queue) == 1

    stage_token = current_git_token(state)

    {:noreply, state} =
      MingaEditor.handle_info(
        {:async_action_result, :git_worktree, stage_token, {:error, "boom stage", git_root}},
        state
      )

    assert EditorState.status_msg(state) == "Committing…"

    assert_receive {:minga_event, :log_message,
                    %Minga.Events.LogMessageEvent{text: text, level: :error}}

    assert text =~ "boom stage"

    queued_token = current_git_token(state)

    {:noreply, state} =
      MingaEditor.handle_info(
        {:async_action_result, :git_worktree, queued_token, {:ok, "Committed stub000", git_root}},
        state
      )

    assert EditorState.status_msg(state) == "Committed stub000"
    assert state.async_actions == %{}

    Events.unsubscribe(:log_message)
  end

  test "git commit surfaces not a repo asynchronously", %{state: state} do
    no_repo_opts = [resolve_git_root: fn -> nil end]

    state = GuiActionHandler.dispatch(state, {:git_commit, "msg"}, no_repo_opts)

    assert EditorState.status_msg(state) == "Committing…"
    assert_receive {:async_action_result, :git_worktree, token, :not_a_repo}

    {:noreply, state} =
      MingaEditor.handle_info(
        {:async_action_result, :git_worktree, token, :not_a_repo},
        state
      )

    assert EditorState.status_msg(state) == "Not in a git repository"
    assert state.async_actions == %{}
  end

  test "queued commit and amend keep their pending status when a prior git action finishes",
       %{state: state, git_root: git_root, dispatch_opts: opts} do
    state =
      run_queued_git_status_regression(
        state,
        git_root,
        opts,
        {:git_commit, "keep pending"},
        "Committing…",
        "Committed stub000"
      )

    _state =
      run_queued_git_status_regression(
        state,
        git_root,
        opts,
        {:git_commit, "keep pending", true},
        "Amending…",
        "Amended stub000"
      )
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
    applied = GuiActionHandler.apply_git_result(state, {:error, "boom"})
    assert EditorState.status_msg(applied) == "Git error: boom"
  end

  test "an unexpected result shape degrades to a failure status", %{state: state} do
    applied = GuiActionHandler.apply_git_result(state, :weird)
    assert EditorState.status_msg(applied) == "Git action failed"
  end

  test "rapid git actions serialize: the second is queued, not run concurrently",
       %{state: state, dispatch_opts: opts} do
    state = GuiActionHandler.dispatch(state, {:git_stage_file, "a.ex"}, opts)
    first_lane = state.async_actions[:git_worktree]
    first_token = first_lane.running

    state = GuiActionHandler.dispatch(state, {:git_discard_file, "b.ex"}, opts)

    lane = state.async_actions[:git_worktree]
    assert is_reference(first_token)
    assert lane.running == first_token
    assert Enum.count(lane.queue) == 1
  end

  @spec run_queued_git_status_regression(
          EditorState.t(),
          String.t(),
          keyword(),
          tuple(),
          String.t(),
          String.t()
        ) :: EditorState.t()
  defp run_queued_git_status_regression(
         state,
         git_root,
         opts,
         queued_action,
         pending_status,
         complete_status
       ) do
    state = GuiActionHandler.dispatch(state, {:git_stage_file, "a.ex"}, opts)
    state = GuiActionHandler.dispatch(state, queued_action, opts)

    assert EditorState.status_msg(state) == pending_status
    assert Enum.count(state.async_actions[:git_worktree].queue) == 1

    stage_token = current_git_token(state)

    {:noreply, state} =
      MingaEditor.handle_info(
        {:async_action_result, :git_worktree, stage_token, {:ok, "Staged a.ex", git_root}},
        state
      )

    assert EditorState.status_msg(state) == pending_status

    queued_token = current_git_token(state)

    {:noreply, state} =
      MingaEditor.handle_info(
        {:async_action_result, :git_worktree, queued_token, {:ok, complete_status, git_root}},
        state
      )

    assert EditorState.status_msg(state) == complete_status
    assert state.async_actions == %{}
    state
  end

  @spec current_git_token(EditorState.t()) :: reference()
  defp current_git_token(state), do: state.async_actions[:git_worktree].running

  @spec apply_async_result(EditorState.t(), tuple()) :: EditorState.t()
  defp apply_async_result(state, async_message) do
    {:noreply, applied_state} = MingaEditor.handle_info(async_message, state)
    applied_state
  end
end
