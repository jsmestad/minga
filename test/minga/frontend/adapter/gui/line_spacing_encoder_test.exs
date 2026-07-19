defmodule Minga.Frontend.Adapter.GUI.LineSpacingEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.LineSpacingEncoder
  alias Minga.RenderModel.UI.LineSpacing

  describe "encode/2" do
    test "encodes canonical spacing_x100 values" do
      for {multiplier, spacing_x100} <- [{1.0, 100}, {1.2, 120}, {1.5, 150}, {2.0, 200}] do
        {cmd, _caches} =
          LineSpacingEncoder.encode(%LineSpacing{multiplier: multiplier}, Caches.new())

        assert <<0x92, 2::16, ^spacing_x100::16>> = cmd
      end
    end

    test "quantizes the multiplier to spacing_x100 on the wire" do
      {cmd, _caches} = LineSpacingEncoder.encode(%LineSpacing{multiplier: 1.2}, Caches.new())
      assert <<0x92, 2::16, 120::16>> = cmd
    end

    test "skips re-emitting an unchanged multiplier" do
      caches = Caches.new()
      {cmd1, caches} = LineSpacingEncoder.encode(%LineSpacing{multiplier: 1.2}, caches)
      assert cmd1 != nil
      {cmd2, _caches} = LineSpacingEncoder.encode(%LineSpacing{multiplier: 1.2}, caches)
      assert cmd2 == nil
    end

    test "re-emits when the multiplier changes" do
      caches = Caches.new()
      {_cmd1, caches} = LineSpacingEncoder.encode(%LineSpacing{multiplier: 1.2}, caches)
      {cmd2, _caches} = LineSpacingEncoder.encode(%LineSpacing{multiplier: 1.5}, caches)
      assert <<0x92, 2::16, 150::16>> = cmd2
    end

    test "a fresh cache (keyframe reset) re-emits the current value" do
      {cmd, _caches} = LineSpacingEncoder.encode(%LineSpacing{multiplier: 1.2}, Caches.new())
      assert <<0x92, 2::16, 120::16>> = cmd
    end

    test "nil model emits nothing" do
      assert {nil, _caches} = LineSpacingEncoder.encode(nil, Caches.new())
    end
  end
end
