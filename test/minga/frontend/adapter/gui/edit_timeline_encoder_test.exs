defmodule Minga.Frontend.Adapter.GUI.EditTimelineEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EncodingError
  alias Minga.Frontend.Adapter.GUI.EditTimelineEncoder
  alias Minga.RenderModel.UI.EditTimeline
  alias Minga.RenderModel.UI.EditTimeline.Entry
  alias Minga.RenderModel.UI.EditTimeline.FileEntry

  @op_gui_edit_timeline Minga.Protocol.Opcodes.gui_edit_timeline()

  defp encode(model) do
    {binary, _caches} = EditTimelineEncoder.encode(model, Caches.new())
    binary
  end

  describe "encode/2 wire format" do
    test "encodes a hidden timeline (viewing index 0xFFFF, no entries)" do
      <<opcode, _len::16, visible, viewing::16, count, file_count>> = encode(%EditTimeline{})

      assert opcode == @op_gui_edit_timeline
      assert visible == 0
      assert viewing == 0xFFFF
      assert count == 0
      assert file_count == 0
    end

    test "encodes a visible timeline with entries" do
      model = %EditTimeline{
        visible?: true,
        generation: 41,
        viewing_index: 1,
        entries: [
          %Entry{entry_id: "a:tc1", index: 0, tool_name: "edit_file", timestamp_delta: 0},
          %Entry{entry_id: "a:tc2", index: 1, tool_name: "write_file", timestamp_delta: 500}
        ]
      }

      <<_opcode, payload_len::16, payload::binary-size(payload_len)>> = encode(model)
      <<visible, viewing::16, count, rest::binary>> = payload

      assert visible == 1
      assert viewing == 1
      assert count == 2

      assert <<0, 9, "edit_file", 0::32, 1, 10, "write_file", 500::32, 0::8, 41::32, 5::16,
               "a:tc1", 5::16, "a:tc2">> = rest
    end

    test "encodes file summary rows after active entries" do
      model = %EditTimeline{
        visible?: true,
        generation: 52,
        viewing_index: nil,
        entries: [],
        files: [
          %FileEntry{
            path: "lib/a.ex",
            entry_count: 2,
            lines_added: 10,
            lines_removed: 3,
            review_status: :reviewing
          }
        ]
      }

      <<_opcode, payload_len::16, payload::binary-size(payload_len)>> = encode(model)

      assert <<1::8, 0xFFFF::16, 0::8, 1::8, 8::16, "lib/a.ex", 2::8, 10::32, 3::32, 1::8,
               52::32>> =
               payload
    end

    test "rejects a tool name that exceeds its u8 byte length" do
      model = %EditTimeline{
        entries: [%Entry{index: 0, tool_name: String.duplicate("x", 256), timestamp_delta: 0}]
      }

      assert %{
               command: :gui_edit_timeline,
               field: :tool_name,
               actual: 256,
               min: 0,
               max: 255
             } = assert_raise(EncodingError, fn -> encode(model) end)
    end

    test "encodes a nil viewing index as 0xFFFF when visible" do
      <<_opcode, _len::16, _visible, viewing::16, _count, _file_count, 0::32>> =
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

    test "re-encodes when only the entry generation changes" do
      model = %EditTimeline{visible?: true, generation: 9}
      {_cmd, caches} = EditTimelineEncoder.encode(model, Caches.new())

      assert {cmd, _caches} = EditTimelineEncoder.encode(%{model | generation: 10}, caches)
      assert is_binary(cmd)
    end
  end
end
