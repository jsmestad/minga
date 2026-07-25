defmodule MingaEditor.RenderPipeline.ComposeTest do
  @moduledoc """
  Tests for the Compose stage of the render pipeline.
  """

  use ExUnit.Case, async: true

  alias Minga.RenderModel.Cursor
  alias MingaEditor.RenderPipeline.ComposedFrame
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Compose
  alias MingaEditor.RenderPipeline.Content

  import MingaEditor.RenderPipeline.TestHelpers

  # Helper to run through scroll, content, and chrome
  defp run_through_chrome(state) do
    state = MingaEditor.WindowFocus.remember_active_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = run_scroll_stage(state, layout)
    {contents, cursor_info, state} = Content.build_content(state, scrolls)
    chrome = state.intent.frame.shell.build_chrome(state, layout, scrolls, cursor_info)
    {contents, chrome, cursor_info, state}
  end

  describe "compose_windows/4" do
    test "returns a ComposedFrame with the flattened window models and resolved cursor" do
      state = base_state()
      {contents, chrome, cursor_info, state} = run_through_chrome(state)

      frame = Compose.compose_windows(contents, chrome, cursor_info, state)

      assert %ComposedFrame{cursor: %Cursor{}} = frame
      assert frame.cursor.shape in [:block, :beam, :underline]
      assert [%Minga.RenderModel.Window{} | _] = frame.windows
    end

    test "frame resolves a cursor from the window content" do
      state = base_state()
      {contents, chrome, cursor_info, state} = run_through_chrome(state)

      frame = Compose.compose_windows(contents, chrome, cursor_info, state)

      assert %Cursor{} = frame.cursor
    end
  end
end
