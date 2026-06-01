defmodule Minga.Frontend.Adapter.GUI.EditTimelineEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EditTimelineEncoder
  alias Minga.RenderModel.UI.EditTimeline
  alias Minga.RenderModel.UI.EditTimeline.Entry

  @op_gui_edit_timeline Minga.Protocol.Opcodes.gui_edit_timeline()

  defp encode(model) do
    {binary, _caches} = EditTimelineEncoder.encode(model, Caches.new())
    binary
  end

  describe "encode/2 wire format" do
    test "encodes a hidden timeline (viewing index 0xFFFF, no entries)" do
      <<opcode, _len::16, visible, viewing::16, count>> = encode(%EditTimeline{})

      assert opcode == @op_gui_edit_timeline
      assert visible == 0
      assert viewing == 0xFFFF
      assert count == 0
    end

    test "encodes a visible timeline with entries" do
      model = %EditTimeline{
        visible?: true,
        viewing_index: 1,
        entries: [
          %Entry{index: 0, tool_name: "edit_file", timestamp_delta: 0},
          %Entry{index: 1, tool_name: "write_file", timestamp_delta: 500}
        ]
      }

      <<_opcode, payload_len::16, payload::binary-size(payload_len)>> = encode(model)
      <<visible, viewing::16, count, rest::binary>> = payload

      assert visible == 1
      assert viewing == 1
      assert count == 2
      assert <<0, 9, "edit_file", 0::32, 1, 10, "write_file", 500::32>> = rest
    end

    test "encodes a nil viewing index as 0xFFFF when visible" do
      <<_opcode, _len::16, _visible, viewing::16, _count>> =
        encode(%EditTimeline{visible?: true, viewing_index: nil, entries: []})

      assert viewing == 0xFFFF
    end
  end

  describe "encode/2 cache skipping" do
    test "returns nil on the second call with an unchanged model" do
      model = %EditTimeline{
        visible?: true,
        viewing_index: 0,
        entries: [%Entry{index: 0, tool_name: "t", timestamp_delta: 0}]
      }

      {cmd1, caches} = EditTimelineEncoder.encode(model, Caches.new())
      assert cmd1 != nil

      {cmd2, _caches} = EditTimelineEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when the model changes" do
      {_cmd, caches} = EditTimelineEncoder.encode(%EditTimeline{}, Caches.new())

      changed = %EditTimeline{
        visible?: true,
        viewing_index: 0,
        entries: [%Entry{index: 0, tool_name: "t", timestamp_delta: 0}]
      }

      {cmd2, _caches} = EditTimelineEncoder.encode(changed, caches)
      assert cmd2 != nil
    end
  end
end
