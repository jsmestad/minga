defmodule MingaEditor.RenderPipeline.ContentTest do
  @moduledoc """
  Tests for the Content stage of the render pipeline.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.WrapMap
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.PromptRenderWindow
  alias MingaEditor.Agent.ViewContext
  alias MingaEditor.DisplayList.{Cursor, WindowFrame}
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.AgentChatPrefetch
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Viewport
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

  defp wrapped_content_width(state, buffer) do
    layout = Layout.get(state)

    content_width =
      case Layout.active_window_layout(layout, state) do
        %{content: {_row, _col, width, _height}} -> width
        nil -> elem(layout.editor_area, 2)
      end

    line_count = BufferProcess.line_count(buffer)

    gutter_width =
      case BufferProcess.get_option(buffer, :line_numbers) do
        :none -> Gutter.total_width(0)
        _ -> Gutter.total_width(Viewport.gutter_width(line_count))
      end

    max(content_width - gutter_width, 1)
  end

  defp layer_row_text(layer, row) do
    layer
    |> Map.get(row, [])
    |> Enum.map_join("", fn {_col, text, _face} -> text end)
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

    test "agent prompt window receives parent reset epoch and full-refresh" do
      state = gui_state(content: "regular buffer")
      {:ok, agent_buf} = BufferProcess.start_link(content: "agent line")
      win_id = state.workspace.windows.active
      window = Window.new_agent_chat(win_id, agent_buf, 24, 80)
      windows = %{state.workspace.windows | map: %{win_id => window}}
      agent_ui = UIState.new() |> UIState.ensure_prompt_buffer()
      state = %{state | workspace: %{state.workspace | windows: windows, agent_ui: agent_ui}}
      layout = Layout.put(state) |> Layout.get()
      win_layout = Map.fetch!(layout.window_layouts, win_id)
      {_row, _col, content_width, _height} = win_layout.content
      gutter_w = Gutter.total_width(Viewport.gutter_width(1))
      snapshot = BufferProcess.render_snapshot(agent_buf, 0, 1)

      prefetch = %AgentChatPrefetch{
        win_id: win_id,
        window: window,
        viewport: window.viewport,
        cursor_line: 0,
        cursor_byte_col: 0,
        cursor_col: 0,
        first_line: 0,
        snapshot: snapshot,
        line_number_style: :absolute,
        gutter_w: gutter_w,
        content_w: max(content_width - gutter_w, 1),
        buf_version: snapshot.version
      }

      {[frame], _cursor, _state} =
        Content.build_agent_chat_content(state, layout, %{win_id => prefetch})

      [prompt_model] = frame.additional_window_models

      default_prompt =
        PromptRenderWindow.build(
          ViewContext.from_editor_state(state),
          prompt_model.geometry.viewport.cols,
          prompt_model.rect
        )

      assert frame.window_model.full_refresh == true
      assert prompt_model.full_refresh == frame.window_model.full_refresh
      assert prompt_model.content_epoch != default_prompt.content_epoch
    end

    test "visual_row_offset renders the correct continuation slice and cursor position" do
      line = "    alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"
      state = base_state(content: line, rows: 5, cols: 24)
      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, true)
      _ = BufferProcess.set_option(buffer, :breakindent, true)
      _ = BufferProcess.set_option(buffer, :linebreak, true)

      content_width = wrapped_content_width(state, buffer)

      wrap_entry =
        WrapMap.compute([line], content_width,
          breakindent: true,
          linebreak: true,
          tab_width: 2
        )
        |> hd()

      assert length(wrap_entry) > 2

      target_idx = 2
      target_row = Enum.at(wrap_entry, target_idx)
      BufferProcess.move_to(buffer, {0, target_row.byte_offset})

      {scrolls, state, _layout} = run_through_scroll(state)
      [{_win_id, scroll}] = Map.to_list(scrolls)
      assert scroll.viewport.visual_row_offset > 0

      {[wf], cursor_info, _state} = Content.build_content(state, scrolls)
      top_row = Enum.min(Map.keys(wf.lines))

      assert String.contains?(
               layer_row_text(wf.lines, top_row),
               Enum.at(wrap_entry, scroll.viewport.visual_row_offset).source_text
             )

      assert String.trim(layer_row_text(wf.gutter, top_row + 1)) == ""
      assert %Cursor{row: row, col: col} = cursor_info
      assert row == top_row + target_idx - scroll.viewport.visual_row_offset
      assert col == scroll.gutter_w + target_row.indent_width
    end
  end
end
