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
    test "row actions require a positive panel token, path, and section" do
      id = 0x1_0000_002A
      path = "lib/é.ex"
      row = <<byte_size(path)::16, path::binary, 1>>

      for {opcode, action} <- [
            {0x18, :git_stage_file},
            {0x19, :git_unstage_file},
            {0x1A, :git_discard_file},
            {0x1E, :git_open_file},
            {0x42, :git_open_diff}
          ] do
        assert {:ok, {^action, ^id, ^path, 1}} =
                 ProtocolGUI.decode_gui_action(opcode, <<id::64, row::binary>>)

        assert :error = ProtocolGUI.decode_gui_action(opcode, row)
        assert :error = ProtocolGUI.decode_gui_action(opcode, <<0::64, row::binary>>)

        assert :error =
                 ProtocolGUI.decode_gui_action(
                   opcode,
                   <<id::64, byte_size(path)::16, path::binary, 4>>
                 )
      end
    end

    test "bulk and remote actions require exactly one positive big-endian panel token" do
      id = 0x0102_0304_0506_0708
      token = <<1, 2, 3, 4, 5, 6, 7, 8>>

      for {opcode, action} <- [
            {0x1B, :git_stage_all},
            {0x1C, :git_unstage_all},
            {0x38, :git_push},
            {0x39, :git_pull},
            {0x3A, :git_fetch}
          ] do
        assert {:ok, {^action, ^id}} = ProtocolGUI.decode_gui_action(opcode, token)
        assert :error = ProtocolGUI.decode_gui_action(opcode, <<>>)
        assert :error = ProtocolGUI.decode_gui_action(opcode, <<0::64>>)
        assert :error = ProtocolGUI.decode_gui_action(opcode, token <> <<0>>)
      end
    end

    test "commit subtypes require a positive panel token and exact message payload" do
      id = 0x0102_0304_0506_0708
      token = <<1, 2, 3, 4, 5, 6, 7, 8>>
      message = "café"
      encoded_message = <<0, 5, message::binary>>

      for {flag, amend?} <- [{0, false}, {1, true}] do
        payload = <<token::binary, flag, encoded_message::binary>>

        assert {:ok, {:git_commit, ^id, ^message, ^amend?}} =
                 ProtocolGUI.decode_gui_action(0x1D, payload)

        assert :error = ProtocolGUI.decode_gui_action(0x1D, <<flag, encoded_message::binary>>)
        assert :error = ProtocolGUI.decode_gui_action(0x1D, payload <> <<0>>)
      end

      assert :error = ProtocolGUI.decode_gui_action(0x1D, encoded_message)
      assert :error = ProtocolGUI.decode_gui_action(0x1D, <<0::64, 0, encoded_message::binary>>)

      assert :error =
               ProtocolGUI.decode_gui_action(0x1D, <<token::binary, 2, encoded_message::binary>>)

      assert {:ok, {:git_commit, ^id, ^message, true}} =
               ProtocolGUI.decode_gui_action(0x3B, token <> encoded_message)

      assert :error = ProtocolGUI.decode_gui_action(0x3B, encoded_message)
      assert :error = ProtocolGUI.decode_gui_action(0x3B, <<0::64, encoded_message::binary>>)
      assert :error = ProtocolGUI.decode_gui_action(0x3B, token <> encoded_message <> <<0>>)
    end

    test "decodes only a positive Git retry toast identity" do
      id = 0x1_0000_002A
      assert {:ok, {:git_pull_and_retry, ^id}} = ProtocolGUI.decode_gui_action(0x3C, <<id::64>>)
      assert :error = ProtocolGUI.decode_gui_action(0x3C, <<>>)
      assert :error = ProtocolGUI.decode_gui_action(0x3C, <<0::64>>)
    end

    test "returns error for unknown opcode" do
      assert :error = ProtocolGUI.decode_gui_action(0xFF, <<>>)
    end
  end
end
