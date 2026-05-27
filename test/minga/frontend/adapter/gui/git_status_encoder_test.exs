defmodule Minga.Frontend.Adapter.GUI.GitStatusEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.GitStatusEncoder
  alias Minga.RenderModel.UI.GitStatus
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_git_status Minga.Protocol.Opcodes.gui_git_status()

  describe "encode/2" do
    test "encodes minimal not_a_repo status" do
      model = %GitStatus{repo_state: :not_a_repo, syncing: false}
      caches = Caches.new()

      {cmd, _caches} = GitStatusEncoder.encode(model, caches)

      # opcode, repo_state=1(not_a_repo), syncing=0, ahead=0, behind=0, branch_len=0, entry_count=0, ...
      assert <<@op_gui_git_status, 1::8, 0::8, _rest::binary>> = cmd
    end

    test "encodes normal repo with entries" do
      model = %GitStatus{
        repo_state: :normal,
        syncing: true,
        branch: "main",
        ahead: 2,
        behind: 1,
        entries: [
          %{path: "lib/foo.ex", status: :modified, staged: false}
        ],
        entry_base_path: "/project",
        last_commit_message: "fix",
        stash_count: 1
      }

      caches = Caches.new()
      {cmd, _caches} = GitStatusEncoder.encode(model, caches)

      assert <<@op_gui_git_status, 0::8, 1::8, 2::16, 1::16, _rest::binary>> = cmd
    end

    test "returns nil on second call with same model (fingerprint skip)" do
      model = %GitStatus{repo_state: :not_a_repo, syncing: false}
      caches = Caches.new()

      {cmd1, caches} = GitStatusEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = GitStatusEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when model changes" do
      model1 = %GitStatus{repo_state: :not_a_repo, syncing: false}
      model2 = %GitStatus{repo_state: :normal, syncing: true, branch: "main"}

      caches = Caches.new()
      {_, caches} = GitStatusEncoder.encode(model1, caches)
      {cmd2, _caches} = GitStatusEncoder.encode(model2, caches)

      assert cmd2 != nil
    end

    test "produces byte-identical output to legacy for not_a_repo case" do
      legacy_data = %{
        repo_state: :not_a_repo,
        syncing: false,
        branch: "",
        ahead: 0,
        behind: 0,
        entries: [],
        entry_base_path: "",
        last_commit_message: "",
        stash_count: 0,
        git_toast: nil
      }

      legacy_binary = ProtocolGUI.encode_gui_git_status(legacy_data)

      model =
        MingaEditor.RenderModel.UI.GitStatusBuilder.build(nil, false, nil)

      caches = Caches.new()
      {new_binary, _caches} = GitStatusEncoder.encode(model, caches)

      assert new_binary == legacy_binary,
             "not_a_repo: new encoder output does not match legacy output"
    end

    test "produces byte-identical output to legacy for normal repo with entries" do
      entries = [
        %Minga.Git.StatusEntry{path: "lib/foo.ex", status: :modified, staged: false},
        %Minga.Git.StatusEntry{path: "lib/bar.ex", status: :added, staged: true},
        %Minga.Git.StatusEntry{path: "test/baz.exs", status: :untracked, staged: false}
      ]

      legacy_data = %{
        repo_state: :normal,
        syncing: true,
        branch: "feature/test",
        ahead: 3,
        behind: 1,
        entries: entries,
        entry_base_path: "/home/user/project",
        last_commit_message: "feat: add feature",
        stash_count: 2,
        git_toast: nil
      }

      legacy_binary = ProtocolGUI.encode_gui_git_status(legacy_data)

      model =
        MingaEditor.RenderModel.UI.GitStatusBuilder.build(legacy_data, true, nil)

      caches = Caches.new()
      {new_binary, _caches} = GitStatusEncoder.encode(model, caches)

      assert new_binary == legacy_binary,
             "Normal repo with entries: new encoder output does not match legacy output"
    end

    test "produces byte-identical output to legacy for syncing with toast" do
      toast = %{message: "Push failed!", level: :error, action: :pull_and_retry}

      legacy_data = %{
        repo_state: :not_a_repo,
        syncing: true,
        branch: "",
        ahead: 0,
        behind: 0,
        entries: [],
        entry_base_path: "",
        last_commit_message: "",
        stash_count: 0,
        git_toast: toast
      }

      legacy_binary = ProtocolGUI.encode_gui_git_status(legacy_data)

      model = MingaEditor.RenderModel.UI.GitStatusBuilder.build(nil, true, toast)
      caches = Caches.new()
      {new_binary, _caches} = GitStatusEncoder.encode(model, caches)

      assert new_binary == legacy_binary,
             "Syncing with toast: new encoder output does not match legacy output"
    end

    test "produces byte-identical output to legacy for success toast" do
      toast = %{message: "Pushed successfully!", level: :success, action: nil}

      legacy_data = %{
        repo_state: :normal,
        syncing: false,
        branch: "main",
        ahead: 0,
        behind: 0,
        entries: [],
        entry_base_path: "/project",
        last_commit_message: "init",
        stash_count: 0,
        git_toast: toast
      }

      legacy_binary = ProtocolGUI.encode_gui_git_status(legacy_data)

      model = MingaEditor.RenderModel.UI.GitStatusBuilder.build(legacy_data, false, toast)
      caches = Caches.new()
      {new_binary, _caches} = GitStatusEncoder.encode(model, caches)

      assert new_binary == legacy_binary
    end

    test "produces byte-identical output for all status types" do
      statuses = [:modified, :added, :deleted, :renamed, :copied, :untracked, :conflict, :unknown]

      for status <- statuses do
        entries = [%Minga.Git.StatusEntry{path: "file.ex", status: status, staged: false}]

        legacy_data = %{
          repo_state: :normal,
          syncing: false,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: entries,
          entry_base_path: "",
          last_commit_message: "",
          stash_count: 0,
          git_toast: nil
        }

        legacy_binary = ProtocolGUI.encode_gui_git_status(legacy_data)
        model = MingaEditor.RenderModel.UI.GitStatusBuilder.build(legacy_data, false, nil)
        caches = Caches.new()
        {new_binary, _caches} = GitStatusEncoder.encode(model, caches)

        assert new_binary == legacy_binary,
               "Status #{status}: new encoder output does not match legacy output"
      end
    end

    test "produces byte-identical output for staged entries" do
      entries = [
        %Minga.Git.StatusEntry{path: "staged.ex", status: :modified, staged: true},
        %Minga.Git.StatusEntry{path: "unstaged.ex", status: :modified, staged: false}
      ]

      legacy_data = %{
        repo_state: :normal,
        syncing: false,
        branch: "main",
        ahead: 0,
        behind: 0,
        entries: entries,
        entry_base_path: "",
        last_commit_message: "",
        stash_count: 0,
        git_toast: nil
      }

      legacy_binary = ProtocolGUI.encode_gui_git_status(legacy_data)
      model = MingaEditor.RenderModel.UI.GitStatusBuilder.build(legacy_data, false, nil)
      caches = Caches.new()
      {new_binary, _caches} = GitStatusEncoder.encode(model, caches)

      assert new_binary == legacy_binary,
             "Staged entries: new encoder output does not match legacy output"
    end

    test "produces byte-identical output for loading repo state" do
      legacy_data = %{
        repo_state: :loading,
        syncing: false,
        branch: "",
        ahead: 0,
        behind: 0,
        entries: [],
        entry_base_path: "",
        last_commit_message: "",
        stash_count: 0,
        git_toast: nil
      }

      legacy_binary = ProtocolGUI.encode_gui_git_status(legacy_data)
      model = MingaEditor.RenderModel.UI.GitStatusBuilder.build(legacy_data, false, nil)
      caches = Caches.new()
      {new_binary, _caches} = GitStatusEncoder.encode(model, caches)

      assert new_binary == legacy_binary,
             "Loading state: new encoder output does not match legacy output"
    end
  end
end
