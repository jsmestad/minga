defmodule MingaEditor.RenderModel.Window.BuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Session.State, as: SessionState
  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Decorations
  alias Minga.Core.Unicode
  alias Minga.Core.Face
  alias Minga.Editing.Fold.Range, as: FoldRange
  alias Minga.Editing.Search.Match
  alias Minga.Language.Highlight.Span, as: HighlightSpan
  alias MingaEditor.Layout
  alias MingaEditor.RenderModel.Window.Builder
  alias MingaEditor.RenderModel.Window.BuildResult
  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.RenderPipeline.BufferPrefetch
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.Renderer.Context
  alias MingaEditor.Renderer.WindowCache
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window, as: EditorWindow
  alias MingaEditor.WindowTree
  alias MingaEditor.UI.Highlight
  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.RowSlotAllocator
  alias Minga.RenderModel.Window.ScrollPresentation

  import MingaEditor.RenderPipeline.TestHelpers

  # Runs the Content stage and reshapes each WindowContent carrier into a map
  # exposing the primary window model, any additional models, and the cursor,
  # so these builder tests can assert against the window model directly.
  defp build_content(%EditorState{} = state) do
    state = MingaEditor.WindowFocus.remember_active_cursor(state)
    state = MingaEditor.RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, input} = run_scroll_stage(state, layout)
    finish_content(input, scrolls)
  end

  defp build_content(%Input{} = input) do
    input = prepare_renderer_windows(input)
    input = MingaEditor.RenderPipeline.compute_layout(input)
    layout = Layout.get(input)
    {scrolls, input} = scroll_input(input, layout)
    finish_content(input, scrolls)
  end

  defp finish_content(input, scrolls) do
    {contents, cursor, input} = Content.build_content(input, scrolls)
    {Enum.map(contents, &to_window_view/1), cursor, input}
  end

  defp scroll_input(input, layout) do
    {prefetched, input} = BufferPrefetch.prefetch_scrolls(input, layout)
    Scroll.scroll_windows(input, layout, prefetched)
  end

  defp prepare_renderer_windows(%Input{} = input) do
    buffer = input.workspace.buffers.active

    if is_pid(buffer) do
      consumed = Buffer.renderer_consume(buffer)

      map =
        Map.new(input.windows.map, fn entry ->
          update_renderer_window(entry, buffer, consumed)
        end)

      windows = %{input.windows | map: map}
      %{input | windows: windows}
    else
      input
    end
  end

  defp update_renderer_window(
         {id, %{content: {:buffer, buffer}} = window},
         buffer,
         consumed
       ) do
    cache = update_renderer_cache(window.render_cache, buffer, consumed)
    {id, %{window | render_cache: cache}}
  end

  defp update_renderer_window(entry, _buffer, _consumed), do: entry

  defp update_renderer_cache(existing, buffer, consumed) do
    cache = renderer_cache(existing)

    case consumed.changes do
      {:ok, deltas} -> WindowCache.apply_edit_deltas(cache, buffer, deltas, consumed.snapshot)
      :reset_required -> WindowCache.mark_identity_reset(cache)
    end
    |> WindowCache.with_fetch_version(consumed.version)
  end

  defp renderer_cache(%WindowCache{} = cache), do: cache
  defp renderer_cache(_editor_cache), do: WindowCache.reset()

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

  # Detaches the active window's viewport from the cursor at `top` (as a wheel
  # free-scroll does): sets the scrolled top and marks `scroll_detach_cursor` to
  # the current cursor so the pipeline leaves the viewport where the user put it.
  defp detach_scroll(state, top) do
    win_id = state.workspace.windows.active
    window = Map.fetch!(state.workspace.windows.map, win_id)
    cursor = BufferProcess.cursor(state.workspace.buffers.active)

    window =
      window
      |> EditorWindow.set_viewport(Viewport.put_top(window.viewport, top))
      |> Map.put(:scroll_detach_cursor, cursor)

    windows =
      Windows.set_map(
        state.workspace.windows,
        Map.put(state.workspace.windows.map, win_id, window)
      )

    %{state | workspace: %{state.workspace | windows: windows}}
  end

  defp build_window_model(%EditorState{} = state, ctx_overrides) do
    state = MingaEditor.WindowFocus.remember_active_cursor(state)
    state = MingaEditor.RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, input} = run_scroll_stage(state, layout)
    finish_window_model(input, scrolls, ctx_overrides)
  end

  defp build_window_model(%Input{} = input, ctx_overrides) do
    input = prepare_renderer_windows(input)
    input = MingaEditor.RenderPipeline.compute_layout(input)
    layout = Layout.get(input)
    {scrolls, input} = scroll_input(input, layout)
    finish_window_model(input, scrolls, ctx_overrides)
  end

  defp finish_window_model(input, scrolls, ctx_overrides) do
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

    Builder.build(input, scroll, ctx)
  end

  defp build_window_with_stats(%EditorState{} = state, ctx_overrides, opts) do
    state = MingaEditor.WindowFocus.remember_active_cursor(state)
    state = MingaEditor.RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, input} = run_scroll_stage(state, layout)
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

    Builder.build_with_stats(input, scroll, ctx, opts)
  end

  describe "GUI content stage" do
    test "builds a canonical window model" do
      state = gui_state(content: "hello\nworld")
      {[wf], _cursor, _state} = build_content(state)

      assert %Window{} = wf.window_model
      assert wf.window_model.content_kind == :buffer
      assert Enum.map(wf.window_model.rows, & &1.text) == ["hello", "world"]
    end

    test "preserves surviving row identities across top insertion and deletion" do
      state = gui_state(content: "duplicate\nduplicate\ntail")
      {[_arming], _cursor, state} = build_content(state)
      {[first], _cursor, state} = build_content(state)

      original =
        Map.new(first.window_model.rows, &{&1.text <> Integer.to_string(&1.buf_line), &1.row_id})

      buffer = state.workspace.buffers.active

      :ok = BufferProcess.insert_text(buffer, "new\n")
      {[inserted], _cursor, state} = build_content(state)
      [new_row | _changed_rows] = inserted.window_model.rows
      assert new_row.text == "new"

      inserted_ids = resident_row_ids(state)

      assert Enum.slice(inserted_ids, 1, 3) == [
               original["duplicate0"],
               original["duplicate1"],
               original["tail2"]
             ]

      :ok = BufferProcess.delete_lines(buffer, 0, 0)
      {[_restored], _cursor, state} = build_content(state)

      assert resident_row_ids(state) == [
               original["duplicate0"],
               original["duplicate1"],
               original["tail2"]
             ]
    end

    test "includes pane geometry and content epoch for GUI windows" do
      state = gui_state(content: "hello\nworld")
      {[wf], _cursor, _state} = build_content(state)
      model = wf.window_model

      assert model.geometry.window_id == state.workspace.windows.active
      assert model.geometry.total_rect == {0, 0, 80, 24}
      assert model.geometry.content_rect == {0, 0, 80, 24}
      assert model.geometry.gutter_rect == {0, 0, 6, 24}
      assert model.geometry.text_rect == {0, 6, 74, 24}
      assert model.geometry.viewport.rows == 24
      assert model.geometry.gutter_metrics.line_number_width == 3
      assert model.geometry.gutter_metrics.sign_col_width == 3

      assert Enum.find(model.geometry.hit_regions, &(&1.kind == :fold_control)).rect ==
               {0, 2, 1, 24}

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

      assert Enum.any?(divider_regions, &(&1.rect == {0, 39, 1, 24}))
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

    # VSCode-style wheel free-scroll (#2684) can leave the cursor off-viewport
    # without moving it. When that happens the caret and cursorline must
    # disappear rather than ghost at the edge row; they return on scroll-back.
    # A window whose `scroll_detach_cursor` matches the (unmoved) cursor keeps
    # its scrolled top through the pipeline, reproducing the detached state.
    test "omits the caret and cursorline when the cursor is scrolled above the viewport" do
      content = Enum.map_join(0..49, "\n", &"line #{&1}")
      state = gui_state(rows: 5, cols: 20, content: content)
      :ok = BufferProcess.move_to(state.workspace.buffers.active, {0, 0})

      model = build_window_model(detach_scroll(state, 30), cursorline_bg: 0x223344)

      assert model.cursor_visible == false
      assert model.cursorline == nil
    end

    test "omits the caret and cursorline when the cursor is scrolled below the viewport" do
      content = Enum.map_join(0..49, "\n", &"line #{&1}")
      state = gui_state(rows: 5, cols: 20, content: content)
      # Cursor on the last line; scroll the viewport back to the top so the
      # cursor sits past the bottom bound. Guards the upper bound strictly:
      # a `<` -> `<=` regression in cursor_on_screen? would fail here.
      :ok = BufferProcess.move_to(state.workspace.buffers.active, {49, 0})

      model = build_window_model(detach_scroll(state, 0), cursorline_bg: 0x223344)

      assert model.cursor_visible == false
      assert model.cursorline == nil
    end

    test "bottom bound is strict: last visible row shows the caret, one past hides it" do
      content = Enum.map_join(0..49, "\n", &"line #{&1}")
      # Probe the visible-row boundary instead of hardcoding chrome height:
      # walk the cursor down from the top until visibility flips, then assert
      # the flip is exactly one row wide. A `<` -> `<=` regression in
      # cursor_on_screen? moves the flip and fails the paired assertions.
      state = gui_state(rows: 8, cols: 20, content: content)
      buffer = state.workspace.buffers.active

      visible_at? = fn line ->
        :ok = BufferProcess.move_to(buffer, {line, 0})
        build_window_model(detach_scroll(state, 0), cursorline_bg: 0x223344).cursor_visible
      end

      first_hidden = Enum.find(1..49, fn line -> not visible_at?.(line) end)

      assert is_integer(first_hidden),
             "expected the cursor to leave the viewport within the buffer"

      last_visible = first_hidden - 1
      :ok = BufferProcess.move_to(buffer, {last_visible, 0})
      model = build_window_model(detach_scroll(state, 0), cursorline_bg: 0x223344)
      assert model.cursor_visible == true
      assert %Window.Cursorline{row: ^last_visible} = model.cursorline
    end

    test "restores the caret and cursorline when scrolled back onto the cursor" do
      content = Enum.map_join(0..49, "\n", &"line #{&1}")
      state = gui_state(rows: 5, cols: 20, content: content)
      :ok = BufferProcess.move_to(state.workspace.buffers.active, {0, 0})

      off = build_window_model(detach_scroll(state, 30), cursorline_bg: 0x223344)
      assert off.cursorline == nil

      back = build_window_model(detach_scroll(state, 0), cursorline_bg: 0x223344)
      assert back.cursor_visible == true
      assert %Window.Cursorline{row: 0, bg_rgb: 0x223344} = back.cursorline
    end

    test "wrapped buffer hides cursor when scrolled off-viewport" do
      content = Enum.map_join(0..49, "\n", &"line #{&1} with enough text to wrap")
      state = gui_state(rows: 5, cols: 20, content: content)
      buffer = state.workspace.buffers.active
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
      assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)
      :ok = BufferProcess.move_to(buffer, {0, 0})

      model = build_window_model(detach_scroll(state, 30), cursorline_bg: 0x223344)

      assert model.cursor_visible == false
      assert model.cursorline == nil
    end

    test "wrapped buffer restores cursor when scrolled back into view" do
      content = Enum.map_join(0..49, "\n", &"line #{&1} with enough text to wrap")
      state = gui_state(rows: 5, cols: 20, content: content)
      buffer = state.workspace.buffers.active
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
      assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)
      :ok = BufferProcess.move_to(buffer, {0, 0})

      off = build_window_model(detach_scroll(state, 30), cursorline_bg: 0x223344)
      assert off.cursor_visible == false

      back = build_window_model(detach_scroll(state, 0), cursorline_bg: 0x223344)
      assert back.cursor_visible == true
      assert %Window.Cursorline{bg_rgb: 0x223344} = back.cursorline
    end

    test "folded buffer hides cursor when scrolled off-viewport" do
      content = Enum.map_join(0..49, "\n", &"line #{&1}")
      state = gui_state(rows: 5, cols: 20, content: content)
      buffer = state.workspace.buffers.active
      :ok = BufferProcess.move_to(buffer, {0, 0})

      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)
      window = EditorWindow.set_fold_ranges(window, [FoldRange.new!(5, 20)])
      window = EditorWindow.fold_at(window, 5)

      state =
        %{
          state
          | workspace:
              SessionState.set_windows(state.workspace, %{
                state.workspace.windows
                | map: Map.put(state.workspace.windows.map, win_id, window)
              })
        }

      model = build_window_model(detach_scroll(state, 25), cursorline_bg: 0x223344)

      assert model.cursor_visible == false
      assert model.cursorline == nil
    end

    test "folded buffer restores cursor when scrolled back into view" do
      content = Enum.map_join(0..49, "\n", &"line #{&1}")
      state = gui_state(rows: 5, cols: 20, content: content)
      buffer = state.workspace.buffers.active
      :ok = BufferProcess.move_to(buffer, {0, 0})

      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)
      window = EditorWindow.set_fold_ranges(window, [FoldRange.new!(5, 20)])
      window = EditorWindow.fold_at(window, 5)

      state =
        %{
          state
          | workspace:
              SessionState.set_windows(state.workspace, %{
                state.workspace.windows
                | map: Map.put(state.workspace.windows.map, win_id, window)
              })
        }

      off = build_window_model(detach_scroll(state, 25), cursorline_bg: 0x223344)
      assert off.cursor_visible == false

      back = build_window_model(detach_scroll(state, 0), cursorline_bg: 0x223344)
      assert back.cursor_visible == true
      assert %Window.Cursorline{row: 0, bg_rgb: 0x223344} = back.cursorline
    end

    test "ordinary buffer edits change row hashes without bumping content epoch or forcing refresh" do
      state = gui_state(content: "hello")
      # First-paint-then-promote (#2679): frame 1 renders windowed (arming), frame 2
      # promotes to residence with a full refresh. Settle both before measuring
      # edit-epoch stability so the edit frame is the only variable.
      {[_wf], _cursor, state} = build_content(state)
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

    test "resize invalidates layout while preserving content epoch and row identity" do
      state = gui_state(content: "hello")
      {[wf], _cursor, state} = build_content(state)
      epoch = wf.window_model.content_epoch
      row_id = hd(wf.window_model.rows).row_id

      resized = %{
        state
        | intent: %{
            state.intent
            | frame: %{state.intent.frame | terminal_viewport: Viewport.new(24, 100)}
          }
      }

      {[wf], _cursor, _state} = build_content(resized)

      assert wf.window_model.content_epoch == epoch
      assert hd(wf.window_model.rows).row_id == row_id
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

    test "wrapped build stats retain typed VisualRows and replay them on reuse" do
      state = gui_state(cols: 20, content: "abcdefghijABCDEFGHIJ")
      buffer = state.workspace.buffers.active
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
      assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)

      {first_model, %BuildResult{} = first_result} = build_window_with_stats(state, [], [])

      assert %BuildResult{
               rasterized: 2,
               retained_rows: retained_rows,
               retained_wrap_lines: retained_wrap_lines,
               resident_build: nil,
               resident_rows_spliced: 0,
               row_slot_allocator: %RowSlotAllocator{}
             } = first_result

      assert map_size(retained_rows) == 2
      assert [{wrap_hash, entries}] = Map.values(retained_wrap_lines)
      assert [%VisualRow{} = first_entry, %VisualRow{} = second_entry] = entries
      assert Enum.map(entries, & &1.row) == first_model.rows

      assert first_entry.buf_line == 0
      assert first_entry.visual_index == 0
      assert first_entry.display_row == 0
      assert first_entry.source_start_byte == 0
      assert first_entry.source_start_col == 0
      assert first_entry.source_end_byte >= first_entry.source_start_byte
      assert first_entry.source_end_col >= first_entry.source_start_col
      assert first_entry.row_width == Unicode.display_width(first_entry.row.text)
      assert first_entry.input_hash == wrap_hash
      assert first_entry.wrap_line_hash == wrap_hash
      assert first_entry.reused? == false
      assert second_entry.display_row == 0

      {second_model, %BuildResult{} = second_result} =
        build_window_with_stats(state, [],
          retained_rows: first_result.retained_rows,
          retained_wrap_lines: first_result.retained_wrap_lines,
          row_slot_allocator: first_result.row_slot_allocator
        )

      assert Enum.map(second_model.rows, & &1.row_id) == Enum.map(first_model.rows, & &1.row_id)

      assert Enum.map(second_model.rows, & &1.content_hash) ==
               Enum.map(first_model.rows, & &1.content_hash)

      assert [{^wrap_hash, reused_entries}] = Map.values(second_result.retained_wrap_lines)
      assert Enum.all?(reused_entries, &match?(%VisualRow{reused?: true}, &1))
      assert Enum.map(reused_entries, & &1.row) == second_model.rows
    end

    test "wrapped row IDs follow their durable source when a line is inserted above" do
      state = gui_state(cols: 20, content: "top\nabcdefghijABCDEFGHIJ")
      buffer = state.workspace.buffers.active
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
      assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)

      {[before], _cursor, state} = build_content(state)

      wrapped_ids =
        before.window_model.rows
        |> Enum.filter(&(&1.buf_line == 1))
        |> Enum.map(& &1.row_id)

      :ok = BufferProcess.move_to(buffer, {0, 0})
      :ok = BufferProcess.insert_text(buffer, "new\n")
      {[after_insert], _cursor, _state} = build_content(state)

      assert after_insert.window_model.rows
             |> Enum.filter(&(&1.buf_line == 2))
             |> Enum.map(& &1.row_id) == wrapped_ids
    end

    test "virtual and block row IDs follow their durable source across structural edits" do
      state = gui_state(content: "top\nanchor\ntail")
      buffer = state.workspace.buffers.active

      _virtual_id =
        BufferProcess.add_virtual_text(buffer, {1, 0},
          segments: [{"virtual", Face.new()}],
          placement: :above
        )

      _block_id =
        BufferProcess.add_block_decoration(buffer, 1,
          placement: :below,
          render: fn _width -> [{"block", Face.new()}] end
        )

      {[before], _cursor, state} = build_content(state)

      decoration_ids =
        before.window_model.rows
        |> Enum.filter(&(&1.row_type in [:virtual_line, :block]))
        |> Enum.map(& &1.row_id)

      :ok = BufferProcess.move_to(buffer, {0, 0})
      :ok = BufferProcess.insert_text(buffer, "new\n")
      {[after_insert], _cursor, _state} = build_content(state)

      assert after_insert.window_model.rows
             |> Enum.filter(&(&1.row_type in [:virtual_line, :block]))
             |> Enum.map(& &1.row_id) == decoration_ids
    end

    test "row-slot exhaustion resets content epoch before rebuilding decoration identities" do
      state = gui_state(content: "line")
      buffer = state.workspace.buffers.active

      _id =
        BufferProcess.add_virtual_text(buffer, {0, 0},
          segments: [{"virtual", Face.new()}],
          placement: :above
        )

      {[warm], _cursor, input} = build_content(state)
      win_id = input.windows.active
      window = Map.fetch!(input.windows.map, win_id)

      exhausted = %RowSlotAllocator{
        slots: %{},
        next: %{{warm.window_model.content_epoch, 0, :virtual_line} => 0x1000_0000}
      }

      renderer_cache = WindowCache.put_row_slot_allocator(window.render_cache, exhausted)
      window = %{window | render_cache: renderer_cache}

      windows = %{
        input.windows
        | map: Map.put(input.windows.map, win_id, window)
      }

      input = %{input | windows: windows}

      {[wf], _cursor, _state} = build_content(input)

      assert wf.window_model.content_epoch > warm.window_model.content_epoch
      assert wf.window_model.full_refresh == true
      assert Enum.any?(wf.window_model.rows, &(&1.row_type == :virtual_line))
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

      _second_id =
        BufferProcess.add_virtual_text(buffer, {0, 0},
          segments: [{"second virtual", Face.new()}],
          placement: :above,
          priority: 1
        )

      {[wf], _cursor, state} = build_content(state)

      virtual_rows = Enum.filter(wf.window_model.rows, &(&1.row_type == :virtual_line))
      assert Enum.map(virtual_rows, & &1.text) == ["first virtual", "second virtual"]

      virtual_gutters = Enum.take(wf.window_model.gutter.entries, 2)
      assert Enum.map(virtual_gutters, & &1.display_type) == [:blank, :blank]
      assert Enum.map(virtual_gutters, & &1.sign_type) == [:none, :none]

      [first_row_id, second_row_id] = Enum.map(virtual_rows, & &1.row_id)
      refute first_row_id == second_row_id

      :ok = BufferProcess.remove_virtual_text(buffer, first_id)

      {[wf], _cursor, _state} = build_content(state)

      [remaining] = Enum.filter(wf.window_model.rows, &(&1.row_type == :virtual_line))
      assert remaining.text == "second virtual"
      assert remaining.row_id == second_row_id
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

      _second_id =
        BufferProcess.add_block_decoration(buffer, 0,
          placement: :above,
          render: fn _width -> [{"second block", Face.new()}] end,
          priority: 1
        )

      {[wf], _cursor, state} = build_content(state)

      block_rows = Enum.filter(wf.window_model.rows, &(&1.row_type == :block))
      assert Enum.map(block_rows, & &1.text) == ["first block", "second block"]

      block_gutters = Enum.take(wf.window_model.gutter.entries, 2)
      assert Enum.map(block_gutters, & &1.display_type) == [:blank, :blank]
      assert Enum.map(block_gutters, & &1.sign_type) == [:none, :none]

      [first_row_id, second_row_id] = Enum.map(block_rows, & &1.row_id)
      refute first_row_id == second_row_id

      :ok = BufferProcess.remove_block_decoration(buffer, first_id)

      {[wf], _cursor, _state} = build_content(state)

      [remaining] = Enum.filter(wf.window_model.rows, &(&1.row_type == :block))
      assert remaining.text == "second block"
      assert remaining.row_id == second_row_id
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
      assert fold_row.row_id == Row.stable_id(:fold_start, 0)
      assert fold_gutter.display_type == :fold_start
    end

    test "folded window rows preserve syntax highlight spans" do
      content = "def folded\n  :ok\nend\nclass Visible\nend"
      lines = String.split(content, "\n")
      state = gui_state(content: content)
      buffer = state.workspace.buffers.active

      highlight =
        state.appearance.theme
        |> Highlight.from_theme()
        |> Highlight.put_names(["keyword"])
        |> Highlight.put_spans(1, [
          highlight_span(lines, 0, 0, 3, 0),
          highlight_span(lines, 3, 0, 5, 0)
        ])

      state =
        %{
          state
          | parser:
              MingaEditor.State.Parser.accept_highlighting(state.parser, %Highlighting{
                highlights: %{buffer => highlight}
              })
        }

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

      {[wf], _cursor, _state} = build_content(state)

      [fold_row] = Enum.filter(wf.window_model.rows, &(&1.row_type == :fold_start))
      [fold_gutter] = Enum.filter(wf.window_model.gutter.entries, &(&1.buf_line == 0))
      assert fold_row.row_id == Row.stable_id(:decoration_fold, 0, 0)
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
      # rows: 2 yields a 2-row content area. Before #2693 this needed rows: 3
      # because the GUI layout stole one row for a phantom minibuffer reservation;
      # now the editor fills the full viewport, so 2 reported rows == 2 content rows.
      state = gui_state(rows: 2, cols: 18, content: content)
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

      assert model.indent_guides.line_indent_levels == [0, 1, 2, 1, 0]
      assert presentation != nil
      assert presentation.window_id == model.window_id
      # With the minibuffer no longer stealing a row, the 5-row viewport now fits
      # one more line, so the EOF clamp pulls the top back to line 0 and the whole
      # 6-line file is visible (#2693 interaction: EOF clamp sees the taller area).
      assert presentation.visible_start_line == 0
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

  defp resident_row_ids(%Input{windows: windows}) do
    window = MingaEditor.State.Windows.active_struct(windows)

    window.render_cache.resident_build.store
    |> ResidentStore.entries()
    |> Enum.map(& &1.id)
  end
end
