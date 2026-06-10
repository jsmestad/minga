defmodule MingaEditor.RenderPipeline.ComposeTest do
  @moduledoc """
  Tests for the Compose stage of the render pipeline.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.DisplayList.{Cursor, Frame}
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Compose
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.State, as: EditorState

  import MingaEditor.RenderPipeline.TestHelpers

  # Helper to run through scroll, content, and chrome
  defp run_through_chrome(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {frames, cursor_info, state} = Content.build_content(state, scrolls)
    chrome = state.shell.build_chrome(state, layout, scrolls, cursor_info)
    {frames, chrome, cursor_info, state}
  end

  describe "compose_windows/4" do
    test "returns a Frame struct" do
      state = base_state()
      {frames, chrome, cursor_info, state} = run_through_chrome(state)

      frame = Compose.compose_windows(frames, chrome, cursor_info, state)

      assert %Frame{cursor: %Cursor{}} = frame
      assert frame.cursor.shape in [:block, :beam, :underline]
    end

    test "frame carries the chrome struct fields through unchanged" do
      # Compose assembles the chrome fields into the final frame. The semantic
      # chrome owns the status bar (0x76) and minibuffer (0x7F) natively, so the
      # cell-draw lists are empty; Compose still threads whatever chrome built.
      state = base_state()
      {frames, chrome, cursor_info, state} = run_through_chrome(state)

      frame = Compose.compose_windows(frames, chrome, cursor_info, state)

      assert frame.status_bar == chrome.status_bar_draws
      assert frame.minibuffer == chrome.minibuffer
      assert frame.tab_bar == chrome.tab_bar
      assert frame.overlays == chrome.overlays
    end

    test "frame resolves a cursor from the window content" do
      state = base_state()
      {frames, chrome, cursor_info, state} = run_through_chrome(state)

      frame = Compose.compose_windows(frames, chrome, cursor_info, state)

      assert %Cursor{} = frame.cursor
    end
  end
end
