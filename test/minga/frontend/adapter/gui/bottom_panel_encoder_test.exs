defmodule Minga.Frontend.Adapter.GUI.BottomPanelEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.BottomPanelEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.BottomPanel
  alias Minga.RenderModel.UI.BottomPanel.MessageEntry

  @op_gui_bottom_panel Minga.Protocol.Opcodes.gui_bottom_panel()

  defp encode(model) do
    {binary, _caches} = BottomPanelEncoder.encode(model, Caches.new())
    binary
  end

  describe "encode/2 wire format" do
    test "encodes a hidden panel as two bytes" do
      assert encode(%BottomPanel{}) == <<@op_gui_bottom_panel, 0>>
    end

    test "encodes a visible panel header with tab defs and empty content" do
      model = %BottomPanel{
        visible?: true,
        active_tab_index: 0,
        height_percent: 30,
        filter_byte: 0,
        tabs: [{0x01, "Messages"}],
        messages: []
      }

      assert <<@op_gui_bottom_panel, 1, active_idx::8, height::8, filter::8, tab_count::8,
               rest::binary>> = encode(model)

      assert active_idx == 0
      assert height == 30
      assert filter == 0
      assert tab_count == 1
      assert <<0x01, 8::8, "Messages", 0::16>> = rest
    end

    test "encodes multiple tab defs and a non-zero filter" do
      model = %BottomPanel{
        visible?: true,
        active_tab_index: 1,
        height_percent: 45,
        filter_byte: 1,
        tabs: [{0x01, "Messages"}, {0x02, "Diagnostics"}, {0x03, "Terminal"}],
        messages: []
      }

      assert <<@op_gui_bottom_panel, 1, 1::8, 45::8, 1::8, 3::8, 0x01, l1::8,
               _n1::binary-size(l1), 0x02, l2::8, _n2::binary-size(l2), 0x03, l3::8,
               _n3::binary-size(l3), 0::16>> = encode(model)
    end

    test "encodes message entries" do
      model = %BottomPanel{
        visible?: true,
        active_tab_index: 0,
        height_percent: 30,
        filter_byte: 0,
        tabs: [{0x01, "Messages"}],
        messages: [
          %MessageEntry{
            id: 42,
            level_byte: 1,
            subsystem_byte: 0,
            ts_secs: 3661,
            file_path: "lib/editor.ex",
            text: "File opened"
          }
        ]
      }

      <<@op_gui_bottom_panel, 1, 0::8, 30::8, 0::8, 1::8, 0x01, nlen::8, _name::binary-size(nlen),
        entry_count::16, entries::binary>> = encode(model)

      assert entry_count == 1

      <<id::32, level::8, sub::8, ts::32, plen::16, path::binary-size(plen), tlen::16,
        text::binary-size(tlen)>> = entries

      assert id == 42
      assert level == 1
      assert sub == 0
      assert ts == 3661
      assert path == "lib/editor.ex"
      assert text == "File opened"
    end

    test "encodes a nil file_path as an empty path" do
      model = %BottomPanel{
        visible?: true,
        tabs: [{0x01, "Messages"}],
        messages: [%MessageEntry{id: 1, level_byte: 0, subsystem_byte: 0, ts_secs: 0, text: "t"}]
      }

      <<@op_gui_bottom_panel, 1, _::binary-size(4), 0x01, nlen::8, _name::binary-size(nlen),
        1::16, _id::32, _lvl::8, _sub::8, _ts::32, 0::16, tlen::16, "t">> = encode(model)

      assert tlen == 1
    end
  end

  describe "encode/2 cache skipping" do
    test "returns nil on the second call with an unchanged model" do
      model = %BottomPanel{visible?: true, tabs: [{0x01, "Messages"}], messages: []}

      {cmd1, caches} = BottomPanelEncoder.encode(model, Caches.new())
      assert cmd1 != nil

      {cmd2, _caches} = BottomPanelEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when the model changes" do
      {_cmd, caches} = BottomPanelEncoder.encode(%BottomPanel{}, Caches.new())

      changed = %BottomPanel{visible?: true, tabs: [{0x01, "Messages"}], messages: []}
      {cmd2, _caches} = BottomPanelEncoder.encode(changed, caches)
      assert cmd2 != nil
    end
  end
end
