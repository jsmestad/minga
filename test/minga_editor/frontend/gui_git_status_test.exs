defmodule MingaEditor.Frontend.GUIGitStatusTest do
  @moduledoc "Tests for gui_git_status (0x85) encoding and git action sub-opcode decoding."
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias Minga.Git.StatusEntry

  describe "encode_gui_git_status/1" do
    test "encodes empty entries with normal repo state" do
      data = %{
        repo_state: :normal,
        syncing: false,
        branch: "main",
        ahead: 0,
        behind: 0,
        entries: [],
        git_toast: nil
      }

      binary = ProtocolGUI.encode_gui_git_status(data)

      # Header, empty entries, no toast, empty entry_base_path, empty last_commit_message, and stash_count.
      assert byte_size(binary) == 1 + 1 + 1 + 2 + 2 + 2 + 4 + 2 + 1 + 2 + 2 + 2

      <<0x85, repo_state::8, syncing::8, ahead::16, behind::16, branch_len::16,
        branch::binary-size(branch_len), entry_count::16, toast_present::8,
        entry_base_path_len::16, last_commit_len::16, stash_count::16>> = binary

      assert repo_state == 0
      assert syncing == 0
      assert ahead == 0
      assert behind == 0
      assert branch == "main"
      assert entry_count == 0
      assert toast_present == 0
      assert entry_base_path_len == 0
      assert last_commit_len == 0
      assert stash_count == 0
    end

    test "truncates entry_base_path and last commit message without breaking UTF-8" do
      long_text = String.duplicate("é", 40_000)

      binary =
        ProtocolGUI.encode_gui_git_status(%{
          repo_state: :normal,
          syncing: false,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: [],
          git_toast: nil,
          entry_base_path: long_text,
          last_commit_message: long_text
        })

      <<0x85, _repo::8, _syncing::8, _ahead::16, _behind::16, branch_len::16,
        _branch::binary-size(branch_len), _entry_count::16, _toast_present::8,
        entry_base_path_len::16, entry_base_path::binary-size(entry_base_path_len),
        last_commit_len::16, last_commit_message::binary-size(last_commit_len), stash_count::16>> =
        binary

      assert entry_base_path_len <= 65_535
      assert last_commit_len <= 65_535
      assert String.valid?(entry_base_path)
      assert String.valid?(last_commit_message)
      assert String.length(entry_base_path) > 0
      assert String.length(last_commit_message) > 0
      assert stash_count == 0
    end

    test "encodes syncing flag when true" do
      data = %{
        repo_state: :normal,
        syncing: true,
        branch: "main",
        ahead: 0,
        behind: 0,
        entries: [],
        git_toast: nil
      }

      binary = ProtocolGUI.encode_gui_git_status(data)

      <<0x85, _repo::8, syncing::8, _rest::binary>> = binary
      assert syncing == 1
    end

    test "encodes loading repo state" do
      data = %{
        repo_state: :loading,
        syncing: false,
        branch: "",
        ahead: 0,
        behind: 0,
        entries: [],
        git_toast: nil
      }

      binary = ProtocolGUI.encode_gui_git_status(data)
      <<0x85, repo_state::8, _rest::binary>> = binary
      assert repo_state == 2
    end

    test "encodes not_a_repo state" do
      data = %{
        repo_state: :not_a_repo,
        syncing: false,
        branch: "",
        ahead: 0,
        behind: 0,
        entries: [],
        git_toast: nil
      }

      binary = ProtocolGUI.encode_gui_git_status(data)

      <<0x85, repo_state::8, _rest::binary>> = binary
      assert repo_state == 1
    end

    test "encodes ahead/behind counts" do
      data = %{
        repo_state: :normal,
        syncing: false,
        branch: "feat/xyz",
        ahead: 3,
        behind: 1,
        entries: [],
        git_toast: nil
      }

      binary = ProtocolGUI.encode_gui_git_status(data)

      <<0x85, _repo::8, _syncing::8, ahead::16, behind::16, _rest::binary>> = binary
      assert ahead == 3
      assert behind == 1
    end

    test "encodes stash count" do
      binary =
        ProtocolGUI.encode_gui_git_status(%{
          repo_state: :normal,
          syncing: false,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: [],
          git_toast: nil,
          stash_count: 7
        })

      <<0x85, _repo::8, _syncing::8, _ahead::16, _behind::16, branch_len::16,
        _branch::binary-size(branch_len), _entry_count::16, _toast_present::8,
        _entry_base_path_len::16, _last_commit_len::16, stash_count::16>> = binary

      assert stash_count == 7
    end

    test "encodes staged and unstaged entries" do
      entries = [
        %StatusEntry{path: "lib/foo.ex", status: :modified, staged: true},
        %StatusEntry{path: "lib/bar.ex", status: :modified, staged: false},
        %StatusEntry{path: "new.txt", status: :untracked, staged: false}
      ]

      data = %{
        repo_state: :normal,
        syncing: false,
        branch: "main",
        ahead: 0,
        behind: 0,
        entries: entries,
        git_toast: nil
      }

      binary = ProtocolGUI.encode_gui_git_status(data)

      # Parse header
      <<0x85, _repo::8, _syncing::8, _ahead::16, _behind::16, branch_len::16,
        _branch::binary-size(branch_len), entry_count::16, rest::binary>> = binary

      assert entry_count == 3

      # Parse first entry (staged modified)
      <<_hash1::32, section1::8, status1::8, path1_len::16, path1::binary-size(path1_len),
        rest2::binary>> = rest

      assert section1 == 0
      assert status1 == 1
      assert path1 == "lib/foo.ex"

      # Parse second entry (unstaged modified)
      <<_hash2::32, section2::8, status2::8, path2_len::16, path2::binary-size(path2_len),
        rest3::binary>> = rest2

      assert section2 == 1
      assert status2 == 1
      assert path2 == "lib/bar.ex"

      # Parse third entry (untracked) -- toast_present byte follows
      <<_hash3::32, section3::8, status3::8, path3_len::16, path3::binary-size(path3_len),
        toast_present::8, entry_base_path_len::16, last_commit_len::16, stash_count::16>> = rest3

      assert section3 == 2
      assert status3 == 6
      assert path3 == "new.txt"
      assert toast_present == 0
      assert entry_base_path_len == 0
      assert last_commit_len == 0
      assert stash_count == 0
    end

    test "encodes conflict entries in section 3" do
      entries = [
        %StatusEntry{path: "conflict.ex", status: :conflict, staged: false}
      ]

      data = %{
        repo_state: :normal,
        syncing: false,
        branch: "main",
        ahead: 0,
        behind: 0,
        entries: entries,
        git_toast: nil
      }

      binary = ProtocolGUI.encode_gui_git_status(data)

      <<0x85, _repo::8, _syncing::8, _ahead::16, _behind::16, branch_len::16,
        _branch::binary-size(branch_len), _count::16, _hash::32, section::8, status::8,
        _rest::binary>> = binary

      assert section == 3
      assert status == 7
    end

    test "encodes all status types" do
      statuses = [
        {:modified, 1},
        {:added, 2},
        {:deleted, 3},
        {:renamed, 4},
        {:copied, 5},
        {:untracked, 6},
        {:conflict, 7},
        {:unknown, 0}
      ]

      for {status_atom, expected_byte} <- statuses do
        entries = [%StatusEntry{path: "file.ex", status: status_atom, staged: false}]

        data = %{
          repo_state: :normal,
          syncing: false,
          branch: "x",
          ahead: 0,
          behind: 0,
          entries: entries,
          git_toast: nil
        }

        binary = ProtocolGUI.encode_gui_git_status(data)

        <<0x85, _repo::8, _syncing::8, _ahead::16, _behind::16, _blen::16,
          _branch::binary-size(1), _count::16, _hash::32, _section::8, status_byte::8,
          _rest::binary>> = binary

        assert status_byte == expected_byte,
               "expected #{status_atom} to encode as #{expected_byte}, got #{status_byte}"
      end
    end

    test "encodes success toast" do
      data = %{
        repo_state: :normal,
        syncing: false,
        branch: "main",
        ahead: 0,
        behind: 0,
        entries: [],
        git_toast: %{message: "Pushed", level: :success, action: nil}
      }

      binary = ProtocolGUI.encode_gui_git_status(data)

      <<0x85, _repo::8, _syncing::8, _ahead::16, _behind::16, branch_len::16,
        _branch::binary-size(branch_len), _count::16, toast_present::8, toast_level::8,
        toast_action::8, msg_len::16, msg::binary-size(msg_len), entry_base_path_len::16,
        last_commit_len::16, stash_count::16>> = binary

      assert toast_present == 1
      assert toast_level == 0
      assert toast_action == 0
      assert msg == "Pushed"
      assert entry_base_path_len == 0
      assert last_commit_len == 0
      assert stash_count == 0
    end

    test "encodes error toast with pull_and_retry action" do
      data = %{
        repo_state: :normal,
        syncing: false,
        branch: "main",
        ahead: 0,
        behind: 0,
        entries: [],
        git_toast: %{message: "Push failed: rejected", level: :error, action: :pull_and_retry}
      }

      binary = ProtocolGUI.encode_gui_git_status(data)

      <<0x85, _repo::8, _syncing::8, _ahead::16, _behind::16, branch_len::16,
        _branch::binary-size(branch_len), _count::16, toast_present::8, toast_level::8,
        toast_action::8, msg_len::16, msg::binary-size(msg_len), entry_base_path_len::16,
        last_commit_len::16, stash_count::16>> = binary

      assert toast_present == 1
      assert toast_level == 1
      assert toast_action == 1
      assert msg == "Push failed: rejected"
      assert entry_base_path_len == 0
      assert last_commit_len == 0
      assert stash_count == 0
    end
  end

  describe "decode_gui_action git actions" do
    test "decodes git_stage_file" do
      path = "lib/foo.ex"
      payload = <<byte_size(path)::16, path::binary>>
      assert {:ok, {:git_stage_file, ^path}} = ProtocolGUI.decode_gui_action(0x18, payload)
    end

    test "decodes git_unstage_file" do
      path = "lib/bar.ex"
      payload = <<byte_size(path)::16, path::binary>>
      assert {:ok, {:git_unstage_file, ^path}} = ProtocolGUI.decode_gui_action(0x19, payload)
    end

    test "decodes git_discard_file" do
      path = "test.txt"
      payload = <<byte_size(path)::16, path::binary>>
      assert {:ok, {:git_discard_file, ^path}} = ProtocolGUI.decode_gui_action(0x1A, payload)
    end

    test "decodes git_stage_all" do
      assert {:ok, :git_stage_all} = ProtocolGUI.decode_gui_action(0x1B, <<>>)
    end

    test "decodes git_unstage_all" do
      assert {:ok, :git_unstage_all} = ProtocolGUI.decode_gui_action(0x1C, <<>>)
    end

    test "decodes legacy git_commit" do
      msg = "fix: resolve bug"
      payload = <<byte_size(msg)::16, msg::binary>>
      assert {:ok, {:git_commit, ^msg}} = ProtocolGUI.decode_gui_action(0x1D, payload)
    end

    test "decodes git_commit with amend flag" do
      msg = "fix: resolve bug"
      payload = <<1::8, byte_size(msg)::16, msg::binary>>
      assert {:ok, {:git_commit, ^msg, true}} = ProtocolGUI.decode_gui_action(0x1D, payload)
    end

    test "decodes git_open_file" do
      path = "src/main.rs"
      payload = <<byte_size(path)::16, path::binary>>
      assert {:ok, {:git_open_file, ^path}} = ProtocolGUI.decode_gui_action(0x1E, payload)
    end

    test "decodes git_open_diff" do
      path = "src/main.rs"
      payload = <<byte_size(path)::16, path::binary, 1::8>>
      assert {:ok, {:git_open_diff, ^path, 1}} = ProtocolGUI.decode_gui_action(0x42, payload)
    end

    test "decodes git_pull_and_retry" do
      assert {:ok, :git_pull_and_retry} = ProtocolGUI.decode_gui_action(0x3C, <<>>)
    end

    test "returns error for unknown opcode" do
      assert :error = ProtocolGUI.decode_gui_action(0xFF, <<>>)
    end
  end
end
