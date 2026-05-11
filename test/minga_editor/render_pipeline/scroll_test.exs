defmodule MingaEditor.RenderPipeline.ScrollTest do
  @moduledoc """
  Tests for the Scroll stage of the render pipeline.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Invalidation
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.RenderPipeline.WindowDirty
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers

  # Helper to run through layout and scroll
  defp run_through_scroll(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {scrolls, state, layout}
  end

  defp clean_invalidation(win_id) do
    %Invalidation{
      full_redraw: false,
      windows: %{win_id => WindowDirty.clean()},
      chrome_regions: MapSet.new()
    }
  end

  defp trace_messages(pid) do
    receive do
      {:trace, ^pid, :receive, msg} -> [msg | trace_messages(pid)]
    after
      0 -> []
    end
  end

  describe "scroll_windows/2" do
    test "returns {scrolls, state} for each window" do
      state = base_state()
      {scrolls, state, _layout} = run_through_scroll(state)

      assert map_size(scrolls) == 1
      [{_win_id, scroll}] = Map.to_list(scrolls)
      assert %WindowScroll{} = scroll
      assert %EditorState{} = state
    end

    test "scroll result contains buffer lines" do
      state = base_state(content: "alpha\nbeta\ngamma")
      {scrolls, _state, _layout} = run_through_scroll(state)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      assert "alpha" in scroll.lines
      assert "beta" in scroll.lines
      assert "gamma" in scroll.lines
    end

    test "scroll result has correct cursor at line 0" do
      state = base_state()
      {scrolls, _state, _layout} = run_through_scroll(state)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      assert scroll.cursor_line == 0
      assert scroll.first_line == 0
      assert scroll.is_active == true
    end

    test "gutter_w is non-negative" do
      state = base_state()
      {scrolls, _state, _layout} = run_through_scroll(state)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      assert scroll.gutter_w >= 0
      assert scroll.content_w >= 1
    end

    test "scroll result includes buf_version" do
      state = base_state()
      {scrolls, _state, _layout} = run_through_scroll(state)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      assert is_integer(scroll.buf_version)
      assert scroll.buf_version >= 0
    end

    test "first frame marks all lines dirty on the window" do
      state = base_state()
      {_scrolls, state, _layout} = run_through_scroll(state)
      [{_win_id, window}] = Map.to_list(state.workspace.windows.map)

      # First frame: sentinel values trigger full invalidation
      assert window.render_cache.dirty_lines == :all
    end

    test "clean windows skip render_snapshot on later frames" do
      state = base_state(content: "alpha\nbeta\ngamma")
      {scrolls, state, layout} = run_through_scroll(state)
      {_frames, _cursor, state} = Content.build_content(state, scrolls)
      win_id = state.workspace.windows.active
      buf = state.workspace.buffers.active
      invalidation = clean_invalidation(win_id)

      :erlang.trace(buf, true, [:receive])
      {_scrolls, _state} = Scroll.scroll_windows(state, layout, invalidation)
      :erlang.trace(buf, false, [:receive])

      messages = trace_messages(buf)

      refute Enum.any?(messages, fn
               {:"$gen_call", _from, {:render_snapshot, _first, _count}} -> true
               _ -> false
             end)
    end

    test "clean active windows preserve horizontal scroll without fetched lines" do
      state = base_state(content: "alpha beta gamma delta epsilon zeta eta theta")
      {:ok, false} = Buffer.set_option(state.workspace.buffers.active, :wrap, false)
      {scrolls, state, layout} = run_through_scroll(state)
      {_frames, _cursor, state} = Content.build_content(state, scrolls)
      win_id = state.workspace.windows.active

      scrolled_window =
        state.workspace.windows.map
        |> Map.fetch!(win_id)
        |> Window.scroll_horizontal(12)

      state = put_in(state.workspace.windows.map[win_id], scrolled_window)
      invalidation = clean_invalidation(win_id)

      {scrolls, state} = Scroll.scroll_windows(state, layout, invalidation)
      scroll = Map.fetch!(scrolls, win_id)
      updated_window = Map.fetch!(state.workspace.windows.map, win_id)

      assert scroll.lines == []
      assert scroll.viewport.left == 12
      assert updated_window.viewport.left == 12
    end

    test "clean windows reuse cached buffer dirty status" do
      state = base_state(content: "alpha\nbeta\ngamma")
      {scrolls, state, layout} = run_through_scroll(state)
      {_frames, _cursor, state} = Content.build_content(state, scrolls)
      win_id = state.workspace.windows.active

      state = put_in(state.workspace.windows.map[win_id].render_cache.last_buffer_dirty, true)
      invalidation = clean_invalidation(win_id)

      {scrolls, _state} = Scroll.scroll_windows(state, layout, invalidation)
      scroll = Map.fetch!(scrolls, win_id)

      assert scroll.snapshot.dirty == true
    end
  end
end
