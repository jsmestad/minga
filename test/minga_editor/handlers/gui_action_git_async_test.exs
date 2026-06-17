defmodule MingaEditor.Handlers.GuiActionGitAsyncTest do
  @moduledoc """
  GitOps GUI actions return control to the editor immediately and apply their
  result asynchronously, so a slow `git` command never blocks the input path.
  """
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
    def stage(_root, _path), do: :ok
    @spec unstage(String.t(), String.t()) :: :ok
    def unstage(_root, _path), do: :ok
    @spec unstage_all(String.t()) :: :ok
    def unstage_all(_root), do: :ok
    @spec discard(String.t(), String.t()) :: :ok
    def discard(_root, _path), do: :ok
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
end
