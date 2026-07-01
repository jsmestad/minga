defmodule MingaEditor.RenderModel.Window.BuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias Minga.Editing.Fold.Range, as: FoldRange
  alias Minga.Editing.Search.Match
  alias Minga.Language.Highlight.Span, as: HighlightSpan
  alias MingaEditor.Layout
  alias MingaEditor.RenderModel.Window.Builder
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.Renderer.Context
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window, as: EditorWindow
  alias MingaEditor.WindowTree
  alias MingaEditor.UI.Highlight
  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.ScrollPresentation

  import MingaEditor.RenderPipeline.TestHelpers

  # Runs the Content stage and reshapes each WindowContent carrier into a map
  # exposing the primary window model, any additional models, and the cursor,
  # so these builder tests can assert against the window model directly.
  defp build_content(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = MingaEditor.RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {contents, cursor, state} = Content.build_content(state, scrolls)
    {Enum.map(contents, &to_window_view/1), cursor, state}
  end

  defp to_window_view(%MingaEditor.RenderPipeline.WindowContent{models: models, cursor: cursor}) do
    %{
      window_model: List.first(models),
      additional_window_models: Enum.drop(models, 1),
      cursor: cursor
    }
  end

  defp add_conceal(decs, start_pos, end_pos) do
    {_id, decs} = Decorations.add_conceal(decs, start_pos, end_pos, group: :test)
    decs
  end

  defp highlight_span(lines, line, start_col, width, capture_id) do
    start_byte = Highlight.byte_offset_for_line(lines, line) + start_col
    HighlightSpan.new(start_byte, start_byte + width, capture_id)
  end

  defp has_span?(%Row{spans: spans}, start_col, end_col) do
    Enum.any?(spans, fn span ->
      span.start_col == start_col and span.end_col == end_col and span.fg != 0
    end)
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
    test "builds a canonical window model" do
      state = gui_state(content: "hello\nworld")
      {[wf], _cursor, _state} = build_content(state)

      assert %Window{} = wf.window_model
      assert wf.window_model.content_kind == :buffer
      assert Enum.map(wf.window_model.rows, & &1.text) == ["hello", "world"]
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

      assert Enum.find(model.geometry.hit_regions, &(&1.kind == :fold_control)).rect ==
               {0, 2, 1, 23}

      assert Enum.map(model.geometry.hit_regions, & &1.kind) == [:text, :gutter, :fold_control]
      assert is_integer(model.content_epoch)
      assert model.full_refresh == true
    end

    test "split pane geometry includes divider hit regions" do
      state = gui_state(content: "left\nright")
      buffer = state.workspace.buffers.active
      {:ok, tree} = WindowTree.split(state.workspace.windows.tree, 1, :vertical, 2)
      second = EditorWindow.new(2, buffer, 24, 80)

      windows = %Windows{
        state.workspace.windows
        | tree: tree,
          map: Map.put(state.workspace.windows.map, 2, second),
          next_id: 3
      }

      state = %{state | workspace: %{state.workspace | windows: windows}}

      {[left, right], _cursor, _state} = build_content(state)

      divider_regions =
        [left.window_model, right.window_model]
        |> Enum.flat_map(& &1.geometry.hit_regions)
        |> Enum.filter(&(&1.kind == :divider))

      assert Enum.any?(divider_regions, &(&1.rect == {0, 39, 1, 23}))
    end

    test "inactive GUI windows hide their cursor" do
      state = gui_state(content: "left\nright")
      buffer = state.workspace.buffers.active
      {:ok, tree} = WindowTree.split(state.workspace.windows.tree, 1, :vertical, 2)
      second = EditorWindow.new(2, buffer, 24, 80)

      windows = %Windows{
        state.workspace.windows
        | tree: tree,
          map: Map.put(state.workspace.windows.map, 2, second),
          next_id: 3
      }

      state = %{state | workspace: %{state.workspace | windows: windows}}

      {[left, right], _cursor, _state} = build_content(state)

      assert left.window_model.cursor_visible == true
      assert right.window_model.cursor_visible == false
    end

    test "ordinary buffer edits change row hashes without bumping content epoch or forcing refresh" do
      state = gui_state(content: "hello")
      {[wf], _cursor, state} = build_content(state)
      epoch = wf.window_model.content_epoch
      old_hash = hd(wf.window_model.rows).content_hash
      assert wf.window_model.full_refresh == true

      :ok = BufferProcess.insert_text(state.workspace.buffers.active, "!")
      {[wf], _cursor, _state} = build_content(state)

      assert wf.window_model.content_epoch == epoch
      assert wf.window_model.full_refresh == false
      assert hd(wf.window_model.rows).content_hash != old_hash
    end

    test "resize reset fingerprint bumps content epoch and forces full refresh" do
      state = gui_state(content: "hello")
      {[wf], _cursor, state} = build_content(state)
      epoch = wf.window_model.content_epoch

      resized = %{state | terminal_viewport: Viewport.new(24, 100)}
      {[wf], _cursor, _state} = build_content(resized)

      assert wf.window_model.content_epoch != epoch
      assert wf.window_model.full_refresh == true
    end

    test "removed diff signs survive in gutter entries" do
      state = gui_state(content: "removed\nkept")
      model = build_window_model(state, git_signs: %{0 => :removed})

      [entry | _] = model.gutter.entries
      assert entry.sign_type == :git_removed
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

      assert Enum.map(model.rows, & &1.row_id) == [
               Row.stable_id(:normal, 0),
               Row.stable_id(:wrap_continuation, 0, 1)
             ]

      assert Enum.map(model.rows, & &1.text) == ["abcdefghijABCD", "EFGHIJ"]
      assert Enum.map(model.gutter.entries, & &1.display_type) == [:normal, :wrap_continuation]
      assert model.cursor_row == 0
      assert model.cursor_col == 12
    end

    test "virtual line row IDs stay stable when earlier siblings are removed" do
      state = gui_state(content: "line\nnext")
      buffer = state.workspace.buffers.active

      first_id =
        BufferProcess.add_virtual_text(buffer, {0, 0},
          segments: [{"first virtual", Face.new()}],
          placement: :above,
          priority: 0
        )

      second_id =
        BufferProcess.add_virtual_text(buffer, {0, 0},
          segments: [{"second virtual", Face.new()}],
          placement: :above,
          priority: 1
        )

      {[wf], _cursor, _state} = build_content(state)

      virtual_rows = Enum.filter(wf.window_model.rows, &(&1.row_type == :virtual_line))
      assert Enum.map(virtual_rows, & &1.text) == ["first virtual", "second virtual"]

      virtual_gutters = Enum.take(wf.window_model.gutter.entries, 2)
      assert Enum.map(virtual_gutters, & &1.display_type) == [:blank, :blank]
      assert Enum.map(virtual_gutters, & &1.sign_type) == [:none, :none]

      assert Enum.map(virtual_rows, & &1.row_id) == [
               Row.stable_decoration_id(:virtual_line, 0, first_id),
               Row.stable_decoration_id(:virtual_line, 0, second_id)
             ]

      :ok = BufferProcess.remove_virtual_text(buffer, first_id)

      {[wf], _cursor, _state} = build_content(state)

      [remaining] = Enum.filter(wf.window_model.rows, &(&1.row_type == :virtual_line))
      assert remaining.text == "second virtual"
      assert remaining.row_id == Row.stable_decoration_id(:virtual_line, 0, second_id)
    end

    test "block decoration row IDs stay stable when earlier siblings are removed" do
      state = gui_state(content: "line\nnext")
      buffer = state.workspace.buffers.active

      first_id =
        BufferProcess.add_block_decoration(buffer, 0,
          placement: :above,
          render: fn _width -> [{"first block", Face.new()}] end,
          priority: 0
        )

      second_id =
        BufferProcess.add_block_decoration(buffer, 0,
          placement: :above,
          render: fn _width -> [{"second block", Face.new()}] end,
          priority: 1
        )

      {[wf], _cursor, _state} = build_content(state)

      block_rows = Enum.filter(wf.window_model.rows, &(&1.row_type == :block))
      assert Enum.map(block_rows, & &1.text) == ["first block", "second block"]

      block_gutters = Enum.take(wf.window_model.gutter.entries, 2)
      assert Enum.map(block_gutters, & &1.display_type) == [:blank, :blank]
      assert Enum.map(block_gutters, & &1.sign_type) == [:none, :none]

      assert Enum.map(block_rows, & &1.row_id) == [
               Row.stable_decoration_id(:block, 0, {first_id, 0}),
               Row.stable_decoration_id(:block, 0, {second_id, 0})
             ]

      :ok = BufferProcess.remove_block_decoration(buffer, first_id)

      {[wf], _cursor, _state} = build_content(state)

      [remaining] = Enum.filter(wf.window_model.rows, &(&1.row_type == :block))
      assert remaining.text == "second block"
      assert remaining.row_id == Row.stable_decoration_id(:block, 0, {second_id, 0})
    end

    test "fold-start rows use stable ids for window folds" do
      state = gui_state(content: "line 1\nline 2\nline 3")
      window = Map.fetch!(state.workspace.windows.map, state.workspace.windows.active)
      window = EditorWindow.set_fold_ranges(window, [FoldRange.new!(0, 2)])
      window = EditorWindow.fold_at(window, 0)

      windows =
        Windows.set_map(
          state.workspace.windows,
          Map.put(state.workspace.windows.map, state.workspace.windows.active, window)
        )

      state = %{state | workspace: %{state.workspace | windows: windows}}

      {[wf], _cursor, _state} = build_content(state)

      [fold_row] = Enum.filter(wf.window_model.rows, &(&1.row_type == :fold_start))
      [fold_gutter] = Enum.filter(wf.window_model.gutter.entries, &(&1.buf_line == 0))
      assert fold_row.row_id == Row.stable_id(:fold_start, 0, 0, 2)
      assert fold_gutter.display_type == :fold_start
    end

    test "folded window rows preserve syntax highlight spans" do
      content = "def folded\n  :ok\nend\nclass Visible\nend"
      lines = String.split(content, "\n")
      state = gui_state(content: content)
      buffer = state.workspace.buffers.active

      highlight =
        state.theme
        |> Highlight.from_theme()
        |> Highlight.put_names(["keyword"])
        |> Highlight.put_spans(1, [
          highlight_span(lines, 0, 0, 3, 0),
          highlight_span(lines, 3, 0, 5, 0)
        ])

      state =
        EditorState.set_highlight(state, %Highlighting{highlights: %{buffer => highlight}})

      window = Map.fetch!(state.workspace.windows.map, state.workspace.windows.active)
      window = EditorWindow.set_fold_ranges(window, [FoldRange.new!(0, 2)])
      window = EditorWindow.fold_at(window, 0)

      windows =
        Windows.set_map(
          state.workspace.windows,
          Map.put(state.workspace.windows.map, state.workspace.windows.active, window)
        )

      state = %{state | workspace: %{state.workspace | windows: windows}}

      {[wf], _cursor, _state} = build_content(state)

      [fold_row, visible_row | _rest] = wf.window_model.rows
      assert fold_row.row_type == :fold_start
      assert fold_row.text == "def folded ··· 2 lines"
      assert has_span?(fold_row, 0, 3)

      assert visible_row.text == "class Visible"
      assert has_span?(visible_row, 0, 5)
    end

    test "decoration fold rows use stable decoration ids" do
      state = gui_state(content: "line 1\nline 2\nline 3")
      buffer = state.workspace.buffers.active

      :ok =
        BufferProcess.batch_decorations(buffer, fn decs ->
          {_id, decs} = Decorations.add_fold_region(decs, 0, 2, closed: true)
          decs
        end)

      [fold] = BufferProcess.decorations(buffer).fold_regions

      {[wf], _cursor, _state} = build_content(state)

      [fold_row] = Enum.filter(wf.window_model.rows, &(&1.row_type == :fold_start))
      [fold_gutter] = Enum.filter(wf.window_model.gutter.entries, &(&1.buf_line == 0))
      assert fold_row.row_id == Row.stable_decoration_id(:fold_start, 0, fold.id)
      assert fold_gutter.display_type == :fold_start
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

    test "wrapped presentation payload keeps document visual offset separate from payload overscan" do
      state =
        gui_state(rows: 3, cols: 20, content: "abcdefghijABCDEFGHIJklmnopqrstKLMNOPQRST\ntail")

      buffer = state.workspace.buffers.active
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
      assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)
      :ok = BufferProcess.move_to(buffer, {0, 16})

      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)
      viewport = Viewport.put_top_visual(window.viewport, 0, 1, 3)
      window = EditorWindow.set_viewport(window, viewport)

      windows =
        Windows.set_map(
          state.workspace.windows,
          Map.put(state.workspace.windows.map, win_id, window)
        )

      state = %{state | workspace: %{state.workspace | windows: windows}}

      {[wf], _cursor, _state} = build_content(state)
      model = wf.window_model
      presentation = ScrollPresentation.from_window(model)

      assert Enum.map(model.rows, & &1.text) == ["EFGHIJklmnopqr", "stKLMNOPQRST", "tail"]
      assert Enum.map(model.rows, & &1.visual_index) == [1, 2, 0]
      assert model.geometry.viewport.visual_row_offset == 1
      assert presentation.anchor_visual_row_offset == 1
      assert presentation.visible_start_line == 0
      assert presentation.overscan_start_line == 0
      assert presentation.visible_end_line == 2
      assert presentation.overscan_end_line == 2
    end

    test "cursor line reveals conceals while other model rows stay concealed" do
      state = gui_state(content: "**bold**\n**italic**")
      buffer = state.workspace.buffers.active

      BufferProcess.batch_decorations(buffer, fn decs ->
        decs
        |> add_conceal({0, 0}, {0, 2})
        |> add_conceal({0, 6}, {0, 8})
        |> add_conceal({1, 0}, {1, 2})
        |> add_conceal({1, 8}, {1, 10})
      end)

      :ok = BufferProcess.move_to(buffer, {0, 0})
      {[wf], _cursor, _state} = build_content(state)

      assert Enum.map(wf.window_model.rows, & &1.text) |> Enum.take(2) == [
               "**bold**",
               "italic"
             ]
    end

    test "wrapped selection starts at the pane edge when visual row offset hides its start" do
      content = "\tabcdef界ghijABCDEFGHIJ"
      state = gui_state(rows: 3, cols: 18, content: content)
      buffer = state.workspace.buffers.active
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
      assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)
      assert {:ok, 4} = BufferProcess.set_option(buffer, :tab_width, 4)
      :ok = BufferProcess.move_to(buffer, {0, 16})

      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)
      viewport = Viewport.put_top_visual(window.viewport, 0, 1, 3)
      window = EditorWindow.set_viewport(window, viewport)

      windows =
        Windows.set_map(
          state.workspace.windows,
          Map.put(state.workspace.windows.map, win_id, window)
        )

      state = %{state | workspace: %{state.workspace | windows: windows}}

      model = build_window_model(state, visual_selection: {:char, {0, 0}, {0, 17}})

      assert hd(model.rows).row_type == :wrap_continuation
      assert model.selection.start_row == 0
      assert model.selection.start_col == 0
      assert model.selection.end_row >= 0
      assert model.selection.end_col > model.selection.start_col
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

    test "scrolled simple window keeps overscan rows and matching scroll presentation metadata" do
      state =
        gui_state(rows: 5, cols: 20, content: "def foo do\n  if x do\n    :ok\n  end\nend\n:tail")

      buffer = state.workspace.buffers.active
      :ok = BufferProcess.move_to(buffer, {2, 4})

      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)
      window = EditorWindow.set_viewport(window, Viewport.put_top(window.viewport, 1))

      windows =
        Windows.set_map(
          state.workspace.windows,
          Map.put(state.workspace.windows.map, win_id, window)
        )

      state = %{state | workspace: %{state.workspace | windows: windows}}

      {[wf], _cursor, _state} = build_content(state)
      model = wf.window_model
      presentation = ScrollPresentation.from_window(model)

      assert Enum.map(model.rows, & &1.text) == [
               "def foo do",
               "  if x do",
               "    :ok",
               "  end",
               "end",
               ":tail"
             ]

      assert model.indent_guides.line_indent_levels == [1, 2, 1, 0]
      assert presentation != nil
      assert presentation.window_id == model.window_id
      assert presentation.visible_start_line == 1
      assert presentation.visible_end_line == 5
      assert presentation.overscan_start_line == 0
      assert presentation.overscan_end_line == 6
      assert presentation.content_epoch == model.content_epoch
      assert presentation.reset_required == model.full_refresh
      assert is_integer(presentation.layout_generation)
    end

    test "contiguous line_range arithmetic matches the fold result for sequential rows" do
      # ScrollPresentation derives the resident line range by arithmetic when the
      # window's rows are contiguous non-wrapped buffer lines. It must produce the
      # same range as folding over every row (the wrap/fold path).
      state = gui_state(rows: 8, cols: 40, content: long_content(40))
      {[wf], _cursor, _state} = build_content(state)
      model = wf.window_model

      assert model.contiguous_rows

      arithmetic = ScrollPresentation.from_window(model)
      folded = ScrollPresentation.from_window(%{model | contiguous_rows: false})

      assert arithmetic.overscan_start_line == folded.overscan_start_line
      assert arithmetic.overscan_end_line == folded.overscan_end_line
    end

    test "includes gutter and indent guide models built from current-frame data" do
      state = gui_state(content: "def a do\n  :ok\nend")
      {[wf], _cursor, _state} = build_content(state)

      assert wf.window_model.gutter.window_id == state.workspace.windows.active
      assert wf.window_model.gutter.entries != []
      assert wf.window_model.indent_guides.window_id == state.workspace.windows.active
    end
  end
end
