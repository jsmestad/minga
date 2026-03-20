defmodule Minga.Editor.RenderPipeline.ChromeTest do
  @moduledoc """
  Tests for the Chrome stage of the render pipeline.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline
  alias Minga.Editor.RenderPipeline.Chrome
  alias Minga.Editor.RenderPipeline.Content
  alias Minga.Editor.RenderPipeline.Scroll
  alias Minga.Editor.State, as: EditorState

  import Minga.Editor.RenderPipeline.TestHelpers

  # Helper to run through scroll and content
  defp run_through_content(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {_frames, cursor_info, state} = Content.build_content(state, scrolls)
    {scrolls, cursor_info, state, layout}
  end

  alias Minga.Port.Capabilities

  describe "build_chrome/4 TUI path" do
    test "returns a Chrome struct" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = Chrome.build_chrome(state, layout, scrolls, cursor_info)

      assert %Chrome{} = chrome
    end

    test "chrome contains minibuffer draw" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = Chrome.build_chrome(state, layout, scrolls, cursor_info)

      assert [_ | _] = chrome.minibuffer
      assert Enum.all?(chrome.minibuffer, &is_tuple/1)
    end

    test "chrome contains global status bar draws" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = Chrome.build_chrome(state, layout, scrolls, cursor_info)

      assert [_ | _] = chrome.status_bar_draws
    end

    test "chrome regions is a list of binaries" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = Chrome.build_chrome(state, layout, scrolls, cursor_info)

      assert is_list(chrome.regions)
      assert Enum.all?(chrome.regions, &is_binary/1)
    end
  end

  describe "build_chrome/4 GUI path" do
    defp gui_state(opts \\ []) do
      state = base_state(opts)
      %{state | capabilities: %Capabilities{frontend_type: :native_gui}}
    end

    test "returns a Chrome struct with GUI capabilities" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = Chrome.build_chrome(state, layout, scrolls, cursor_info)

      assert %Chrome{} = chrome
    end

    test "tab bar and file tree are empty (SwiftUI handles them)" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = Chrome.build_chrome(state, layout, scrolls, cursor_info)

      assert chrome.tab_bar == []
      assert chrome.tab_bar_click_regions == []
      assert chrome.file_tree == []
    end

    test "status bar draws are empty for GUI (SwiftUI owns the status bar surface)" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = Chrome.build_chrome(state, layout, scrolls, cursor_info)

      assert chrome.status_bar_draws == []
      assert chrome.modeline_click_regions == []
    end

    test "status bar data is computed for GUI (consumed by Emit.GUI 0x76 opcode)" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = Chrome.build_chrome(state, layout, scrolls, cursor_info)

      assert {:buffer, _} = chrome.status_bar_data
    end

    test "minibuffer is still rendered" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = Chrome.build_chrome(state, layout, scrolls, cursor_info)

      assert [_ | _] = chrome.minibuffer
    end

    test "regions are still produced" do
      state = gui_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = Chrome.build_chrome(state, layout, scrolls, cursor_info)

      assert is_list(chrome.regions)
      assert Enum.all?(chrome.regions, &is_binary/1)
    end
  end
end
