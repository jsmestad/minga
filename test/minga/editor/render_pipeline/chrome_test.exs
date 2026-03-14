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

  describe "build_chrome/4" do
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

    test "chrome contains modeline draws per window" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = Chrome.build_chrome(state, layout, scrolls, cursor_info)

      assert map_size(chrome.modeline_draws) == 1
      [{_win_id, draws}] = Map.to_list(chrome.modeline_draws)
      assert [_ | _] = draws
    end

    test "chrome regions is a list of binaries" do
      state = base_state()
      {scrolls, cursor_info, state, layout} = run_through_content(state)

      chrome = Chrome.build_chrome(state, layout, scrolls, cursor_info)

      assert is_list(chrome.regions)
      assert Enum.all?(chrome.regions, &is_binary/1)
    end
  end
end
