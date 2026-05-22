defmodule MingaEditor.Commands.GitStashTest do
  @moduledoc "Tests for the git stash editor commands."
  # Mutates the global Git.Stub root mapping because these commands resolve the project root internally.
  use ExUnit.Case, async: false

  alias Minga.Git.Repo
  alias Minga.Git.StashEntry
  alias Minga.Git.StatusEntry
  alias Minga.Git.Stub, as: GitStub
  alias MingaEditor.Commands.Git, as: GitCommands
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.UI.Picker.GitStashSource
  alias MingaEditor.Viewport

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    project_root = Minga.Project.resolve_root()
    GitStub.set_root(project_root, dir)

    on_exit(fn ->
      GitStub.clear(project_root)
      GitStub.clear(dir)
    end)

    {:ok, root: dir, project_root: project_root}
  end

  describe "stash save/pop" do
    test "save success clears the repo and reports success", %{root: dir} do
      repo = start_repo(dir, [tracked_change()], [])

      result = GitCommands.execute(build_state(), :git_stash_save)
      :sys.get_state(repo)

      assert EditorState.status_msg(result) == "Stashed changes"
      assert Repo.status(repo) == []

      summary = Repo.summary(repo)
      assert summary.staged_count == 0
      assert summary.unstaged_count == 0
      assert summary.untracked_count == 0
      assert summary.conflict_count == 0
      assert summary.stash_count == 1
    end

    test "save with no changes reports a no-op", %{root: dir} do
      repo = start_repo(dir, [], [])

      result = GitCommands.execute(build_state(), :git_stash_save)
      :sys.get_state(repo)

      assert EditorState.status_msg(result) == "No changes to stash"
      assert Repo.summary(repo).stash_count == 0
    end

    test "pop restores the stashed repo status", %{root: dir} do
      repo = start_repo(dir, [tracked_change()], [])

      save_result = GitCommands.execute(build_state(), :git_stash_save)
      :sys.get_state(repo)

      assert EditorState.status_msg(save_result) == "Stashed changes"
      assert Repo.status(repo) == []
      assert Repo.summary(repo).stash_count == 1

      pop_result = GitCommands.execute(build_state(), :git_stash_pop)
      :sys.get_state(repo)

      assert EditorState.status_msg(pop_result) == "Popped stash"
      assert Repo.status(repo) == [tracked_change()]

      summary = Repo.summary(repo)
      assert summary.staged_count == 0
      assert summary.unstaged_count == 1
      assert summary.untracked_count == 0
      assert summary.conflict_count == 0
      assert summary.stash_count == 0
    end

    test "pop failure reports the backend error", %{root: dir} do
      start_repo(dir, [], [])

      result = GitCommands.execute(build_state(), :git_stash_pop)

      assert EditorState.status_msg(result) == "Stash pop failed: No stash entries to pop"
    end
  end

  describe "stash picker commands" do
    test "list opens the stash picker", %{root: dir} do
      GitStub.set_stashes(dir, [stash_entry(0)])

      result = GitCommands.execute(build_state(), :git_stash_list)

      assert {:picker, %{picker_ui: %{source: GitStashSource}}} = result.shell_state.modal
    end

    test "drop opens the stash picker in drop mode", %{root: dir} do
      GitStub.set_stashes(dir, [stash_entry(0)])

      result = GitCommands.execute(build_state(), :git_stash_drop)

      assert {:picker, %{picker_ui: %{source: GitStashSource, context: context}}} =
               result.shell_state.modal

      assert context == %{git_root: dir, action: :drop}
    end
  end

  defp build_state do
    %EditorState{
      port_manager: nil,
      workspace: %SessionState{viewport: Viewport.new(24, 80)}
    }
  end

  defp start_repo(dir, status_entries, stashes) do
    GitStub.set_status(dir, status_entries)
    GitStub.set_stashes(dir, stashes)
    start_supervised!({Repo, git_root: dir}, id: {Repo, dir})
  end

  defp tracked_change do
    %StatusEntry{path: "file.txt", status: :modified, staged: false}
  end

  defp stash_entry(index) do
    %StashEntry{index: index, ref: "stash@{#{index}}", date: "1 minute ago", message: "WIP"}
  end
end
