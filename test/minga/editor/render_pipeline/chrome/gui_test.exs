defmodule Minga.Editor.RenderPipeline.Chrome.GUITest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline
  alias Minga.Editor.RenderPipeline.Chrome
  alias Minga.Editor.RenderPipeline.Chrome.GUI, as: ChromeGUI
  alias Minga.Editor.RenderPipeline.Content
  alias Minga.Editor.RenderPipeline.Scroll
  alias Minga.Editor.State, as: EditorState

  import Minga.Editor.RenderPipeline.TestHelpers

  defp run_through_content(state) do
    state = EditorState.sync_active_window_cursor(state)
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

    test "tab bar and file tree are empty (SwiftUI handles them)" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeGUI.build(state, layout, scrolls, cursor_info)

      assert chrome.tab_bar == []
      assert chrome.file_tree == []
      assert chrome.agent_panel == []
    end

    test "status bar draws are empty for GUI (SwiftUI owns the status bar surface)" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeGUI.build(state, layout, scrolls, cursor_info)

      assert chrome.status_bar_draws == []
    end

    test "status bar data is computed for GUI emission via 0x76 opcode" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeGUI.build(state, layout, scrolls, cursor_info)

      assert {:buffer, _} = chrome.status_bar_data
    end

    test "minibuffer is still rendered in Metal" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeGUI.build(state, layout, scrolls, cursor_info)

      assert [_ | _] = chrome.minibuffer
    end

    test "includes region definitions" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeGUI.build(state, layout, scrolls, cursor_info)

      assert is_list(chrome.regions)
    end
  end
end
