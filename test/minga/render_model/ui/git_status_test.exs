defmodule Minga.RenderModel.UI.GitStatusTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.GitStatus

  describe "%GitStatus{}" do
    test "requires repo_state and syncing" do
      gs = %GitStatus{repo_state: :normal, syncing: false}

      assert gs.repo_state == :normal
      assert gs.syncing == false
      assert gs.branch == ""
      assert gs.ahead == 0
      assert gs.behind == 0
      assert gs.entries == []
      assert gs.entry_base_path == ""
      assert gs.last_commit_message == ""
      assert gs.stash_count == 0
      assert gs.git_toast == nil
    end

    test "raises when enforce_keys are missing" do
      assert_raise ArgumentError, fn ->
        struct!(GitStatus, %{})
      end
    end

    test "accepts all fields" do
      gs = %GitStatus{
        repo_state: :normal,
        syncing: true,
        branch: "main",
        ahead: 2,
        behind: 1,
        entries: [%{path: "lib/foo.ex", status: :modified, staged: false}],
        entry_base_path: "/home/user/project",
        last_commit_message: "fix: thing",
        stash_count: 3,
        git_toast: %{message: "Pushed!", level: :success, action: nil}
      }

      assert gs.branch == "main"
      assert length(gs.entries) == 1
      assert is_map(gs.git_toast)
    end
  end
end
