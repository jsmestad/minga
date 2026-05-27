defmodule Minga.Frontend.Adapter.GUI.BoardEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.BoardEncoder
  alias Minga.RenderModel.UI.Board

  @op_gui_board Minga.Protocol.Opcodes.gui_board()

  describe "encode/2" do
    test "encodes dismissed board" do
      model = %Board{
        encoded: <<@op_gui_board, 0::8, 0::32, 0::16, 0::8, 0::16>>,
        fingerprint: :dismissed
      }

      caches = Caches.new()

      {cmd, _caches} = BoardEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "encodes active board" do
      model = %Board{
        encoded: <<@op_gui_board, 1::8, "board_data">>,
        fingerprint: 12_345
      }

      caches = Caches.new()

      {cmd, _caches} = BoardEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %Board{
        encoded: <<@op_gui_board, 0::8>>,
        fingerprint: :dismissed
      }

      caches = Caches.new()

      {cmd1, caches} = BoardEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = BoardEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %Board{
        encoded: <<@op_gui_board, 0::8>>,
        fingerprint: :dismissed
      }

      model2 = %Board{
        encoded: <<@op_gui_board, 1::8, "data">>,
        fingerprint: 99_999
      }

      caches = Caches.new()
      {_, caches} = BoardEncoder.encode(model1, caches)
      {cmd2, _caches} = BoardEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end

    test "transitions from active to dismissed" do
      active_model = %Board{
        encoded: <<@op_gui_board, 1::8, "data">>,
        fingerprint: 12_345
      }

      dismissed_model = %Board{
        encoded: <<@op_gui_board, 0::8>>,
        fingerprint: :dismissed
      }

      caches = Caches.new()
      {_, caches} = BoardEncoder.encode(active_model, caches)
      {cmd, _caches} = BoardEncoder.encode(dismissed_model, caches)

      assert cmd == dismissed_model.encoded
    end
  end
end
