defmodule Minga.Frontend.GUIBottomPanelTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.BottomPanel
  alias Minga.Frontend.Protocol.GUI, as: ProtocolGUI
  alias Minga.UI.Panel.MessageStore

  defp empty_store, do: %MessageStore{}

  describe "encode_gui_bottom_panel/2" do
    test "encodes hidden panel as 2 bytes" do
      panel = %BottomPanel{visible: false}
      {binary, _store} = ProtocolGUI.encode_gui_bottom_panel(panel, empty_store())
      assert <<0x7C, 0>> = binary
    end

    test "encodes visible panel with messages tab and empty store" do
      panel = %BottomPanel{
        visible: true,
        active_tab: :messages,
        tabs: [:messages],
        height_percent: 30,
        filter: nil
      }

      {binary, _store} = ProtocolGUI.encode_gui_bottom_panel(panel, empty_store())

      assert <<0x7C, 1, active_idx::8, height::8, filter::8, tab_count::8, rest::binary>> =
               binary

      assert active_idx == 0
      assert height == 30
      assert filter == 0
      assert tab_count == 1

      # Tab def: type(1) + name_len(1) + name + content: entry_count(2)=0
      assert <<0x01, name_len::8, name::binary-size(name_len), 0::16>> = rest
      assert name == "Messages"
    end

    test "encodes visible panel with multiple tabs" do
      panel = %BottomPanel{
        visible: true,
        active_tab: :diagnostics,
        tabs: [:messages, :diagnostics, :terminal],
        height_percent: 45,
        filter: :warnings
      }

      {binary, _store} = ProtocolGUI.encode_gui_bottom_panel(panel, empty_store())

      assert <<0x7C, 1, active_idx::8, height::8, filter::8, tab_count::8, rest::binary>> =
               binary

      # diagnostics is at index 1
      assert active_idx == 1
      assert height == 45
      assert filter == 1
      assert tab_count == 3

      # Parse three tab defs + empty content (entry_count=0)
      assert <<0x01, len1::8, _name1::binary-size(len1), 0x02, len2::8, _name2::binary-size(len2),
               0x03, len3::8, _name3::binary-size(len3), 0::16>> = rest
    end

    test "encodes message entries when messages tab is active" do
      store =
        %MessageStore{}
        |> MessageStore.append("Editor started", :info, :editor)
        |> MessageStore.append("[LSP] elixir-ls connected", :info, :lsp)

      panel = %BottomPanel{visible: true, active_tab: :messages, tabs: [:messages]}

      {binary, new_store} = ProtocolGUI.encode_gui_bottom_panel(panel, store)

      # Header: opcode + visible + active_idx + height + filter + tab_count + tab_def
      assert <<0x7C, 1, 0, _height::8, 0, 1, 0x01, nlen::8, _name::binary-size(nlen),
               entry_count::16, entries_data::binary>> = binary

      assert entry_count == 2
      assert new_store.last_sent_id == 2

      # Parse first entry
      assert <<id1::32, level1::8, sub1::8, _ts1::32, path_len1::16,
               _path1::binary-size(path_len1), text_len1::16, text1::binary-size(text_len1),
               _rest::binary>> = entries_data

      assert id1 == 1
      assert level1 == 1
      assert sub1 == 0
      assert text1 == "Editor started"
    end

    test "sends only incremental entries after first send" do
      store =
        %MessageStore{}
        |> MessageStore.append("First message", :info, :editor)

      panel = %BottomPanel{visible: true, active_tab: :messages, tabs: [:messages]}

      # First send: gets entry 1
      {_binary1, store2} = ProtocolGUI.encode_gui_bottom_panel(panel, store)
      assert store2.last_sent_id == 1

      # Add another entry
      store3 = MessageStore.append(store2, "Second message", :warning, :lsp)

      # Second send: only gets entry 2
      {binary2, store4} = ProtocolGUI.encode_gui_bottom_panel(panel, store3)
      assert store4.last_sent_id == 2

      # Parse to find entry count
      assert <<0x7C, 1, _::binary-size(4), 0x01, nlen::8, _name::binary-size(nlen),
               entry_count::16, _rest::binary>> = binary2

      assert entry_count == 1
    end

    test "encodes filter preset for warnings" do
      panel = %BottomPanel{visible: true, filter: :warnings}
      {binary, _store} = ProtocolGUI.encode_gui_bottom_panel(panel, empty_store())
      <<0x7C, 1, _active::8, _height::8, filter::8, _rest::binary>> = binary
      assert filter == 0x01
    end
  end

  describe "decode_gui_action for panel actions" do
    test "decodes panel_switch_tab" do
      assert {:ok, {:panel_switch_tab, 2}} =
               ProtocolGUI.decode_gui_action(0x09, <<2>>)
    end

    test "decodes panel_dismiss" do
      assert {:ok, :panel_dismiss} =
               ProtocolGUI.decode_gui_action(0x0A, <<>>)
    end

    test "decodes panel_resize" do
      assert {:ok, {:panel_resize, 45}} =
               ProtocolGUI.decode_gui_action(0x0B, <<45>>)
    end
  end
end
