defmodule MingaEditor.BottomPanelTest do
  use ExUnit.Case, async: true

  alias MingaEditor.BottomPanel

  describe "new panel" do
    test "starts hidden and unfocused with no filter" do
      panel = %BottomPanel{}
      assert panel.visible == false
      assert panel.focused == false
      assert panel.filter == nil
      assert panel.height_percent == 30
    end
  end

  describe "toggle/1" do
    test "toggles from hidden to visible and clears filter" do
      panel = %BottomPanel{visible: false, filter: :warnings}
      result = BottomPanel.toggle(panel)
      assert result.visible == true
      assert result.filter == nil
    end

    test "toggles from visible to hidden and clears focus" do
      panel = %BottomPanel{visible: true, focused: true}
      result = BottomPanel.toggle(panel)
      assert result.visible == false
      assert result.focused == false
    end
  end

  describe "show/2" do
    test "shows panel with nil filter" do
      panel = %BottomPanel{visible: false, filter: :warnings}
      result = BottomPanel.show(panel)
      assert result.visible == true
      assert result.filter == nil
    end

    test "shows panel with warnings filter" do
      panel = %BottomPanel{visible: false}
      result = BottomPanel.show(panel, :warnings)
      assert result.visible == true
      assert result.filter == :warnings
    end
  end

  describe "hide/1" do
    test "hides panel and clears focus" do
      panel = %BottomPanel{visible: true, focused: true, filter: :warnings}
      result = BottomPanel.hide(panel)
      assert result.visible == false
      assert result.focused == false
      assert result.filter == :warnings
    end
  end

  describe "focus/1 and blur/1" do
    test "focuses a visible panel" do
      panel = %BottomPanel{visible: true}
      result = BottomPanel.focus(panel)
      assert BottomPanel.focused?(result)
    end

    test "does not focus a hidden panel" do
      panel = %BottomPanel{visible: false}
      result = BottomPanel.focus(panel)
      refute BottomPanel.focused?(result)
    end

    test "blur clears focus without hiding" do
      panel = %BottomPanel{visible: true, focused: true}
      result = BottomPanel.blur(panel)
      assert result.visible == true
      refute BottomPanel.focused?(result)
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
    test "filter_byte/1 returns correct bytes" do
      assert BottomPanel.filter_byte(nil) == 0x00
      assert BottomPanel.filter_byte(:warnings) == 0x01
    end
  end
end
