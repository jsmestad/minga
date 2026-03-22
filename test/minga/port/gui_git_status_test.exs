defmodule Minga.Port.GUIGitStatusTest do
  @moduledoc "Tests for gui_git_status (0x85) encoding and git action sub-opcode decoding."
  use ExUnit.Case, async: true

  alias Minga.Git.StatusEntry
  alias Minga.Port.Protocol.GUI, as: ProtocolGUI

  describe "encode_gui_git_status/1" do
    test "encodes empty entries with normal repo state" do
      data = %{
        repo_state: :normal,
        branch: "main",
        ahead: 0,
        behind: 0,
        entries: []
      }

      binary = ProtocolGUI.encode_gui_git_status(data)

      # opcode(1) + repo_state(1) + ahead(2) + behind(2) + branch_len(2) + "main"(4) + entry_count(2)
      assert byte_size(binary) == 1 + 1 + 2 + 2 + 2 + 4 + 2

      <<0x85, repo_state::8, ahead::16, behind::16, branch_len::16,
        branch::binary-size(branch_len), entry_count::16>> = binary

      assert repo_state == 0
      assert ahead == 0
      assert behind == 0
      assert branch == "main"
      assert entry_count == 0
    end

    test "encodes loading repo state" do
      data = %{repo_state: :loading, branch: "", ahead: 0, behind: 0, entries: []}
      binary = ProtocolGUI.encode_gui_git_status(data)
      <<0x85, repo_state::8, _rest::binary>> = binary
      assert repo_state == 2
    end

    test "encodes not_a_repo state" do
      data = %{
        repo_state: :not_a_repo,
        branch: "",
        ahead: 0,
        behind: 0,
        entries: []
      }

      binary = ProtocolGUI.encode_gui_git_status(data)

      <<0x85, repo_state::8, _rest::binary>> = binary
      assert repo_state == 1
    end

    test "encodes ahead/behind counts" do
      data = %{
        repo_state: :normal,
        branch: "feat/xyz",
        ahead: 3,
        behind: 1,
        entries: []
      }

      binary = ProtocolGUI.encode_gui_git_status(data)

      <<0x85, _repo::8, ahead::16, behind::16, _rest::binary>> = binary
      assert ahead == 3
      assert behind == 1
    end

    test "encodes staged and unstaged entries" do
      entries = [
        %StatusEntry{path: "lib/foo.ex", status: :modified, staged: true},
        %StatusEntry{path: "lib/bar.ex", status: :modified, staged: false},
        %StatusEntry{path: "new.txt", status: :untracked, staged: false}
      ]

      data = %{
        repo_state: :normal,
        branch: "main",
        ahead: 0,
        behind: 0,
        entries: entries
      }

      binary = ProtocolGUI.encode_gui_git_status(data)

      # Parse header
      <<0x85, _repo::8, _ahead::16, _behind::16, branch_len::16, _branch::binary-size(branch_len),
        entry_count::16, rest::binary>> = binary

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

      # Parse third entry (untracked)
      <<_hash3::32, section3::8, status3::8, path3_len::16, path3::binary-size(path3_len)>> =
        rest3

      assert section3 == 2
      assert status3 == 6
      assert path3 == "new.txt"
    end

    test "encodes conflict entries in section 3" do
      entries = [
        %StatusEntry{path: "conflict.ex", status: :conflict, staged: false}
      ]

      data = %{
        repo_state: :normal,
        branch: "main",
        ahead: 0,
        behind: 0,
        entries: entries
      }

      binary = ProtocolGUI.encode_gui_git_status(data)

      <<0x85, _repo::8, _ahead::16, _behind::16, branch_len::16, _branch::binary-size(branch_len),
        _count::16, _hash::32, section::8, status::8, _rest::binary>> = binary

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
          branch: "x",
          ahead: 0,
          behind: 0,
          entries: entries
        }

        binary = ProtocolGUI.encode_gui_git_status(data)

        <<0x85, _repo::8, _ahead::16, _behind::16, _blen::16, _branch::binary-size(1), _count::16,
          _hash::32, _section::8, status_byte::8, _rest::binary>> = binary

        assert status_byte == expected_byte,
               "expected #{status_atom} to encode as #{expected_byte}, got #{status_byte}"
      end
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

    test "decodes git_commit" do
      msg = "fix: resolve bug"
      payload = <<byte_size(msg)::16, msg::binary>>
      assert {:ok, {:git_commit, ^msg}} = ProtocolGUI.decode_gui_action(0x1D, payload)
    end

    test "decodes git_open_file" do
      path = "src/main.rs"
      payload = <<byte_size(path)::16, path::binary>>
      assert {:ok, {:git_open_file, ^path}} = ProtocolGUI.decode_gui_action(0x1E, payload)
    end

    test "returns error for unknown opcode" do
      assert :error = ProtocolGUI.decode_gui_action(0xFF, <<>>)
    end
  end
end
