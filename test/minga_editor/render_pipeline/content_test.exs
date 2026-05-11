defmodule MingaEditor.RenderPipeline.ContentTest do
  @moduledoc """
  Tests for the Content stage of the render pipeline.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.{Cursor, WindowFrame}
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Invalidation
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.RenderPipeline.WindowDirty
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers

  # Helper to run through scroll and get {scrolls, state}
  defp run_through_scroll(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {scrolls, state, layout}
  end

  defp invalidation(win_id, dirty) do
    %Invalidation{full_redraw: false, windows: %{win_id => dirty}, chrome_regions: MapSet.new()}
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

    test "updates window tracking fields after render" do
      state = base_state()
      {scrolls, state, _layout} = run_through_scroll(state)

      {_frames, _cursor, state} = Content.build_content(state, scrolls)

      [{_win_id, window}] = Map.to_list(state.workspace.windows.map)

      # After rendering, dirty_lines should be cleared
      assert window.render_cache.dirty_lines == %{}
      # Tracking fields should be set (no longer sentinels)
      assert window.render_cache.last_viewport_top >= 0
      assert window.render_cache.last_gutter_w >= 0
      assert window.render_cache.last_line_count > 0
      assert window.render_cache.last_buf_version >= 0
      assert %WindowFrame{} = window.render_cache.last_window_frame
    end

    test "clean windows return the cached window frame" do
      state = base_state(content: "alpha\nbeta\ngamma")
      {scrolls, state, layout} = run_through_scroll(state)
      {_frames, _cursor, state} = Content.build_content(state, scrolls)
      win_id = state.workspace.windows.active
      cached = Map.fetch!(state.workspace.windows.map, win_id).render_cache.last_window_frame
      clean = invalidation(win_id, WindowDirty.clean())

      {scrolls, state} = Scroll.scroll_windows(state, layout, clean)
      {[frame], cursor, _state} = Content.build_content(state, scrolls, clean)

      assert frame == %{cached | changed: false}
      assert cursor == frame.cursor
    end

    test "clean active windows refresh cached cursor shape" do
      state = base_state(content: "alpha\nbeta\ngamma")
      {scrolls, state, layout} = run_through_scroll(state)
      {_frames, _cursor, state} = Content.build_content(state, scrolls)
      win_id = state.workspace.windows.active
      clean = invalidation(win_id, WindowDirty.clean())

      state = put_in(state.workspace.editing.mode, :insert)
      {scrolls, state} = Scroll.scroll_windows(state, layout, clean)
      {[frame], cursor, _state} = Content.build_content(state, scrolls, clean)

      assert frame.changed == false
      assert frame.cursor.shape == :beam
      assert cursor.shape == :beam
    end

    test "row dirty windows merge rebuilt rows with cached rows" do
      state = base_state(content: "alpha\nbeta\ngamma")
      {scrolls, state, layout} = run_through_scroll(state)
      {_frames, _cursor, state} = Content.build_content(state, scrolls)
      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)

      cached_window =
        window
        |> Window.cache_line(0, [], [DisplayList.draw(0, 4, "cached row 0")])
        |> Window.mark_dirty([1])

      state = put_in(state.workspace.windows.map[win_id], cached_window)
      rows = invalidation(win_id, WindowDirty.rows([1], :buffer_edit))

      {scrolls, state} = Scroll.scroll_windows(state, layout, rows)
      {[frame], _cursor, _state} = Content.build_content(state, scrolls, rows)
      draws = DisplayList.layer_to_draws(frame.lines)

      assert Enum.any?(draws, fn {_row, _col, text, _face} -> text == "cached row 0" end)
      assert Enum.any?(draws, fn {_row, _col, text, _face} -> String.contains?(text, "beta") end)
    end
  end
end
