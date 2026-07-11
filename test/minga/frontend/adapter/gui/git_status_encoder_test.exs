defmodule Minga.Frontend.Adapter.GUI.GitStatusEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EncodingError
  alias Minga.Frontend.Adapter.GUI.GitStatusEncoder
  alias Minga.RenderModel.UI.GitStatus
  alias MingaEditor.RenderModel.UI.GitStatusBuilder

  @op_gui_git_status Minga.Protocol.Opcodes.gui_git_status()

  describe "encode/2" do
    test "encodes minimal not_a_repo status" do
      model = GitStatusBuilder.build(nil, false, nil)
      caches = Caches.new()

      {cmd, _caches} = GitStatusEncoder.encode(model, caches)

      # opcode, repo_state=1(not_a_repo), syncing=0, ahead=0, behind=0, branch_len=0, entry_count=0, ...
      assert <<@op_gui_git_status, 1::8, 0::8, _rest::binary>> = cmd
    end

    test "encodes normal repo with entries" do
      data = %{
        repo_state: :normal,
        branch: "main",
        ahead: 2,
        behind: 1,
        entries: [%{path: "lib/foo.ex", status: :modified, staged: false}],
        entry_base_path: "/project",
        last_commit_message: "fix",
        stash_count: 1
      }

      model = GitStatusBuilder.build(data, true, nil)

      caches = Caches.new()
      {cmd, _caches} = GitStatusEncoder.encode(model, caches)

      assert <<@op_gui_git_status, 0::8, 1::8, 2::16, 1::16, _rest::binary>> = cmd
    end

    test "returns nil on second call with same model (fingerprint skip)" do
      model = GitStatusBuilder.build(nil, false, nil)
      caches = Caches.new()

      {cmd1, caches} = GitStatusEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = GitStatusEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when model changes" do
      model1 = GitStatusBuilder.build(nil, false, nil)
      model2 = GitStatusBuilder.build(%{repo_state: :normal, branch: "main"}, true, nil)

      caches = Caches.new()
      {_, caches} = GitStatusEncoder.encode(model1, caches)
      {cmd2, _caches} = GitStatusEncoder.encode(model2, caches)

      assert cmd2 != nil
    end

    # Byte-exactness against the schema-generated codec is proven by the
    # cross-language golden tests (test/support/protocol_golden.ex +
    # go/tui/internal/protocol/golden_cross_lang_test.go), which replaced the
    # former hand-written ProtocolGUI.encode_gui_git_status parity oracle for
    # this family. The tests below decode the production wire format and assert
    # on the decoded fields, preserving the input-case coverage the
    # oracle-anchored tests carried (repo states, entry sections/statuses,
    # toast levels/actions, staging) without re-deriving expected bytes by hand.
    test "encodes not_a_repo with empty header and no toast" do
      model = GitStatusBuilder.build(nil, false, nil)
      {cmd, _caches} = GitStatusEncoder.encode(model, Caches.new())

      decoded = decode_git_status(cmd)

      assert decoded.repo_state == 1
      assert decoded.syncing == 0
      assert decoded.ahead == 0
      assert decoded.behind == 0
      assert decoded.branch == ""
      assert decoded.entries == []
      assert decoded.toast == nil
      assert decoded.entry_base_path == ""
      assert decoded.last_commit_message == ""
      assert decoded.stash_count == 0
    end

    test "encodes a normal repo with mixed-section entries" do
      data = %{
        repo_state: :normal,
        branch: "feature/test",
        ahead: 3,
        behind: 1,
        entries: [
          %{path: "lib/foo.ex", status: :modified, staged: false},
          %{path: "lib/bar.ex", status: :added, staged: true},
          %{path: "test/baz.exs", status: :untracked, staged: false}
        ],
        entry_base_path: "/home/user/project",
        last_commit_message: "feat: add feature",
        stash_count: 2
      }

      model = GitStatusBuilder.build(data, true, nil)
      {cmd, _caches} = GitStatusEncoder.encode(model, Caches.new())

      decoded = decode_git_status(cmd)

      assert decoded.repo_state == 0
      assert decoded.syncing == 1
      assert decoded.ahead == 3
      assert decoded.behind == 1
      assert decoded.branch == "feature/test"
      assert decoded.entry_base_path == "/home/user/project"
      assert decoded.last_commit_message == "feat: add feature"
      assert decoded.stash_count == 2

      # unstaged modified => section 1, staged added => section 0, untracked => section 2
      assert Enum.map(decoded.entries, & &1.section) == [1, 0, 2]
      # modified=1, added=2, untracked=6
      assert Enum.map(decoded.entries, & &1.status) == [1, 2, 6]
      assert Enum.map(decoded.entries, & &1.path) == ["lib/foo.ex", "lib/bar.ex", "test/baz.exs"]

      for entry <- decoded.entries do
        assert entry.path_hash == :erlang.phash2(entry.path, 0xFFFFFFFF)
      end
    end

    test "encodes a syncing not_a_repo with an error/pull_and_retry toast" do
      toast = %{message: "Push failed!", level: :error, action: :pull_and_retry}
      model = GitStatusBuilder.build(nil, true, toast)
      {cmd, _caches} = GitStatusEncoder.encode(model, Caches.new())

      decoded = decode_git_status(cmd)

      assert decoded.repo_state == 1
      assert decoded.syncing == 1
      # error => 1, pull_and_retry => 1
      assert decoded.toast == %{level: 1, action: 1, message: "Push failed!"}
    end

    test "encodes a success/no-action toast" do
      toast = %{message: "Pushed successfully!", level: :success, action: nil}

      data = %{
        repo_state: :normal,
        branch: "main",
        entry_base_path: "/project",
        last_commit_message: "init"
      }

      model = GitStatusBuilder.build(data, false, toast)
      {cmd, _caches} = GitStatusEncoder.encode(model, Caches.new())

      decoded = decode_git_status(cmd)

      # success => 0, nil action => 0
      assert decoded.toast == %{level: 0, action: 0, message: "Pushed successfully!"}
      assert decoded.entry_base_path == "/project"
      assert decoded.last_commit_message == "init"
    end

    test "encodes each file status to its wire byte" do
      expected_status_byte = %{
        modified: 1,
        added: 2,
        deleted: 3,
        renamed: 4,
        copied: 5,
        untracked: 6,
        conflict: 7,
        unknown: 0
      }

      for {status, byte} <- expected_status_byte do
        data = %{
          repo_state: :normal,
          branch: "main",
          entries: [%{path: "file.ex", status: status, staged: false}]
        }

        model = GitStatusBuilder.build(data, false, nil)
        {cmd, _caches} = GitStatusEncoder.encode(model, Caches.new())

        decoded = decode_git_status(cmd)
        [entry] = decoded.entries

        assert entry.status == byte, "status #{status} should encode as #{byte}"
      end
    end

    test "encodes staged vs unstaged entries to sections 0 and 1" do
      data = %{
        repo_state: :normal,
        branch: "main",
        entries: [
          %{path: "staged.ex", status: :modified, staged: true},
          %{path: "unstaged.ex", status: :modified, staged: false}
        ]
      }

      model = GitStatusBuilder.build(data, false, nil)
      {cmd, _caches} = GitStatusEncoder.encode(model, Caches.new())

      decoded = decode_git_status(cmd)

      assert Enum.map(decoded.entries, & &1.section) == [0, 1]
    end

    test "encodes loading repo state" do
      data = %{repo_state: :loading}
      model = GitStatusBuilder.build(data, false, nil)
      {cmd, _caches} = GitStatusEncoder.encode(model, Caches.new())

      decoded = decode_git_status(cmd)

      assert decoded.repo_state == 2
    end

    test "rejects oversized git status header counts" do
      base = valid_git_status()

      for field <- [:ahead, :behind, :stash_count] do
        assert_encoding_error(Map.put(base, field, 65_536), field, 65_536, 65_535)
      end

      assert_encoding_error(
        %{base | entries: List.duplicate(hd(base.entries), 65_536)},
        :entry_count,
        65_536,
        65_535
      )
    end

    test "rejects every oversized git status string" do
      oversized = String.duplicate("x", 65_536)
      base = valid_git_status()
      [entry] = base.entries

      for {field, model} <- [
            branch: %{base | branch: oversized},
            entry_path: %{base | entries: [%{entry | path: oversized}]},
            toast_message: %{
              base
              | git_toast: %{present: 1, level: :error, action: :none, message: oversized}
            },
            entry_base_path: %{base | entry_base_path: oversized},
            last_commit_message: %{base | last_commit_message: oversized}
          ] do
        assert_encoding_error(model, field, 65_536, 65_535)
      end
    end

    test "rejects oversized nested git entry numeric fields" do
      base = valid_git_status()
      [entry] = base.entries

      for {field, changed_entry, actual, max} <- [
            {:entry_path_hash, %{entry | path_hash: 0x100000000}, 0x100000000, 0xFFFFFFFF},
            {:entry_section, %{entry | section: 256}, 256, 255}
          ] do
        assert_encoding_error(%{base | entries: [changed_entry]}, field, actual, max)
      end
    end
  end

  defp valid_git_status do
    %GitStatus{
      repo_state: :normal,
      syncing: false,
      entries: [%{path_hash: 1, section: 1, status: :modified, path: "lib/file.ex"}]
    }
  end

  defp assert_encoding_error(model, field, actual, max) do
    error = assert_raise EncodingError, fn -> GitStatusEncoder.encode_command(model) end

    assert %EncodingError{
             command: :gui_git_status,
             field: ^field,
             actual: ^actual,
             min: 0,
             max: ^max
           } = error
  end

  # Decodes the production gui_git_status wire format (opcode stripped) into a
  # struct of fields, mirroring the layout the native frontend decodes.
  defp decode_git_status(
         <<@op_gui_git_status, repo_state::8, syncing::8, ahead::16, behind::16, branch_len::16,
           branch::binary-size(branch_len), entry_count::16, rest::binary>>
       ) do
    {entries, rest} = decode_entries(rest, entry_count, [])
    {toast, rest} = decode_toast(rest)

    <<base_len::16, entry_base_path::binary-size(base_len), commit_len::16,
      last_commit_message::binary-size(commit_len), stash_count::16>> = rest

    %{
      repo_state: repo_state,
      syncing: syncing,
      ahead: ahead,
      behind: behind,
      branch: branch,
      entries: entries,
      toast: toast,
      entry_base_path: entry_base_path,
      last_commit_message: last_commit_message,
      stash_count: stash_count
    }
  end

  defp decode_entries(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_entries(
         <<path_hash::32, section::8, status::8, path_len::16, path::binary-size(path_len),
           rest::binary>>,
         n,
         acc
       ) do
    entry = %{path_hash: path_hash, section: section, status: status, path: path}
    decode_entries(rest, n - 1, [entry | acc])
  end

  defp decode_toast(<<0::8, rest::binary>>), do: {nil, rest}

  defp decode_toast(
         <<1::8, level::8, action::8, msg_len::16, msg::binary-size(msg_len), rest::binary>>
       ) do
    {%{level: level, action: action, message: msg}, rest}
  end
end
