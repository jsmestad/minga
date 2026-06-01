defmodule Minga.RenderModel.UI.BottomPanelTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.BottomPanel
  alias Minga.RenderModel.UI.BottomPanel.MessageEntry

  describe "%BottomPanel{}" do
    test "defaults to a hidden panel" do
      panel = %BottomPanel{}

      refute panel.visible?
      assert panel.tabs == []
      assert panel.messages == []
    end

    test "carries tabs and resolved messages" do
      panel = %BottomPanel{
        visible?: true,
        active_tab_index: 0,
        height_percent: 30,
        filter_byte: 1,
        tabs: [{0x01, "Messages"}],
        messages: [
          %MessageEntry{id: 1, level_byte: 1, subsystem_byte: 0, ts_secs: 10, text: "hi"}
        ]
      }

      assert [{0x01, "Messages"}] = panel.tabs
      assert [%MessageEntry{id: 1, text: "hi"}] = panel.messages
    end
  end

  describe "%BottomPanel.MessageEntry{}" do
    test "requires id, level/subsystem bytes, ts, and text; path optional" do
      entry = %MessageEntry{id: 7, level_byte: 2, subsystem_byte: 5, ts_secs: 100, text: "x"}

      assert entry.file_path == nil
    end

    test "raises when a required field is missing" do
      assert_raise ArgumentError, fn -> struct!(MessageEntry, %{id: 1}) end
    end
  end
end
