defmodule MingaEditor.Handlers.GuiActionGitAsyncTest do
  @moduledoc """
  GitOps GUI actions return control to the editor immediately and apply their
  result asynchronously, so a slow `git` command never blocks the input path.
  """
  # async: false because this module mutates the global :minga Application env
  # to swap git backends and coordinate blocking fake git work.
  use ExUnit.Case, async: false

  alias Minga.Events
  alias MingaEditor.AsyncAction
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State, as: EditorState

  # Stub git backend: returns :ok without touching the real worktree. Tests only
  # assert dispatch/apply behavior, not real git side effects.
  defmodule FakeGit do
    @moduledoc false

    @spec root_for(String.t()) :: {:ok, String.t()} | :not_git
    def root_for(root) do
      case Application.get_env(:minga, :git_root_for_result) do
        :not_git -> :not_git
        _ -> {:ok, root}
      end
    end

    @spec stage(String.t(), String.t()) :: :ok | {:error, String.t()}
    def stage(_root, _path) do
      maybe_block(:stage)

      case Application.get_env(:minga, :git_stage_result) do
        {:error, reason} -> {:error, reason}
        _ -> :ok
      end
    end

    @spec unstage(String.t(), String.t()) :: :ok
    def unstage(_root, _path), do: :ok

    @spec unstage_all(String.t()) :: :ok
    def unstage_all(_root), do: :ok

    @spec discard(String.t(), String.t()) :: :ok
    def discard(_root, _path), do: :ok

    @spec commit(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
    def commit(root, message, opts) do
      send(test_pid(), {:fake_git_commit, root, message, opts})

      case {message, opts} do
        {"fail commit", []} -> {:error, "boom commit"}
        {"fail amend", [amend: true]} -> {:error, "boom amend"}
        _ -> {:ok, "abc1234"}
      end
    end

    @spec maybe_block(atom()) :: :ok
    defp maybe_block(op) do
      case Application.get_env(:minga, :git_stage_block) do
        {^op, pid} ->
          send(pid, {:fake_git_stage_blocked, op, self()})

          receive do
            {:continue_fake_git_stage, ^op} -> :ok
          end

        _ ->
          :ok
      end
    end

    @spec test_pid() :: pid()
    defp test_pid do
      Application.fetch_env!(:minga, :git_test_pid)
    end
  end

  setup do
    previous_git_module = Application.get_env(:minga, :git_module)
    previous_test_pid = Application.get_env(:minga, :git_test_pid)

    Application.put_env(:minga, :git_module, FakeGit)
    Application.put_env(:minga, :git_test_pid, self())

    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})

    on_exit(fn ->
      restore_env(:git_module, previous_git_module)
      restore_env(:git_test_pid, previous_test_pid)
    end)

    %{state: TestHelpers.base_state(sidebar_registry: table)}
  end

  test "git commit forwards message, keeps amend off, and applies the async result", %{
    state: state
  } do
    new_state = GuiActionHandler.dispatch(state, {:git_commit, "fix the thing"})

    assert EditorState.status_msg(new_state) == "Committing…"
    assert map_size(new_state.async_actions) == 1
    assert_receive {:fake_git_commit, _root, "fix the thing", []}

    assert_receive {:async_action_result, :git_worktree, token,
                    {:ok, "Committed abc1234", git_root}}

    applied_state =
      apply_async_result(
        new_state,
        {:async_action_result, :git_worktree, token, {:ok, "Committed abc1234", git_root}}
      )

    assert EditorState.status_msg(applied_state) == "Committed abc1234"
    assert applied_state.async_actions == %{}
  end

  test "git amend forwards amend: true and applies the async result", %{state: state} do
    new_state = GuiActionHandler.dispatch(state, {:git_commit, "reword", true})

    assert EditorState.status_msg(new_state) == "Amending…"
    assert_receive {:fake_git_commit, _root, "reword", [amend: true]}

    assert_receive {:async_action_result, :git_worktree, token,
                    {:ok, "Amended abc1234", git_root}}

    applied_state =
      apply_async_result(
        new_state,
        {:async_action_result, :git_worktree, token, {:ok, "Amended abc1234", git_root}}
      )

    assert EditorState.status_msg(applied_state) == "Amended abc1234"
    assert applied_state.async_actions == %{}
  end

  test "git commit failure preserves the legacy failure status", %{state: state} do
    new_state = GuiActionHandler.dispatch(state, {:git_commit, "fail commit"})

    assert EditorState.status_msg(new_state) == "Committing…"
    assert_receive {:fake_git_commit, _root, "fail commit", []}

    assert_receive {:async_action_result, :git_worktree, token,
                    {:error, "boom commit", git_root, "Commit failed: boom commit"}}

    applied_state =
      apply_async_result(
        new_state,
        {:async_action_result, :git_worktree, token,
         {:error, "boom commit", git_root, "Commit failed: boom commit"}}
      )

    assert EditorState.status_msg(applied_state) == "Commit failed: boom commit"
    assert applied_state.async_actions == %{}
  end

  test "git amend failure preserves the legacy failure status", %{state: state} do
    new_state = GuiActionHandler.dispatch(state, {:git_commit, "fail amend", true})

    assert EditorState.status_msg(new_state) == "Amending…"
    assert_receive {:fake_git_commit, _root, "fail amend", [amend: true]}

    assert_receive {:async_action_result, :git_worktree, token,
                    {:error, "boom amend", git_root, "Amend failed: boom amend"}}

    applied_state =
      apply_async_result(
        new_state,
        {:async_action_result, :git_worktree, token,
         {:error, "boom amend", git_root, "Amend failed: boom amend"}}
      )

    assert EditorState.status_msg(applied_state) == "Amend failed: boom amend"
    assert applied_state.async_actions == %{}
  end

  test "a stale git commit result is ignored by the editor handler", %{state: state} do
    state = GuiActionHandler.dispatch(state, {:git_commit, "first"})
    assert_receive {:fake_git_commit, _root, "first", []}

    assert_receive {:async_action_result, :git_worktree, stale_token,
                    {:ok, "Committed abc1234", stale_git_root}}

    state = GuiActionHandler.dispatch(state, {:git_discard_file, "lib/bar.ex"})
    state = AsyncAction.advance(state, :git_worktree)
    current_status = EditorState.status_msg(state)
    current_async_actions = state.async_actions

    stale_state =
      apply_async_result(
        state,
        {:async_action_result, :git_worktree, stale_token,
         {:ok, "Committed abc1234", stale_git_root}}
      )

    assert stale_state == state
    assert EditorState.status_msg(stale_state) == current_status
    assert stale_state.async_actions == current_async_actions
  end

  test "queued git failure is logged while a commit keeps its pending status", %{state: state} do
    Events.subscribe(:log_message)
    Application.put_env(:minga, :git_stage_block, {:stage, self()})
    Application.put_env(:minga, :git_stage_result, {:error, "boom stage"})

    try do
      state = GuiActionHandler.dispatch(state, {:git_stage_file, "a.ex"})
      state = GuiActionHandler.dispatch(state, {:git_commit, "keep pending"})

      assert EditorState.status_msg(state) == "Committing…"
      assert_receive {:fake_git_stage_blocked, :stage, stage_pid}
      assert length(state.async_actions[:git_worktree].queue) == 1

      send(stage_pid, {:continue_fake_git_stage, :stage})

      assert_receive {:async_action_result, :git_worktree, stage_token,
                      {:error, "boom stage", git_root}}

      {:noreply, state} =
        MingaEditor.handle_info(
          {:async_action_result, :git_worktree, stage_token, {:error, "boom stage", git_root}},
          state
        )

      assert EditorState.status_msg(state) == "Committing…"

      assert_receive {:minga_event, :log_message,
                      %Minga.Events.LogMessageEvent{text: text, level: :error}}

      assert text =~ "boom stage"

      assert_receive {:async_action_result, :git_worktree, queued_token,
                      {:ok, "Committed abc1234", ^git_root}}

      {:noreply, state} =
        MingaEditor.handle_info(
          {:async_action_result, :git_worktree, queued_token,
           {:ok, "Committed abc1234", git_root}},
          state
        )

      assert EditorState.status_msg(state) == "Committed abc1234"
      assert state.async_actions == %{}
    after
      Events.unsubscribe(:log_message)
      restore_env(:git_stage_block, nil)
      restore_env(:git_stage_result, nil)
    end
  end

  test "git commit surfaces not a repo asynchronously", %{state: state} do
    Application.put_env(:minga, :git_root_for_result, :not_git)

    try do
      state = GuiActionHandler.dispatch(state, {:git_commit, "msg"})

      assert EditorState.status_msg(state) == "Committing…"
      assert_receive {:async_action_result, :git_worktree, token, :not_a_repo}

      {:noreply, state} =
        MingaEditor.handle_info(
          {:async_action_result, :git_worktree, token, :not_a_repo},
          state
        )

      assert EditorState.status_msg(state) == "Not in a git repository"
      assert state.async_actions == %{}
    after
      restore_env(:git_root_for_result, nil)
    end
  end

  test "queued commit and amend keep their pending status when a prior git action finishes",
       %{state: state} do
    state =
      run_queued_git_status_regression(
        state,
        {:git_commit, "keep pending"},
        "Committing…",
        "Committed abc1234"
      )

    _state =
      run_queued_git_status_regression(
        state,
        {:git_commit, "keep pending", true},
        "Amending…",
        "Amended abc1234"
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

  @spec run_queued_git_status_regression(
          EditorState.t(),
          tuple(),
          String.t(),
          String.t()
        ) :: EditorState.t()
  defp run_queued_git_status_regression(state, queued_action, pending_status, complete_status) do
    Application.put_env(:minga, :git_stage_block, {:stage, self()})

    try do
      state = GuiActionHandler.dispatch(state, {:git_stage_file, "a.ex"})
      state = GuiActionHandler.dispatch(state, queued_action)

      assert EditorState.status_msg(state) == pending_status
      assert_receive {:fake_git_stage_blocked, :stage, stage_pid}
      assert length(state.async_actions[:git_worktree].queue) == 1

      send(stage_pid, {:continue_fake_git_stage, :stage})

      assert_receive {:async_action_result, :git_worktree, stage_token,
                      {:ok, "Staged a.ex", git_root}}

      {:noreply, state} =
        MingaEditor.handle_info(
          {:async_action_result, :git_worktree, stage_token, {:ok, "Staged a.ex", git_root}},
          state
        )

      assert EditorState.status_msg(state) == pending_status

      assert_receive {:async_action_result, :git_worktree, queued_token,
                      {:ok, ^complete_status, ^git_root}}

      {:noreply, state} =
        MingaEditor.handle_info(
          {:async_action_result, :git_worktree, queued_token, {:ok, complete_status, git_root}},
          state
        )

      assert EditorState.status_msg(state) == complete_status
      assert state.async_actions == %{}
      state
    after
      Application.delete_env(:minga, :git_stage_block)
    end
  end

  @spec restore_env(atom(), term() | nil) :: :ok
  defp restore_env(key, nil), do: Application.delete_env(:minga, key)
  defp restore_env(key, value), do: Application.put_env(:minga, key, value)

  @spec apply_async_result(EditorState.t(), tuple()) :: EditorState.t()
  defp apply_async_result(state, async_message) do
    {:noreply, applied_state} = MingaEditor.handle_info(async_message, state)
    applied_state
  end
end
