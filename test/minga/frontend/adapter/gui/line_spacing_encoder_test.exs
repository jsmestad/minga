defmodule Minga.Frontend.Adapter.GUI.LineSpacingEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.LineSpacingEncoder
  alias Minga.RenderModel.UI.LineSpacing
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  describe "encode/2" do
    test "produces bytes identical to the legacy parity oracle" do
      for multiplier <- [1.0, 1.2, 1.5, 2.0] do
        {cmd, _caches} =
          LineSpacingEncoder.encode(%LineSpacing{multiplier: multiplier}, Caches.new())

        assert cmd == ProtocolGUI.encode_gui_line_spacing(multiplier)
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
      assert cmd == ProtocolGUI.encode_gui_line_spacing(1.2)
    end

    test "nil model emits nothing" do
      assert {nil, _caches} = LineSpacingEncoder.encode(nil, Caches.new())
    end
  end
end
