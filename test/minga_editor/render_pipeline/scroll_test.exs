defmodule MingaEditor.RenderPipeline.ScrollTest do
  @moduledoc """
  Tests for the Scroll stage of the render pipeline.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Session.State, as: SessionState
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Fold.Range, as: FoldRange
  alias Minga.Core.WrapMap
  alias Minga.Mode.CommandState
  alias Minga.Project.FileRef
  alias MingaEditor.Layout
  alias MingaEditor.Mouse
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.BufferPrefetch
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.InlineAsk
  alias MingaEditor.Viewport
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers

  # Helper to run through layout and scroll
  defp run_through_scroll(%EditorState{} = state) do
    state = MingaEditor.WindowFocus.remember_active_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, input} = run_scroll_stage(state, layout)
    {scrolls, input, layout}
  end

  defp run_through_scroll(%Input{} = input) do
    layout = Layout.get(input)
    {scrolls, input} = scroll_input(input, layout)
    {scrolls, input, layout}
  end

  defp scroll_input(input, layout) do
    {prefetched, input} = BufferPrefetch.prefetch_scrolls(input, layout)
    Scroll.scroll_windows(input, layout, prefetched)
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

  defp prepared_wrapped_wheel_state do
    state = gui_state(rows: 8, cols: 18, content: String.duplicate("x", 320))
    buffer = state.workspace.buffers.active
    assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
    assert {:ok, :absolute} = BufferProcess.set_option(buffer, :line_numbers, :absolute)
    state = RenderPipeline.compute_layout(state)
    Mouse.handle_scroll_batch(state, state.workspace.windows.active, 100, :down)
  end

  describe "scroll_windows/3" do
    test "returns {scrolls, state} for each window" do
      state = base_state()
      {scrolls, state, _layout} = run_through_scroll(state)

      assert map_size(scrolls) == 1
      [{_win_id, scroll}] = Map.to_list(scrolls)
      assert %WindowScroll{} = scroll
      assert %Input{} = state
    end

    test "scroll result contains buffer lines" do
      state = base_state(content: "alpha\nbeta\ngamma")
      {scrolls, _state, _layout} = run_through_scroll(state)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      assert "alpha" in scroll.lines
      assert "beta" in scroll.lines
      assert "gamma" in scroll.lines
    end

    test "wrapped pane measures its resident extent after the first windowed paint" do
      content = Enum.map_join(1..10, "\n", fn _idx -> "abcdefghijklmnopqrstuv" end)
      state = gui_state(rows: 4, cols: 20, content: content)
      buffer = state.workspace.buffers.active
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
      assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)

      {first, state, _layout} = run_through_scroll(state)
      refute first[state.windows.active].full_residence
      {second, state, _layout} = run_through_scroll(state)
      assert %{full_residence: true, total_visual_rows: 20} = second[state.windows.active]
    end

    test "windowed wrapping revalidates a detached continuation after the gutter width changes" do
      state = prepared_wrapped_wheel_state()
      id = state.workspace.windows.active
      buffer = state.workspace.buffers.active
      {before, _input, _layout} = run_through_scroll(state)
      assert %{full_residence: false, viewport: %{top: 0, visual_row_offset: narrow}} = before[id]

      assert {:ok, :none} = BufferProcess.set_option(buffer, :line_numbers, :none)
      {after_resize, _input, _layout} = run_through_scroll(state)
      assert %{viewport: %{top: 0, visual_row_offset: wide}} = after_resize[id]
      assert wide < narrow
      assert BufferProcess.cursor(buffer) == {0, 0}
    end

    test "windowed display does not skip rows when wrap is disabled while detached" do
      state = prepared_wrapped_wheel_state()
      id = state.workspace.windows.active
      buffer = state.workspace.buffers.active
      assert %{visual_row_offset: continuation} = state.workspace.windows.map[id].viewport
      assert continuation > 0

      assert {:ok, false} = BufferProcess.set_option(buffer, :wrap, false)
      {scrolls, _input, _layout} = run_through_scroll(state)
      assert %{wrap_on: false, viewport: %{top: 0, visual_row_offset: 0}} = scrolls[id]
    end

    test "wheel bounds include the extra wraps in an active substitute preview" do
      editor = gui_state(rows: 8, cols: 26, content: "start TAIL")
      buffer = editor.workspace.buffers.active
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
      replacement = String.duplicate("x", 320)
      command = CommandState.new("%s/start/#{replacement}/")
      workspace = SessionState.transition_mode(editor.workspace, :command, command)
      editor = RenderPipeline.compute_layout(%{editor | workspace: workspace})
      id = editor.workspace.windows.active
      editor = Mouse.handle_scroll_batch(editor, id, 100, :down)
      assert %{top: 0, visual_row_offset: offset} = editor.workspace.windows.map[id].viewport
      assert offset > 0

      {scrolls, _input, _layout} = run_through_scroll(editor)
      assert %{full_residence: false, viewport: %{visual_row_offset: ^offset}} = scrolls[id]
      assert ["#{replacement} TAIL"] == scrolls[id].lines
    end

    test "Inline Ask preserves a detached continuation and participates in wheel bounds" do
      editor = prepared_wrapped_wheel_state()
      buffer = editor.workspace.buffers.active
      id = editor.workspace.windows.active
      assert {0, old_bottom} = Viewport.vertical_anchor(editor.workspace.windows.map[id].viewport)
      assert old_bottom > 0

      file = %FileRef{kind: :buffer, display_name: "scratch", buffer_pid: buffer}
      ask = InlineAsk.new(buffer, file, "scratch", 0, nil, "context")
      shell = TraditionalState.activate_inline_ask(%TraditionalState{}, ask)
      runtime = Runtime.new(Runtime.default_entry(), shell)
      editor = %{editor | shell_runtime: runtime}

      next = old_bottom + 1
      editor = Mouse.handle_scroll_batch(editor, id, 1, :down)
      assert {0, ^next} = Viewport.vertical_anchor(editor.workspace.windows.map[id].viewport)

      {scrolls, input, _layout} = run_through_scroll(editor)
      assert %{wrap_on: true, full_residence: false, viewport: viewport} = scrolls[id]
      assert Viewport.vertical_anchor(viewport) == {0, next}
      {[%{models: [model]}], nil, _input} = Content.build_content(input, scrolls)
      assert [%{row_type: :wrap_continuation, visual_index: ^next} | _] = model.rows
      assert Enum.at(model.rows, Viewport.content_rows(viewport) - 1).row_type == :block

      at_bottom = Mouse.handle_scroll_batch(editor, id, 100, :down)
      {0, bottom} = Viewport.vertical_anchor(at_bottom.workspace.windows.map[id].viewport)
      assert bottom > next
      assert at_bottom.workspace.windows.map[id].pinned

      reversed = Mouse.handle_scroll_batch(at_bottom, id, -1, :up)
      {scrolls, input, _layout} = run_through_scroll(reversed)
      {[%{models: [model]}], nil, _input} = Content.build_content(input, scrolls)
      assert Viewport.vertical_anchor(scrolls[id].viewport) == {0, bottom - 1}
      assert hd(model.rows).visual_index == bottom - 1
      refute reversed.workspace.windows.map[id].pinned
      assert BufferProcess.cursor(buffer) == {0, 0}
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

    test "full-document residence is on by default for a nowrap buffer under the ceiling (#2679)" do
      # Residence now ships on (resident_store_max_lines default 65_536), so a
      # nowrap buffer under the ceiling becomes fully resident regardless of scroll
      # position. This test relies on the default rather than mutating global config,
      # so it stays async-safe.
      state = base_state(rows: 10, cols: 40, content: long_content(500))
      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)
      window = Window.set_viewport(window, Viewport.put_top(window.viewport, 250))

      state = %{
        state
        | workspace:
            SessionState.set_windows(state.workspace, %{
              state.workspace.windows
              | map: Map.put(state.workspace.windows.map, win_id, window)
            })
      }

      # First-paint-then-promote (#2679): the first frame renders windowed (arming
      # promotion), the second promotes to full residence.
      {_scrolls, state, _layout} = run_through_scroll(state)
      {scrolls, _state, _layout} = run_through_scroll(state)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      assert scroll.full_residence == true
      assert Enum.count(scroll.lines) == 500
    end

    test "wheel and paint keep wrapping the current line with a closed fold far offscreen" do
      state =
        gui_state(
          rows: 8,
          cols: 18,
          content: String.duplicate("a", 120) <> "\n" <> long_content(40)
        )

      buffer = state.workspace.buffers.active
      assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)

      id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, id)
      window = Window.set_fold_ranges(window, [FoldRange.new!(30, 35)])
      window = Window.fold_at(window, 30)

      state = %{
        state
        | workspace:
            SessionState.set_windows(state.workspace, %{
              state.workspace.windows
              | map: Map.put(state.workspace.windows.map, id, window)
            })
      }

      state = RenderPipeline.compute_layout(state)
      state = Mouse.handle_scroll_batch(state, id, 1, :down)
      assert {0, 1} = Viewport.vertical_anchor(state.workspace.windows.map[id].viewport)

      {scrolls, input, _layout} = run_through_scroll(state)
      assert %{full_residence: false, viewport: viewport} = scrolls[id]
      assert Viewport.vertical_anchor(viewport) == {0, 1}
      {[%{models: [model]}], nil, _input} = Content.build_content(input, scrolls)

      assert [%{buf_line: 0, row_type: :wrap_continuation, visual_index: 1} | _] = model.rows
      assert BufferProcess.cursor(buffer) == {0, 0}
    end

    test "wrapped scroll keeps offset 0 when the wrapped file fits" do
      penultimate = "    " <> String.duplicate("alpha beta ", 4)
      last_line = "tail"
      state = base_state(content: penultimate <> "\n" <> last_line, rows: 10, cols: 24)
      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, true)
      _ = BufferProcess.set_option(buffer, :line_numbers, :none)
      _ = BufferProcess.set_option(buffer, :linebreak, false)
      _ = BufferProcess.set_option(buffer, :breakindent, true)

      content_width = wrapped_content_width(state, buffer)

      [penultimate_entry, last_entry] =
        WrapMap.compute([penultimate, last_line], content_width,
          breakindent: true,
          linebreak: false,
          tab_width: 2
        )

      assert WrapMap.visual_row_count([penultimate_entry, last_entry]) <=
               Viewport.content_rows(Viewport.new(10, 24, 0))

      BufferProcess.move_to(buffer, {0, Enum.at(penultimate_entry, -1).byte_offset})

      {scrolls, _state, _layout} = run_through_scroll(state)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      assert scroll.viewport.top == 0
      assert scroll.viewport.visual_row_offset == 0
    end

    test "wrapped render scroll preserves a non-zero offset away from eof" do
      head = "    " <> String.duplicate("alpha beta ", 2)
      tail = Enum.map_join(1..20, "\n", &"tail #{&1} with enough text to stay long")
      state = base_state(content: head <> "\n" <> tail, rows: 10, cols: 24)
      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, true)
      _ = BufferProcess.set_option(buffer, :line_numbers, :none)
      _ = BufferProcess.set_option(buffer, :linebreak, false)
      _ = BufferProcess.set_option(buffer, :breakindent, true)

      content_width = wrapped_content_width(state, buffer)

      [head_entry | _] =
        WrapMap.compute([head], content_width,
          breakindent: true,
          linebreak: false,
          tab_width: 2
        )

      visible_rows = Viewport.content_rows(Viewport.new(10, 24, 0))
      assert Enum.count(head_entry) < visible_rows
      assert Enum.count(head_entry) > 1

      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)
      viewport = Viewport.put_top_visual(window.viewport, 0, 1, Enum.count(head_entry))
      window = Window.set_viewport(window, viewport)

      state = %{
        state
        | workspace:
            SessionState.set_windows(state.workspace, %{
              state.workspace.windows
              | map: Map.put(state.workspace.windows.map, win_id, window)
            })
      }

      BufferProcess.move_to(buffer, {0, Enum.at(head_entry, -1).byte_offset})

      {scrolls, _state, _layout} = run_through_scroll(state)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      assert scroll.first_line == 0
      assert scroll.viewport.top == 0
      assert scroll.viewport.visual_row_offset == 1
    end

    test "wrapped scroll uses rows remaining to eof for penultimate wrapped lines" do
      penultimate = "    " <> String.duplicate("alpha beta ", 4)
      last_line = String.duplicate("omega psi ", 12)
      # Layout.GUI reserves only the minibuffer row, so a smaller viewport
      # reproduces the overflow the TUI layout produced with its taller chrome.
      state = base_state(content: penultimate <> "\n" <> last_line, rows: 3, cols: 24)
      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, true)
      _ = BufferProcess.set_option(buffer, :line_numbers, :none)
      _ = BufferProcess.set_option(buffer, :linebreak, false)
      _ = BufferProcess.set_option(buffer, :breakindent, true)

      content_width = wrapped_content_width(state, buffer)

      [penultimate_entry, last_entry] =
        WrapMap.compute([penultimate, last_line], content_width,
          breakindent: true,
          linebreak: false,
          tab_width: 2
        )

      assert WrapMap.visual_row_count([penultimate_entry, last_entry]) >
               Viewport.content_rows(Viewport.new(3, 24, 0))

      BufferProcess.move_to(buffer, {0, Enum.at(penultimate_entry, -1).byte_offset})

      {scrolls, _state, _layout} = run_through_scroll(state)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      assert scroll.viewport.top == 0
      assert scroll.viewport.visual_row_offset == 1
    end

    test "non-wrap cursor-follow clamps to EOF instead of overscrolling" do
      content = Enum.map_join(1..20, "\n", &"line #{&1}")
      state = base_state(content: content, rows: 10, cols: 80)
      buffer = state.workspace.buffers.active

      _ = BufferProcess.set_option(buffer, :wrap, false)
      _ = BufferProcess.set_option(buffer, :line_numbers, :none)

      BufferProcess.move_to(buffer, {19, 0})

      {scrolls, _state, _layout} = run_through_scroll(state)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      visible = Viewport.content_rows(scroll.viewport)
      assert scroll.viewport.top <= 20 - visible
    end

    test "scroll result uses snapshot version" do
      state = base_state()
      {scrolls, _state, _layout} = run_through_scroll(state)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      assert is_integer(scroll.snapshot.version)
      assert scroll.snapshot.version >= 0
    end

    test "first frame marks the window fully dirty" do
      state = base_state()
      {_scrolls, state, _layout} = run_through_scroll(state)
      [{_win_id, window}] = Map.to_list(state.windows.map)

      assert window.render_cache.fully_dirty?
    end

    test "resets horizontal scroll when cursor fits on screen" do
      state = base_state(content: "short line\nanother short line")

      # Inject a stale left offset into the window's viewport
      win_id = state.workspace.windows.active
      window = Map.get(state.workspace.windows.map, win_id)
      scrolled_vp = %{window.viewport | left: 40}
      updated_window = %{window | viewport: scrolled_vp}
      new_map = Map.put(state.workspace.windows.map, win_id, updated_window)

      state = %{
        state
        | workspace:
            SessionState.set_windows(state.workspace, %{state.workspace.windows | map: new_map})
      }

      {scrolls, _state, _layout} = run_through_scroll(state)
      [{_win_id, scroll}] = Map.to_list(scrolls)

      assert scroll.viewport.left == 0
    end
  end
end
