defmodule MingaEditor.RenderPipeline.ChromeTest do
  @moduledoc """
  Tests for the Chrome stage of the render pipeline.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.RenderPipeline.Content

  import MingaEditor.RenderPipeline.TestHelpers

  # Helper to run through scroll and content
  defp run_through_content(state) do
    state = MingaEditor.WindowFocus.remember_active_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = run_scroll_stage(state, layout)
    {_frames, cursor_info, state} = Content.build_content(state, scrolls)
    {scrolls, cursor_info, state, layout}
  end

  describe "build_chrome/4" do
    test "returns a Chrome struct with GUI capabilities" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = state.shell.build_chrome(state, layout, scrolls, cursor_info)

      assert %Chrome{} = chrome
    end

    test "click regions and overlays are empty (SwiftUI handles chrome surfaces)" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = state.shell.build_chrome(state, layout, scrolls, cursor_info)

      assert chrome.tab_bar_click_regions == []
      assert chrome.modeline_click_regions == []
      assert chrome.overlays == []
    end

    test "status bar data is computed for GUI (consumed by 0x76 opcode)" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = state.shell.build_chrome(state, layout, scrolls, cursor_info)

      assert {:buffer, _} = chrome.status_bar_data
    end
  end
end
