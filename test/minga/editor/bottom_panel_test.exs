defmodule Minga.Editor.BottomPanelTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.BottomPanel

  describe "new panel" do
    test "starts hidden with messages tab" do
      panel = %BottomPanel{}
      assert panel.visible == false
      assert panel.active_tab == :messages
      assert panel.tabs == [:messages]
      assert panel.dismissed == false
      assert panel.filter == nil
      assert panel.height_percent == 30
    end
  end

  describe "toggle/1" do
    test "toggles from hidden to visible" do
      panel = %BottomPanel{visible: false}
      result = BottomPanel.toggle(panel)
      assert result.visible == true
      assert result.dismissed == false
      assert result.filter == nil
    end

    test "toggles from visible to hidden" do
      panel = %BottomPanel{visible: true}
      result = BottomPanel.toggle(panel)
      assert result.visible == false
    end

    test "clears dismissed state on open" do
      panel = %BottomPanel{visible: false, dismissed: true}
      result = BottomPanel.toggle(panel)
      assert result.visible == true
      assert result.dismissed == false
    end
  end

  describe "show/3" do
    test "shows panel on specified tab" do
      panel = %BottomPanel{visible: false}
      result = BottomPanel.show(panel, :messages, :warnings)
      assert result.visible == true
      assert result.active_tab == :messages
      assert result.filter == :warnings
      assert result.dismissed == false
    end

    test "defaults to messages tab with no filter" do
      panel = %BottomPanel{visible: false}
      result = BottomPanel.show(panel)
      assert result.visible == true
      assert result.active_tab == :messages
      assert result.filter == nil
    end
  end

  describe "dismiss/1" do
    test "hides panel and sets dismissed flag" do
      panel = %BottomPanel{visible: true}
      result = BottomPanel.dismiss(panel)
      assert result.visible == false
      assert result.dismissed == true
    end
  end

  describe "switch_tab/2" do
    test "switches to a valid tab index" do
      panel = %BottomPanel{tabs: [:messages, :diagnostics], active_tab: :messages}
      result = BottomPanel.switch_tab(panel, 1)
      assert result.active_tab == :diagnostics
      assert result.filter == nil
    end

    test "ignores invalid tab index" do
      panel = %BottomPanel{tabs: [:messages], active_tab: :messages}
      result = BottomPanel.switch_tab(panel, 5)
      assert result.active_tab == :messages
    end

    test "clears filter on tab switch" do
      panel = %BottomPanel{tabs: [:messages], active_tab: :messages, filter: :warnings}
      result = BottomPanel.switch_tab(panel, 0)
      assert result.filter == nil
    end
  end

  describe "next_tab/1 and prev_tab/1" do
    test "cycles forward through tabs" do
      panel = %BottomPanel{tabs: [:messages, :diagnostics, :terminal], active_tab: :messages}
      result = BottomPanel.next_tab(panel)
      assert result.active_tab == :diagnostics
    end

    test "wraps around at end" do
      panel = %BottomPanel{tabs: [:messages, :diagnostics], active_tab: :diagnostics}
      result = BottomPanel.next_tab(panel)
      assert result.active_tab == :messages
    end

    test "cycles backward through tabs" do
      panel = %BottomPanel{tabs: [:messages, :diagnostics, :terminal], active_tab: :terminal}
      result = BottomPanel.prev_tab(panel)
      assert result.active_tab == :diagnostics
    end

    test "wraps around at beginning" do
      panel = %BottomPanel{tabs: [:messages, :diagnostics], active_tab: :messages}
      result = BottomPanel.prev_tab(panel)
      assert result.active_tab == :diagnostics
    end
  end

  describe "resize/2" do
    test "sets height within bounds" do
      panel = %BottomPanel{}
      result = BottomPanel.resize(panel, 45)
      assert result.height_percent == 45
    end

    test "clamps to minimum 10%" do
      panel = %BottomPanel{}
      result = BottomPanel.resize(panel, 5)
      assert result.height_percent == 10
    end

    test "clamps to maximum 60%" do
      panel = %BottomPanel{}
      result = BottomPanel.resize(panel, 80)
      assert result.height_percent == 60
    end
  end

  describe "protocol encoding helpers" do
    test "tab_type_byte/1 returns correct bytes" do
      assert BottomPanel.tab_type_byte(:messages) == 0x01
      assert BottomPanel.tab_type_byte(:diagnostics) == 0x02
      assert BottomPanel.tab_type_byte(:terminal) == 0x03
    end

    test "tab_name/1 returns display names" do
      assert BottomPanel.tab_name(:messages) == "Messages"
      assert BottomPanel.tab_name(:diagnostics) == "Diagnostics"
      assert BottomPanel.tab_name(:terminal) == "Terminal"
    end

    test "filter_byte/1 returns correct bytes" do
      assert BottomPanel.filter_byte(nil) == 0x00
      assert BottomPanel.filter_byte(:warnings) == 0x01
    end
  end
end
