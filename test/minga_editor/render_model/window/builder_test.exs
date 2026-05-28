defmodule MingaEditor.RenderModel.Window.BuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Search.Match
  alias MingaEditor.Layout
  alias MingaEditor.RenderModel.Window.Builder
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.Renderer.Context
  alias MingaEditor.State, as: EditorState
  alias Minga.RenderModel.Window

  import MingaEditor.RenderPipeline.TestHelpers

  defp build_content(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = MingaEditor.RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    Content.build_content(state, scrolls)
  end

  defp build_window_model(state, ctx_overrides) do
    state = EditorState.sync_active_window_cursor(state)
    state = MingaEditor.RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    scroll = scrolls |> Map.values() |> hd()

    ctx =
      struct!(
        Context,
        Keyword.merge(
          [
            viewport: scroll.viewport,
            gutter_w: scroll.gutter_w,
            content_w: scroll.content_w,
            is_gui: true,
            wrap_on: scroll.wrap_on,
            line_number_style: scroll.line_number_style,
            width_oracle: scroll.width_oracle
          ],
          ctx_overrides
        )
      )

    Builder.build(state, scroll, ctx)
  end

  describe "GUI content stage" do
    test "builds a canonical window model and no GUI draw layers" do
      state = gui_state(content: "hello\nworld")
      {[wf], _cursor, _state} = build_content(state)

      assert %Window{} = wf.window_model
      assert wf.window_model.content_kind == :buffer
      assert Enum.map(wf.window_model.rows, & &1.text) == ["hello", "world"]
      assert wf.gutter == %{}
      assert wf.lines == %{}
      assert wf.tilde_lines == %{}
    end

    test "includes pane geometry and content epoch for GUI windows" do
      state = gui_state(content: "hello\nworld")
      {[wf], _cursor, _state} = build_content(state)
      model = wf.window_model

      assert model.geometry.window_id == state.workspace.windows.active
      assert model.geometry.total_rect == {0, 0, 80, 23}
      assert model.geometry.content_rect == {0, 0, 80, 23}
      assert model.geometry.gutter_rect == {0, 0, 6, 23}
      assert model.geometry.text_rect == {0, 6, 74, 23}
      assert model.geometry.viewport.rows == 23
      assert model.geometry.gutter_metrics.line_number_width == 3
      assert model.geometry.gutter_metrics.sign_col_width == 3
      assert Enum.map(model.geometry.hit_regions, & &1.kind) == [:text, :gutter, :fold_control]
      assert is_integer(model.content_epoch)
      assert model.full_refresh == true
    end

    test "wrapped lines produce continuation rows and cursor coordinates inside the visual row" do
      state = gui_state(cols: 20, content: "abcdefghijABCDEFGHIJ")
      buffer = state.workspace.buffers.active
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
      assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)
      :ok = BufferProcess.move_to(buffer, {0, 12})

      {[wf], _cursor, _state} = build_content(state)
      model = wf.window_model

      assert Enum.map(model.rows, & &1.row_type) == [:normal, :wrap_continuation]
      assert Enum.map(model.rows, & &1.visual_index) == [0, 1]
      assert Enum.map(model.rows, & &1.text) == ["abcdefghijABCD", "EFGHIJ"]
      assert model.cursor_row == 0
      assert model.cursor_col == 12
    end

    test "wrapped geometry reports total visual rows for the whole buffer" do
      content = Enum.map_join(1..10, "\n", fn _idx -> "abcdefghijABCDEFGHIJ" end)
      state = gui_state(rows: 4, cols: 20, content: content)
      buffer = state.workspace.buffers.active
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
      assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)

      {[wf], _cursor, _state} = build_content(state)

      assert wf.window_model.geometry.viewport.total_visual_rows == 20
    end

    test "wrapped overlay coordinates use visual rows and byte columns after previous wraps" do
      state = gui_state(cols: 20, content: "abcdefghijABCDEFGHIJ\nétarget")
      buffer = state.workspace.buffers.active
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
      assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)

      model =
        build_window_model(
          state,
          search_matches: [Match.new(1, 2, 6)],
          visual_selection: {:char, {1, 0}, {1, 7}}
        )

      assert Enum.map(model.rows, & &1.text) == ["abcdefghijABCD", "EFGHIJ", "étarget"]
      assert [%{row: 2, start_col: 1, end_col: 7}] = model.search_matches
      assert model.selection.start_row == 2
      assert model.selection.end_row == 2
      assert model.selection.end_col == 7
    end

    test "includes gutter and indent guide models built from current-frame data" do
      state = gui_state(content: "def a do\n  :ok\nend")
      {[wf], _cursor, _state} = build_content(state)

      assert wf.window_model.gutter.window_id == state.workspace.windows.active
      assert wf.window_model.gutter.entries != []
      assert wf.window_model.indent_guides.window_id == state.workspace.windows.active
    end

    test "TUI path keeps draw layers and skips the GUI window model" do
      state = base_state(content: "hello\nworld")
      {[wf], _cursor, _state} = build_content(state)

      assert wf.window_model == nil
      assert map_size(wf.lines) > 0
    end
  end
end
