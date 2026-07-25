defmodule MingaEditor.Frontend.FrameTransactionTest do
  use ExUnit.Case, async: true

  alias Minga.Protocol.Opcodes
  alias MingaEditor.Frontend.FrameTransaction
  alias MingaEditor.Frontend.Protocol

  test "accepts a complete render frame with semantic commands" do
    commands = [
      Protocol.encode_begin_frame(12, 0),
      <<Opcodes.gui_tab_bar(), 0>>,
      Protocol.encode_commit_frame(12)
    ]

    assert FrameTransaction.validate(commands) == :ok
  end

  test "accepts sanctioned side-channel commands outside a frame" do
    assert FrameTransaction.validate([Protocol.encode_set_title("Minga")]) == :ok
  end

  test "rejects a semantic command outside a frame without inspecting its payload" do
    assert {:error, {:out_of_transaction_command, opcode}} =
             FrameTransaction.validate([<<Opcodes.gui_tab_bar(), 0>>])

    assert opcode == Opcodes.gui_tab_bar()

    assert FrameTransaction.format_error({:out_of_transaction_command, opcode}) ==
             "opcode 0x71 outside a frame"
  end

  test "rejects retired cell-grid clear inside a frame" do
    assert {:error, {:retired_render_command, 0x12}} =
             FrameTransaction.validate([
               Protocol.encode_begin_frame(12, 0),
               <<0x12>>,
               Protocol.encode_commit_frame(12)
             ])

    assert FrameTransaction.format_error({:retired_render_command, 0x12}) ==
             "retired render opcode 0x12 inside a frame"
  end

  test "rejects retired batch_end inside a frame" do
    assert {:error, {:retired_render_command, 0x13}} =
             FrameTransaction.validate([
               Protocol.encode_begin_frame(12, 0),
               <<0x13, 0::32>>,
               Protocol.encode_commit_frame(12)
             ])
  end

  test "rejects a mismatched frame commit" do
    assert {:error, {:commit_seq_mismatch, 12, 13}} =
             FrameTransaction.validate([
               Protocol.encode_begin_frame(12, 0),
               Protocol.encode_commit_frame(13)
             ])
  end
end
