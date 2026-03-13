defmodule Minga.Editor.RenderPipelineTest do
  @moduledoc """
  Per-stage tests for the render pipeline.

  Each stage is tested independently with constructed inputs, verifying
  it can be called without running the full pipeline.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Frame, WindowFrame}
  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline
  alias Minga.Editor.RenderPipeline.{Chrome, WindowScroll}
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.{Buffers, Highlighting, Windows}
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Input
  alias Minga.Theme

  # ── Test helpers ───────────────────────────────────────────────────────────

  defp base_state(opts \\ []) do
    rows = Keyword.get(opts, :rows, 24)
    cols = Keyword.get(opts, :cols, 80)
    content = Keyword.get(opts, :content, "line one\nline two\nline three")
    {:ok, buf} = BufferServer.start_link(content: content)

    win_id = 1
    window = Window.new(win_id, buf, rows, cols)

    %EditorState{
      port_manager: self(),
      viewport: Viewport.new(rows, cols),
      vim: VimState.new(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(win_id),
        map: %{win_id => window},
        active: win_id,
        next_id: win_id + 1
      },
      focus_stack: Input.default_stack(),
      theme: Theme.get!(:doom_one),
      highlight: %Highlighting{}
    }
  end

  # Helper to run through scroll and get {scrolls, state}
  defp run_through_scroll(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = RenderPipeline.scroll_windows(state, layout)
    {scrolls, state, layout}
  end

  # ── Stage 1: Invalidation ─────────────────────────────────────────────────

  describe "invalidate/1" do
    test "returns state (pass-through for now)" do
      state = base_state()
      result = RenderPipeline.invalidate(state)
      assert %EditorState{} = result
    end
  end

  # ── Stage 2: Layout ────────────────────────────────────────────────────────

  describe "compute_layout/1" do
    test "returns state with cached layout" do
      state = base_state()
      state = EditorState.sync_active_window_cursor(state)
      new_state = RenderPipeline.compute_layout(state)
      layout = Layout.get(new_state)
      assert %Layout{} = layout
    end

    test "layout contains minibuffer and editor_area" do
      state = base_state(rows: 30, cols: 100)
      state = EditorState.sync_active_window_cursor(state)
      new_state = RenderPipeline.compute_layout(state)
      layout = Layout.get(new_state)

      {mr, _mc, mw, mh} = layout.minibuffer
      assert mr == 29
      assert mw == 100
      assert mh == 1

      {er, _ec, ew, eh} = layout.editor_area
      assert er == 1
      assert ew == 100
      assert eh == 28
    end
  end

  # ── Stage 3: Scroll ────────────────────────────────────────────────────────

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
      [{_win_id, window}] = Map.to_list(state.windows.map)

      # First frame: sentinel values trigger full invalidation
      assert window.dirty_lines == :all
    end
  end

  # ── Stage 4: Content ──────────────────────────────────────────────────────

  describe "build_content/2" do
    test "returns {WindowFrames, cursor_info, state}" do
      state = base_state()
      {scrolls, state, _layout} = run_through_scroll(state)

      {frames, cursor_info, state} = RenderPipeline.build_content(state, scrolls)

      assert [%WindowFrame{} | _] = frames
      assert {row, col} = cursor_info
      assert is_integer(row)
      assert is_integer(col)
      assert %EditorState{} = state
    end

    test "WindowFrame contains gutter and line layers" do
      state = base_state(content: "hello world")
      {scrolls, state, _layout} = run_through_scroll(state)

      {[wf], _cursor, _state} = RenderPipeline.build_content(state, scrolls)

      assert map_size(wf.lines) >= 1
    end

    test "modeline layer is empty (Chrome handles modeline)" do
      state = base_state()
      {scrolls, state, _layout} = run_through_scroll(state)

      {[wf], _cursor, _state} = RenderPipeline.build_content(state, scrolls)

      assert wf.modeline == %{}
    end

    test "updates window tracking fields after render" do
      state = base_state()
      {scrolls, state, _layout} = run_through_scroll(state)

      {_frames, _cursor, state} = RenderPipeline.build_content(state, scrolls)

      [{_win_id, window}] = Map.to_list(state.windows.map)

      # After rendering, dirty_lines should be cleared
      assert window.dirty_lines == %{}
      # Tracking fields should be set (no longer sentinels)
      assert window.last_viewport_top >= 0
      assert window.last_gutter_w >= 0
      assert window.last_line_count > 0
      assert window.last_buf_version >= 0
    end
  end

  # ── Stage 5: Chrome ────────────────────────────────────────────────────────

  describe "build_chrome/4" do
    test "returns a Chrome struct" do
      state = base_state()
      {scrolls, state, layout} = run_through_scroll(state)
      {_frames, cursor_info, state} = RenderPipeline.build_content(state, scrolls)

      chrome = RenderPipeline.build_chrome(state, layout, scrolls, cursor_info)

      assert %Chrome{} = chrome
    end

    test "chrome contains minibuffer draw" do
      state = base_state()
      {scrolls, state, layout} = run_through_scroll(state)
      {_frames, cursor_info, state} = RenderPipeline.build_content(state, scrolls)

      chrome = RenderPipeline.build_chrome(state, layout, scrolls, cursor_info)

      assert [_ | _] = chrome.minibuffer
      assert Enum.all?(chrome.minibuffer, &is_tuple/1)
    end

    test "chrome contains modeline draws per window" do
      state = base_state()
      {scrolls, state, layout} = run_through_scroll(state)
      {_frames, cursor_info, state} = RenderPipeline.build_content(state, scrolls)

      chrome = RenderPipeline.build_chrome(state, layout, scrolls, cursor_info)

      assert map_size(chrome.modeline_draws) == 1
      [{_win_id, draws}] = Map.to_list(chrome.modeline_draws)
      assert [_ | _] = draws
    end

    test "chrome regions is a list of binaries" do
      state = base_state()
      {scrolls, state, layout} = run_through_scroll(state)
      {_frames, cursor_info, state} = RenderPipeline.build_content(state, scrolls)

      chrome = RenderPipeline.build_chrome(state, layout, scrolls, cursor_info)

      assert is_list(chrome.regions)
      assert Enum.all?(chrome.regions, &is_binary/1)
    end
  end

  # ── Stage 6: Compose ──────────────────────────────────────────────────────

  describe "compose_windows/4" do
    test "returns a Frame struct" do
      state = base_state()
      {scrolls, state, layout} = run_through_scroll(state)
      {frames, cursor_info, state} = RenderPipeline.build_content(state, scrolls)
      chrome = RenderPipeline.build_chrome(state, layout, scrolls, cursor_info)

      frame = RenderPipeline.compose_windows(frames, chrome, cursor_info, state)

      assert %Frame{} = frame
      assert is_tuple(frame.cursor)
      assert frame.cursor_shape in [:block, :beam, :underline]
    end

    test "frame windows have modeline injected" do
      state = base_state()
      {scrolls, state, layout} = run_through_scroll(state)
      {frames, cursor_info, state} = RenderPipeline.build_content(state, scrolls)
      chrome = RenderPipeline.build_chrome(state, layout, scrolls, cursor_info)

      frame = RenderPipeline.compose_windows(frames, chrome, cursor_info, state)

      [wf | _] = frame.windows
      assert map_size(wf.modeline) >= 1
    end

    test "frame includes chrome elements" do
      state = base_state()
      {scrolls, state, layout} = run_through_scroll(state)
      {frames, cursor_info, state} = RenderPipeline.build_content(state, scrolls)
      chrome = RenderPipeline.build_chrome(state, layout, scrolls, cursor_info)

      frame = RenderPipeline.compose_windows(frames, chrome, cursor_info, state)

      assert frame.minibuffer != []
      assert is_list(frame.regions)
    end
  end

  # ── Stage 7: Emit ─────────────────────────────────────────────────────────

  describe "emit/2" do
    test "converts frame to commands and sends to port_manager" do
      frame = %Frame{
        cursor: {0, 0},
        cursor_shape: :block,
        splash: [DisplayList.draw(0, 0, "hello")]
      }

      state = base_state()
      assert :ok = RenderPipeline.emit(frame, state)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert is_list(commands)
      assert Enum.all?(commands, &is_binary/1)
    end
  end

  # ── Full pipeline integration ──────────────────────────────────────────────

  describe "run/1 (full pipeline)" do
    test "returns updated state with window caches" do
      state = base_state()
      result = RenderPipeline.run(state)

      assert %EditorState{} = result
      assert_receive {:"$gen_cast", {:send_commands, commands}}
      assert [_ | _] = commands

      # Windows should have updated tracking fields
      [{_win_id, window}] = Map.to_list(result.windows.map)
      assert window.dirty_lines == %{}
      assert window.last_buf_version >= 0
    end

    test "produces commands for different viewport sizes" do
      for {rows, cols} <- [{10, 40}, {24, 80}, {50, 200}] do
        state = base_state(rows: rows, cols: cols)
        result = RenderPipeline.run(state)
        assert %EditorState{} = result
        assert_receive {:"$gen_cast", {:send_commands, _}}
      end
    end
  end

  # ── Dirty-line tracking integration ────────────────────────────────────────

  describe "dirty-line tracking across frames" do
    test "second frame without edits detects no changes" do
      state = base_state(content: "line one\nline two\nline three")

      # Frame 1: first render populates caches
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      [{win_id, window}] = Map.to_list(state.windows.map)
      assert window.dirty_lines == %{}
      assert window.last_buf_version >= 0

      # Frame 2: no edits, run scroll to see invalidation result
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      {_scrolls, state} = RenderPipeline.scroll_windows(state, layout)

      window2 = Map.get(state.windows.map, win_id)
      # No changes detected, dirty_lines stays empty
      assert window2.dirty_lines == %{}
    end

    test "editing the buffer triggers invalidation on next frame" do
      state = base_state(content: "line one\nline two\nline three")
      buf = state.buffers.active

      # Frame 1
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      [{win_id, window1}] = Map.to_list(state.windows.map)
      old_version = window1.last_buf_version

      # Edit: insert a character
      BufferServer.insert_char(buf, "x")

      # Frame 2: scroll stage should detect version change
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      {_scrolls, state} = RenderPipeline.scroll_windows(state, layout)

      window2 = Map.get(state.windows.map, win_id)
      # Buffer version changed → full invalidation (conservative)
      assert window2.dirty_lines == :all

      # Verify version actually changed
      snapshot = BufferServer.render_snapshot(buf, 0, 3)
      assert snapshot.version > old_version
    end

    test "full pipeline produces correct output after edit" do
      state = base_state(content: "aaa\nbbb\nccc")
      buf = state.buffers.active

      # Frame 1
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, cmds1}}

      # Edit
      BufferServer.insert_char(buf, "X")

      # Frame 2
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, cmds2}}

      # Both frames should produce valid commands
      assert [_ | _] = cmds1
      assert [_ | _] = cmds2

      # Window should be clean after frame 2
      [{_win_id, window}] = Map.to_list(state.windows.map)
      assert window.dirty_lines == %{}
    end

    test "multiple sequential renders without edits produce stable state" do
      state = base_state()

      # Render 3 times
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      [{_win_id, window}] = Map.to_list(state.windows.map)
      assert window.dirty_lines == %{}
      assert window.last_buf_version >= 0
    end

    test "second render without edits reuses cached draws (clean lines)" do
      # A 10-line buffer in a viewport that shows all lines
      lines = Enum.map_join(1..10, "\n", &"line #{&1}")
      state = base_state(content: lines, rows: 15, cols: 80)

      # Frame 1: full render
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      [{win_id, window}] = Map.to_list(state.windows.map)
      # Verify caches were populated
      assert map_size(window.cached_content) > 0
      assert map_size(window.cached_gutter) > 0

      # Frame 2: no edits, no scroll, no cursor change
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      window2 = Map.get(state.windows.map, win_id)
      # Caches should still be populated and window clean
      assert map_size(window2.cached_content) > 0
      assert window2.dirty_lines == %{}
    end

    test "window caches contain per-line gutter and content draws" do
      state = base_state(content: "aaa\nbbb\nccc")

      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      [{_win_id, window}] = Map.to_list(state.windows.map)

      # Should have cache entries for lines 0, 1, 2
      assert Map.has_key?(window.cached_content, 0)
      assert Map.has_key?(window.cached_content, 1)
      assert Map.has_key?(window.cached_content, 2)
      assert Map.has_key?(window.cached_gutter, 0)
    end

    test "cached draws are identical to fresh draws for unchanged lines" do
      state = base_state(content: "hello\nworld\nfoo")

      # Frame 1: fresh render
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, cmds1}}

      [{win_id, window1}] = Map.to_list(state.windows.map)
      cached_content_0 = window1.cached_content[0]
      cached_gutter_0 = window1.cached_gutter[0]
      assert cached_content_0 != nil
      assert cached_gutter_0 != nil

      # Frame 2: no changes, should reuse cache and produce identical output
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, cmds2}}

      window2 = Map.get(state.windows.map, win_id)
      assert window2.cached_content[0] == cached_content_0
      assert window2.cached_gutter[0] == cached_gutter_0

      # Commands should be identical since content didn't change
      assert cmds1 == cmds2
    end

    test "edit marks buffer version changed, triggering full redraw" do
      lines = Enum.map_join(1..5, "\n", &"line #{&1}")
      state = base_state(content: lines, rows: 10, cols: 80)
      buf = state.buffers.active

      # Frame 1
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}
      [{win_id, _}] = Map.to_list(state.windows.map)

      # Edit buffer
      BufferServer.insert_char(buf, "X")

      # Frame 2: should detect version change, redraw all
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      window = Map.get(state.windows.map, win_id)
      # After render, window should be clean with updated caches
      assert window.dirty_lines == %{}
      assert window.last_buf_version > 0
      # Content cache should have the edited line
      assert Map.has_key?(window.cached_content, 0)
    end

    test "cursor-only movement with absolute numbering dirties only 2 lines" do
      lines = Enum.map_join(1..10, "\n", &"line #{&1}")
      state = base_state(content: lines, rows: 15, cols: 80)
      # Use absolute numbering so only old+new cursor lines dirty
      BufferServer.set_option(state.buffers.active, :line_numbers, :absolute)

      # Frame 1: full render
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      [{win_id, window}] = Map.to_list(state.windows.map)
      assert window.dirty_lines == %{}

      # Simulate cursor move from line 0 to line 3
      BufferServer.move(state.buffers.active, :down)
      BufferServer.move(state.buffers.active, :down)
      BufferServer.move(state.buffers.active, :down)

      # Run through scroll stage to detect gutter invalidation
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      {_scrolls, state} = RenderPipeline.scroll_windows(state, layout)

      window = Map.get(state.windows.map, win_id)
      # With absolute line numbers, only old and new cursor lines dirty
      assert window.dirty_lines != :all
      dirty_count = map_size(window.dirty_lines)
      assert dirty_count <= 2, "Expected at most 2 dirty lines, got #{dirty_count}"
    end

    test "cursor-only movement with hybrid numbering dirties all lines" do
      lines = Enum.map_join(1..10, "\n", &"line #{&1}")
      state = base_state(content: lines, rows: 15, cols: 80)
      # Hybrid numbering: every visible line number changes on cursor move
      BufferServer.set_option(state.buffers.active, :line_numbers, :hybrid)

      # Frame 1
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      # Move cursor
      BufferServer.move(state.buffers.active, :down)
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      {_scrolls, state} = RenderPipeline.scroll_windows(state, layout)

      [{_win_id, window}] = Map.to_list(state.windows.map)
      # Hybrid/relative: all lines dirty because every gutter number changes
      assert window.dirty_lines == :all
    end

    test "context fingerprint change triggers full redraw" do
      state = base_state(content: "aaa\nbbb\nccc")

      # Frame 1
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      [{win_id, window}] = Map.to_list(state.windows.map)
      assert window.dirty_lines == %{}
      assert window.last_context_fingerprint != nil

      # Simulate entering visual mode (changes visual_selection in context).
      # Visual mode uses VisualState as the mode_state, not a nested field.
      visual_state = %Minga.Mode.VisualState{visual_type: :char, visual_anchor: {0, 0}}
      state = %{state | vim: %{state.vim | mode: :visual, mode_state: visual_state}}

      # Frame 2: context fingerprint will change due to visual selection
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      window2 = Map.get(state.windows.map, win_id)
      # After render, dirty_lines is cleared but a full redraw happened
      assert window2.dirty_lines == %{}
      # Fingerprint should be updated
      assert window2.last_context_fingerprint != window.last_context_fingerprint
    end

    test "cache is pruned to visible range after render" do
      # 20-line buffer but viewport only shows ~10
      lines = Enum.map_join(1..20, "\n", &"line #{&1}")
      state = base_state(content: lines, rows: 12, cols: 80)

      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      [{_win_id, window}] = Map.to_list(state.windows.map)

      # Cache should only contain entries for visible lines (roughly 0..9)
      # Not lines 10..19 which are below the viewport
      max_cached_line = window.cached_content |> Map.keys() |> Enum.max()
      assert max_cached_line < 20, "Cache should not contain lines below viewport"

      # All cached lines should be in the visible range
      visible_count = Viewport.content_rows(window.viewport)
      assert map_size(window.cached_content) <= visible_count
    end
  end
end
