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
      # An absent toast normalizes to the non-nullable wire "absent" map.
      assert model.git_toast == %{present: 0}
    end

    test "returns not_a_repo with syncing and toast" do
      toast = %{message: "Error!", level: :error, action: :pull_and_retry}
      model = GitStatusBuilder.build(nil, true, toast)

      assert model.repo_state == :not_a_repo
      assert model.syncing == true
      # The toast normalizes to the wire presence map.
      assert model.git_toast.present == 1
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

    test "derives wire-shaped entries with path_hash and section (ruling 4)" do
      panel_data = %{
        repo_state: :normal,
        branch: "main",
        ahead: 0,
        behind: 0,
        entries: [
          %Minga.Git.StatusEntry{path: "lib/foo.ex", status: :modified, staged: true},
          %Minga.Git.StatusEntry{path: "lib/bar.ex", status: :untracked, staged: false},
          %Minga.Git.StatusEntry{path: "lib/baz.ex", status: :conflict, staged: false},
          %Minga.Git.StatusEntry{path: "lib/qux.ex", status: :added, staged: false}
        ],
        entry_base_path: "",
        last_commit_message: "",
        stash_count: 0
      }

      model = GitStatusBuilder.build(panel_data, false, nil)

      [staged, untracked, conflict, other] = model.entries

      # The builder owns path_hash and the section predicate; entries no longer
      # carry :staged because section now encodes it.
      assert staged.path == "lib/foo.ex"
      assert staged.status == :modified
      assert staged.path_hash == :erlang.phash2("lib/foo.ex", 0xFFFFFFFF)
      assert staged.section == 0
      assert untracked.section == 2
      assert conflict.section == 3
      assert other.section == 1
      refute Map.has_key?(staged, :staged)
    end

    test "clamps stash_count to the u16 maximum" do
      model = GitStatusBuilder.build(%{repo_state: :normal, stash_count: 70_000}, false, nil)

      assert model.stash_count == 65_535
    end

    test "truncates an over-length last_commit_message to the u16 byte limit" do
      message = String.duplicate("λ", 40_000)

      model =
        GitStatusBuilder.build(%{repo_state: :normal, last_commit_message: message}, false, nil)

      assert byte_size(model.last_commit_message) <= 65_535
      assert String.valid?(model.last_commit_message)
    end

    test "normalizes a nil toast action to :none" do
      toast = %{message: "Done!", level: :success, action: nil}
      model = GitStatusBuilder.build(nil, false, toast)

      assert model.git_toast.present == 1
      assert model.git_toast.message == "Done!"
      assert model.git_toast.action == :none
    end
  end
end
