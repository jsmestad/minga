defmodule MingaEditor.Frontend.GUIGitStatusTest do
  @moduledoc "Tests for git action sub-opcode decoding (decode_gui_action)."
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  # The gui_git_status *encode* parity oracle (ProtocolGUI.encode_gui_git_status/1)
  # was removed in #2225 once the production GitStatusEncoder migrated to the
  # schema-generated codec. Its encode coverage now lives in
  # Minga.Frontend.Adapter.GUI.GitStatusEncoderTest (decoded-field assertions),
  # MingaEditor.RenderModel.UI.GitStatusBuilderTest (derivations), and the
  # cross-language golden tests (byte-exactness). Only the unrelated git-action
  # decode path remains here.

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
