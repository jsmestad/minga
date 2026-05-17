defmodule MingaEditor.RenderPipeline.ContentTest do
  @moduledoc """
  Tests for the Content stage of the render pipeline.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.DisplayList.{Cursor, WindowFrame}
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.Window
  alias MingaEditor.State, as: EditorState

  import MingaEditor.RenderPipeline.TestHelpers

  # Helper to run through scroll and get {scrolls, state}
  defp run_through_scroll(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {scrolls, state, layout}
  end

  describe "build_content/2" do
    test "returns {WindowFrames, cursor_info, state}" do
      state = base_state()
      {scrolls, state, _layout} = run_through_scroll(state)

      {frames, cursor_info, state} = Content.build_content(state, scrolls)

      assert [%WindowFrame{} | _] = frames
      assert %Cursor{row: row, col: col, shape: shape} = cursor_info
      assert is_integer(row)
      assert is_integer(col)
      assert shape in [:block, :beam, :underline]
      assert %EditorState{} = state
    end

    test "WindowFrame contains gutter and line layers" do
      state = base_state(content: "hello world")
      {scrolls, state, _layout} = run_through_scroll(state)

      {[wf], _cursor, _state} = Content.build_content(state, scrolls)

      assert map_size(wf.lines) >= 1
    end

    test "modeline layer is empty (Chrome handles modeline)" do
      state = base_state()
      {scrolls, state, _layout} = run_through_scroll(state)

      {[wf], _cursor, _state} = Content.build_content(state, scrolls)

      assert wf.modeline == %{}
    end

    test "visible_line_map keeps wrapped cursor math out of the folded path" do
      state =
        base_state(
          content:
            String.duplicate("a", 120) <>
              "\n" <> String.duplicate("b", 160) <> "\nvisible\nfold\ntail"
        )

      buffer = state.workspace.buffers.active
      Minga.Buffer.Process.set_option(buffer, :wrap, true)
      Minga.Buffer.Process.move_to(buffer, {2, 0})
      assert Minga.Buffer.Process.cursor(buffer) == {2, 0}

      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)
      window = Window.set_fold_ranges(window, [Minga.Editing.Fold.Range.new!(3, 4)])
      window = Window.fold_at(window, 3)
      state = put_in(state.workspace.windows.map[win_id], window)

      {scrolls, state, _layout} = run_through_scroll(state)
      [{_scroll_win_id, scroll}] = Map.to_list(scrolls)
      assert scroll.visible_line_map != nil

      {[wf], cursor_info, _state} = Content.build_content(state, scrolls)

      assert %Cursor{row: row} = cursor_info
      assert row <= 3
      assert Enum.max(Map.keys(wf.lines)) <= 4
    end

    test "updates window tracking fields after render" do
      state = base_state()
      {scrolls, state, _layout} = run_through_scroll(state)

      {_frames, _cursor, state} = Content.build_content(state, scrolls)

      [{_win_id, window}] = Map.to_list(state.workspace.windows.map)

      # After rendering, dirty_lines should be cleared
      assert window.render_cache.dirty_lines == %{}
      # Tracking fields should be set (no longer sentinels)
      assert window.render_cache.last_viewport_top >= 0
      assert window.render_cache.last_viewport_cache_key >= 0
      assert window.render_cache.last_gutter_w >= 0
      assert window.render_cache.last_line_count > 0
      assert window.render_cache.last_buf_version >= 0
    end
  end
end
