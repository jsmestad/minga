defmodule Minga.Editor.RenderPipeline.Chrome.TUITest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline
  alias Minga.Editor.RenderPipeline.Chrome
  alias Minga.Editor.RenderPipeline.Chrome.TUI, as: ChromeTUI
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

  describe "Chrome.TUI.build/4" do
    test "returns a Chrome struct" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert %Chrome{} = chrome
    end

    test "tab bar field is a list (TUI renders tab bar)" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert is_list(chrome.tab_bar)
    end

    test "includes minibuffer draw" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert [_ | _] = chrome.minibuffer
    end

    test "includes global status bar draws" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert [_ | _] = chrome.status_bar_draws
    end

    test "includes region definitions" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = ChromeTUI.build(state, layout, scrolls, cursor_info)

      assert is_list(chrome.regions)
      assert Enum.all?(chrome.regions, &is_binary/1)
    end
  end
end
