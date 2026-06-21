defmodule MingaEditor.Handlers.GuiActionGitAsyncTest do
  @moduledoc """
  GitOps GUI actions return control to the editor immediately and apply their
  result asynchronously, so a slow `git` command never blocks the input path.
  """
  # async: false because this swaps the global git backend and blocks fake git work.
  use ExUnit.Case, async: false

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
    def stage(_root, _path) do
      maybe_block(:stage)
      :ok
    end

    @spec commit(String.t(), String.t(), keyword()) :: {:ok, String.t()}
    def commit(_root, _message, _opts), do: {:ok, "deadbeef"}

    @spec unstage(String.t(), String.t()) :: :ok
    def unstage(_root, _path), do: :ok

    @spec unstage_all(String.t()) :: :ok
    def unstage_all(_root), do: :ok

    @spec discard(String.t(), String.t()) :: :ok
    def discard(_root, _path), do: :ok

    @spec maybe_block(atom()) :: :ok
    defp maybe_block(op) do
      case Application.get_env(:minga, :git_async_block) do
        {^op, pid} ->
          send(pid, {:git_async_blocked, op, self()})

          receive do
            {:git_async_continue, ^op} -> :ok
          end

        _ ->
          :ok
      end
    end
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

  test "queued file git actions keep their pending status after the prior git action finishes",
       %{state: state} do
    state =
      assert_queued_git_status_preserved(
        state,
        {:git_discard_file, "b.ex"},
        "Discarding b.ex…",
        "Discarded b.ex"
      )

    assert_queued_git_status_preserved(
      state,
      {:git_unstage_file, "c.ex"},
      "Unstaging c.ex…",
      "Unstaged c.ex"
    )
  end

  defp assert_queued_git_status_preserved(state, queued_action, pending_status, complete_status) do
    Application.put_env(:minga, :git_async_block, {:stage, self()})

    try do
      state = GuiActionHandler.dispatch(state, {:git_stage_file, "a.ex"})
      state = GuiActionHandler.dispatch(state, queued_action)

      assert EditorState.status_msg(state) == pending_status
      assert_receive {:git_async_blocked, :stage, task_pid}
      assert length(MingaEditor.State.get_async_lane(state, :git_worktree).queue) == 1

      send(task_pid, {:git_async_continue, :stage})

      assert_receive {:async_action_result, :git_worktree, stage_token,
                      {:ok, "Staged a.ex", git_root}}

      {:noreply, state} =
        MingaEditor.handle_info(
          {:async_action_result, :git_worktree, stage_token, {:ok, "Staged a.ex", git_root}},
          state
        )

      assert EditorState.status_msg(state) == pending_status
      assert map_size(state.async_actions) == 1

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
      Application.delete_env(:minga, :git_async_block)
    end
  end
end
