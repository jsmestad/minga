defmodule MingaEditor.RenderPipeline.ContentTest do
  @moduledoc """
  Tests for the Content stage of the render pipeline.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Session.State, as: SessionState
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.WrapMap
  alias Minga.RenderModel.Cursor
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.View.PromptRenderWindow
  alias MingaEditor.Agent.ViewContext
  alias MingaEditor.RenderPipeline.WindowContent
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.BufferChanges
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Renderer.State, as: RendererState
  alias MingaEditor.Viewport
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers

  # Helper to run through scroll and get {scrolls, state}
  defp run_through_scroll(state) do
    state = MingaEditor.WindowFocus.remember_active_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = run_scroll_stage(state, layout)
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

  describe "build_content/2" do
    test "returns {WindowContents, cursor_info, state}" do
      state = base_state()
      {scrolls, state, _layout} = run_through_scroll(state)

      {contents, cursor_info, state} = Content.build_content(state, scrolls)

      assert [%WindowContent{models: [%Minga.RenderModel.Window{} | _]} | _] = contents
      assert %Cursor{row: row, col: col, shape: shape} = cursor_info
      assert is_integer(row)
      assert is_integer(col)
      assert shape in [:block, :beam, :underline]
      assert %Input{} = state
    end

    test "window content carries the semantic window model" do
      state = base_state(content: "hello world")
      {scrolls, state, _layout} = run_through_scroll(state)

      {[content], _cursor, _state} = Content.build_content(state, scrolls)

      assert [%Minga.RenderModel.Window{content_kind: :buffer} = model] = content.models
      assert Enum.any?(model.rows, fn row -> String.contains?(row.text, "hello world") end)
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

      state = %{
        state
        | workspace:
            SessionState.set_windows(state.workspace, %{
              state.workspace.windows
              | map: Map.put(state.workspace.windows.map, win_id, window)
            })
      }

      {scrolls, state, _layout} = run_through_scroll(state)
      [{_scroll_win_id, scroll}] = Map.to_list(scrolls)
      assert scroll.visible_line_map != nil

      {[_content], cursor_info, _state} = Content.build_content(state, scrolls)

      assert %Cursor{row: row} = cursor_info
      assert row <= 3
    end

    test "updates window tracking fields after render" do
      state = base_state()
      {scrolls, state, _layout} = run_through_scroll(state)

      {_frames, _cursor, state} = Content.build_content(state, scrolls)

      [{_win_id, window}] = Map.to_list(state.windows.map)

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
      win_id = state.workspace.windows.active
      window = Window.new_agent_chat(win_id, 24, 80)
      windows = %{state.workspace.windows | map: %{win_id => window}}
      agent_ui = UIState.new() |> MingaEditor.Agent.PromptBuffer.ensure()

      transcript = %{
        line_index: [{0, :text}, {0, :code}, {1, :tool}],
        display_messages: [],
        display_message_pairs: [],
        markdown: "",
        line_offsets: []
      }

      panel = Panel.cache_transcript_display(agent_ui.panel, transcript, nil)
      agent_ui = UIState.replace_panel(agent_ui, panel)
      state = %{state | workspace: %{state.workspace | windows: windows, agent_ui: agent_ui}}
      intent = Intent.from_editor_state(state)
      renderer = RendererState.new(editor_pid: nil, pipeline: &RenderPipeline.run/1)
      {_renderer, input} = BufferChanges.prepare(renderer, intent)
      layout = Layout.put(input) |> Layout.get()

      {[content], _cursor, output} = Content.build_agent_chat_content(input, layout)

      [prompt_model] = content.models
      updated_window = Map.fetch!(output.windows.map, win_id)

      {content_row, _content_col, _content_width, _content_height} =
        layout.window_layouts[win_id].content

      {prompt_row, _prompt_col, prompt_width, _prompt_height} = prompt_model.rect

      assert updated_window.viewport.rows == prompt_row - content_row - 1
      assert updated_window.viewport.cols == prompt_width
      assert updated_window.viewport.reserved == 0

      assert output.workspace.agent_ui.panel.scroll.metrics == %{
               total_lines: 3,
               visible_height: updated_window.viewport.rows
             }

      default_prompt =
        PromptRenderWindow.build(
          ViewContext.from_editor_state(state),
          prompt_model.geometry.viewport.cols,
          prompt_model.rect
        )

      assert prompt_model.full_refresh == true
      assert prompt_model.content_epoch == default_prompt.content_epoch
    end

    test "visual_row_offset resolves the cursor position within the continuation slice" do
      line = "    alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"
      # Layout.GUI reserves only the minibuffer row, so a smaller viewport is
      # needed for the wrapped line to still overflow the editor area.
      state = base_state(content: line, rows: 3, cols: 24)
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

      assert Enum.count(wrap_entry) > 2

      target_idx = 2
      target_row = Enum.at(wrap_entry, target_idx)
      BufferProcess.move_to(buffer, {0, target_row.byte_offset})

      {scrolls, state, _layout} = run_through_scroll(state)
      [{_win_id, scroll}] = Map.to_list(scrolls)
      assert scroll.viewport.visual_row_offset > 0

      {[_content], cursor_info, _state} = Content.build_content(state, scrolls)

      # The active window's cursor row accounts for the visual-row offset so the
      # cursor lands on the on-screen continuation slice, not the logical line top.
      assert %Cursor{row: row, col: col} = cursor_info
      assert row == target_idx - scroll.viewport.visual_row_offset
      assert col == scroll.gutter_w + target_row.indent_width
    end
  end
end
