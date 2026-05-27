defmodule MingaEditor.RenderModel.UI.GitStatusBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.GitStatusBuilder
  alias Minga.RenderModel.UI.GitStatus

  describe "build/3" do
    test "returns not_a_repo when panel is nil" do
      model = GitStatusBuilder.build(nil, false, nil)

      assert %GitStatus{} = model
      assert model.repo_state == :not_a_repo
      assert model.syncing == false
      assert model.entries == []
      assert model.git_toast == nil
    end

    test "returns not_a_repo with syncing and toast" do
      toast = %{message: "Error!", level: :error, action: :pull_and_retry}
      model = GitStatusBuilder.build(nil, true, toast)

      assert model.repo_state == :not_a_repo
      assert model.syncing == true
      assert model.git_toast.message == "Error!"
      assert model.git_toast.level == :error
      assert model.git_toast.action == :pull_and_retry
    end

    test "builds from panel data map" do
      panel_data = %{
        repo_state: :normal,
        branch: "main",
        ahead: 2,
        behind: 1,
        entries: [
          %Minga.Git.StatusEntry{path: "lib/foo.ex", status: :modified, staged: false},
          %Minga.Git.StatusEntry{path: "lib/bar.ex", status: :added, staged: true}
        ],
        entry_base_path: "/home/user/project",
        last_commit_message: "fix: thing",
        stash_count: 3
      }

      model = GitStatusBuilder.build(panel_data, false, nil)

      assert model.repo_state == :normal
      assert model.branch == "main"
      assert model.ahead == 2
      assert model.behind == 1
      assert length(model.entries) == 2
      assert model.entry_base_path == "/home/user/project"
      assert model.last_commit_message == "fix: thing"
      assert model.stash_count == 3
    end

    test "converts entries to plain maps" do
      panel_data = %{
        repo_state: :normal,
        branch: "main",
        ahead: 0,
        behind: 0,
        entries: [%Minga.Git.StatusEntry{path: "lib/foo.ex", status: :modified, staged: false}],
        entry_base_path: "",
        last_commit_message: "",
        stash_count: 0
      }

      model = GitStatusBuilder.build(panel_data, false, nil)
      entry = hd(model.entries)

      assert entry.path == "lib/foo.ex"
      assert entry.status == :modified
      assert entry.staged == false
    end

    test "normalizes toast by stripping dismiss_ref" do
      toast = %{message: "Done!", level: :success, action: nil, dismiss_ref: make_ref()}
      model = GitStatusBuilder.build(nil, false, toast)

      assert model.git_toast.message == "Done!"
      refute Map.has_key?(model.git_toast, :dismiss_ref)
    end
  end
end
