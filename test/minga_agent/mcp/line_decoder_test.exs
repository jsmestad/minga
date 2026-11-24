defmodule MingaAgent.MCP.LineDecoderTest do
  use ExUnit.Case, async: true

  alias MingaAgent.MCP.LineDecoder

  @piece_size 65_536
  @piece String.duplicate("x", @piece_size)

  describe "large frames" do
    test "retains each multi-megabyte piece by reference and copies the frame once at the end" do
      piece_count = 160
      decoder = push_pieces(LineDecoder.new(piece_count * @piece_size + 1), piece_count)

      assert LineDecoder.buffered_bytes(decoder) == piece_count * @piece_size
      assert length(decoder.pieces) == piece_count
      assert Enum.all?(decoder.pieces, &:erts_debug.same(&1, @piece))

      assert {:ok, frame, empty} = LineDecoder.finish(decoder, "!")
      assert byte_size(frame) == piece_count * @piece_size + 1
      assert binary_part(frame, byte_size(frame), -1) == "!"
      assert LineDecoder.buffered_bytes(empty) == 0
      assert empty.pieces == []
    end

    test "a frame with no newline stops at the limit and retains nothing after rejection" do
      max_bytes = 10 * 1_048_576
      within_limit = div(max_bytes, @piece_size)
      decoder = push_pieces(LineDecoder.new(max_bytes), within_limit)

      assert LineDecoder.buffered_bytes(decoder) == max_bytes

      assert LineDecoder.push(decoder, @piece) ==
               {:error, {:line_too_long, max_bytes + @piece_size}}
    end

    test "the final piece counts toward the limit" do
      decoder = push_pieces(LineDecoder.new(@piece_size + 10), 1)

      assert {:ok, _frame, _empty} = LineDecoder.finish(decoder, String.duplicate("y", 10))

      assert LineDecoder.finish(decoder, String.duplicate("y", 11)) ==
               {:error, {:line_too_long, @piece_size + 11}}
    end
  end

  test "frames decode independently after a finished frame" do
    {:ok, decoder} = LineDecoder.push(LineDecoder.new(100), ~s({"id":))
    {:ok, first, decoder} = LineDecoder.finish(decoder, "1}")
    {:ok, second, _decoder} = LineDecoder.finish(decoder, ~s({"id":2}))

    assert {first, second} == {~s({"id":1}), ~s({"id":2})}
  end

  defp push_pieces(decoder, count) do
    Enum.reduce(1..count//1, decoder, fn _index, acc ->
      {:ok, acc} = LineDecoder.push(acc, @piece)
      acc
    end)
  end
end
