defmodule Minga.RenderModel.UI.BoardTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Board

  describe "%Board{}" do
    test "requires encoded and fingerprint" do
      board = %Board{encoded: <<0x87, 0>>, fingerprint: :dismissed}

      assert board.encoded == <<0x87, 0>>
      assert board.fingerprint == :dismissed
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(Board, %{})
      end
    end

    test "accepts integer fingerprint for active board" do
      board = %Board{encoded: <<0x87, 1>>, fingerprint: 12_345}

      assert board.fingerprint == 12_345
    end
  end
end
