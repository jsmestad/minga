defmodule Minga.Frontend.Adapter.GUI.CursorAnimationEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.CursorAnimationEncoder
  alias Minga.RenderModel.UI.CursorAnimation

  describe "encode/2" do
    test "encodes enabled/disabled flags" do
      {on, _} = CursorAnimationEncoder.encode(%CursorAnimation{enabled?: true}, Caches.new())
      {off, _} = CursorAnimationEncoder.encode(%CursorAnimation{enabled?: false}, Caches.new())
      assert <<0x95, 1::16, 1::8>> = on
      assert <<0x95, 1::16, 0::8>> = off
    end

    test "skips re-emitting an unchanged value" do
      caches = Caches.new()
      {cmd1, caches} = CursorAnimationEncoder.encode(%CursorAnimation{enabled?: true}, caches)
      assert cmd1 != nil
      {cmd2, _caches} = CursorAnimationEncoder.encode(%CursorAnimation{enabled?: true}, caches)
      assert cmd2 == nil
    end

    test "re-emits when the value flips" do
      caches = Caches.new()
      {_cmd1, caches} = CursorAnimationEncoder.encode(%CursorAnimation{enabled?: true}, caches)
      {cmd2, _caches} = CursorAnimationEncoder.encode(%CursorAnimation{enabled?: false}, caches)
      assert <<0x95, 1::16, 0::8>> = cmd2
    end

    test "nil model emits nothing" do
      assert {nil, _caches} = CursorAnimationEncoder.encode(nil, Caches.new())
    end
  end
end
