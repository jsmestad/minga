defmodule MingaEditor.Shell.Traditional.Chrome.GUITest do
  use ExUnit.Case, async: true

  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.Shell.Traditional.Chrome.GUI, as: ChromeGUI
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll

  import MingaEditor.RenderPipeline.TestHelpers

  defp run_through_content(state) do
    state = MingaEditor.WindowFocus.remember_active_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {_frames, cursor_info, state} = Content.build_content(state, scrolls)
    {scrolls, cursor_info, state, layout}
  end

  describe "Chrome.GUI.build/4" do
    test "returns a Chrome struct" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeGUI.build(state, layout, scrolls, cursor_info)

      assert %Chrome{} = chrome
    end

    test "overlays and click regions are empty (SwiftUI handles chrome surfaces)" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeGUI.build(state, layout, scrolls, cursor_info)

      assert chrome.overlays == []
      assert chrome.modeline_click_regions == []
      assert chrome.tab_bar_click_regions == []
    end

    test "status bar data is computed for GUI emission via 0x76 opcode" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeGUI.build(state, layout, scrolls, cursor_info)

      assert {:buffer, _} = chrome.status_bar_data
    end
  end
end
