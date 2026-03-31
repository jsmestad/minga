defmodule MingaEditor.RenderPipelineTest do
  @moduledoc """
  Integration tests for the full render pipeline.

  Tests that exercise cross-stage behavior: the full `run/1` pipeline
  and dirty-line tracking across frames. Per-stage unit tests live in
  `test/minga/editor/render_pipeline/*_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  import MingaEditor.RenderPipeline.TestHelpers

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
      # 30 rows: tab=1, status_bar=1, minibuffer=1, editor=27
      assert eh == 27
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
      [{_win_id, window}] = Map.to_list(result.workspace.windows.map)
      assert window.render_cache.dirty_lines == %{}
      assert window.render_cache.last_buf_version >= 0
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

      [{win_id, window}] = Map.to_list(state.workspace.windows.map)
      assert window.render_cache.dirty_lines == %{}
      assert window.render_cache.last_buf_version >= 0

      # Frame 2: no edits, run scroll to see invalidation result
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      {_scrolls, state} = Scroll.scroll_windows(state, layout)

      window2 = Map.get(state.workspace.windows.map, win_id)
      # No changes detected, dirty_lines stays empty
      assert window2.render_cache.dirty_lines == %{}
    end

    test "editing the buffer triggers invalidation on next frame" do
      state = base_state(content: "line one\nline two\nline three")
      buf = state.workspace.buffers.active

      # Frame 1
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      [{win_id, window1}] = Map.to_list(state.workspace.windows.map)
      old_version = window1.render_cache.last_buf_version

      # Edit: insert a character
      BufferServer.insert_char(buf, "x")

      # Frame 2: scroll stage should detect version change
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      {_scrolls, state} = Scroll.scroll_windows(state, layout)

      window2 = Map.get(state.workspace.windows.map, win_id)
      # Buffer version changed → full invalidation (conservative)
      assert window2.render_cache.dirty_lines == :all

      # Verify version actually changed
      snapshot = BufferServer.render_snapshot(buf, 0, 3)
      assert snapshot.version > old_version
    end

    test "full pipeline produces correct output after edit" do
      state = base_state(content: "aaa\nbbb\nccc")
      buf = state.workspace.buffers.active

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
      [{_win_id, window}] = Map.to_list(state.workspace.windows.map)
      assert window.render_cache.dirty_lines == %{}
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

      [{_win_id, window}] = Map.to_list(state.workspace.windows.map)
      assert window.render_cache.dirty_lines == %{}
      assert window.render_cache.last_buf_version >= 0
    end

    test "second render without edits reuses cached draws (clean lines)" do
      # A 10-line buffer in a viewport that shows all lines
      lines = Enum.map_join(1..10, "\n", &"line #{&1}")
      state = base_state(content: lines, rows: 15, cols: 80)

      # Frame 1: full render
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      [{win_id, window}] = Map.to_list(state.workspace.windows.map)
      # Verify caches were populated
      assert map_size(window.render_cache.cached_content) > 0
      assert map_size(window.render_cache.cached_gutter) > 0

      # Frame 2: no edits, no scroll, no cursor change
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      window2 = Map.get(state.workspace.windows.map, win_id)
      # Caches should still be populated and window clean
      assert map_size(window2.render_cache.cached_content) > 0
      assert window2.render_cache.dirty_lines == %{}
    end

    test "window caches contain per-line gutter and content draws" do
      state = base_state(content: "aaa\nbbb\nccc")

      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      [{_win_id, window}] = Map.to_list(state.workspace.windows.map)

      # Should have cache entries for lines 0, 1, 2
      assert Map.has_key?(window.render_cache.cached_content, 0)
      assert Map.has_key?(window.render_cache.cached_content, 1)
      assert Map.has_key?(window.render_cache.cached_content, 2)
      assert Map.has_key?(window.render_cache.cached_gutter, 0)
    end

    test "cached draws are identical to fresh draws for unchanged lines" do
      state = base_state(content: "hello\nworld\nfoo")

      # Frame 1: fresh render
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, cmds1}}

      [{win_id, window1}] = Map.to_list(state.workspace.windows.map)
      cached_content_0 = window1.render_cache.cached_content[0]
      cached_gutter_0 = window1.render_cache.cached_gutter[0]
      assert cached_content_0 != nil
      assert cached_gutter_0 != nil

      # Frame 2: no changes, should reuse cache and produce identical output
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, cmds2}}

      window2 = Map.get(state.workspace.windows.map, win_id)
      assert window2.render_cache.cached_content[0] == cached_content_0
      assert window2.render_cache.cached_gutter[0] == cached_gutter_0

      # Commands should be identical since content didn't change
      assert cmds1 == cmds2
    end

    test "edit marks buffer version changed, triggering full redraw" do
      lines = Enum.map_join(1..5, "\n", &"line #{&1}")
      state = base_state(content: lines, rows: 10, cols: 80)
      buf = state.workspace.buffers.active

      # Frame 1
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}
      [{win_id, _}] = Map.to_list(state.workspace.windows.map)

      # Edit buffer
      BufferServer.insert_char(buf, "X")

      # Frame 2: should detect version change, redraw all
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      window = Map.get(state.workspace.windows.map, win_id)
      # After render, window should be clean with updated caches
      assert window.render_cache.dirty_lines == %{}
      assert window.render_cache.last_buf_version > 0
      # Content cache should have the edited line
      assert Map.has_key?(window.render_cache.cached_content, 0)
    end

    test "cursor-only movement with absolute numbering dirties only 2 lines" do
      lines = Enum.map_join(1..10, "\n", &"line #{&1}")
      state = base_state(content: lines, rows: 15, cols: 80)
      # Use absolute numbering so only old+new cursor lines dirty
      BufferServer.set_option(state.workspace.buffers.active, :line_numbers, :absolute)

      # Frame 1: full render
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      [{win_id, window}] = Map.to_list(state.workspace.windows.map)
      assert window.render_cache.dirty_lines == %{}

      # Simulate cursor move from line 0 to line 3
      BufferServer.move(state.workspace.buffers.active, :down)
      BufferServer.move(state.workspace.buffers.active, :down)
      BufferServer.move(state.workspace.buffers.active, :down)

      # Run through scroll stage to detect gutter invalidation
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      {_scrolls, state} = Scroll.scroll_windows(state, layout)

      window = Map.get(state.workspace.windows.map, win_id)
      # With absolute line numbers, only old and new cursor lines dirty
      assert window.render_cache.dirty_lines != :all
      dirty_count = map_size(window.render_cache.dirty_lines)
      assert dirty_count <= 2, "Expected at most 2 dirty lines, got #{dirty_count}"
    end

    test "cursor-only movement with hybrid numbering dirties all lines" do
      lines = Enum.map_join(1..10, "\n", &"line #{&1}")
      state = base_state(content: lines, rows: 15, cols: 80)
      # Hybrid numbering: every visible line number changes on cursor move
      BufferServer.set_option(state.workspace.buffers.active, :line_numbers, :hybrid)

      # Frame 1
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      # Move cursor
      BufferServer.move(state.workspace.buffers.active, :down)
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      {_scrolls, state} = Scroll.scroll_windows(state, layout)

      [{_win_id, window}] = Map.to_list(state.workspace.windows.map)
      # Hybrid/relative: all lines dirty because every gutter number changes
      assert window.render_cache.dirty_lines == :all
    end

    test "context fingerprint change triggers full redraw" do
      state = base_state(content: "aaa\nbbb\nccc")

      # Frame 1
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      [{win_id, window}] = Map.to_list(state.workspace.windows.map)
      assert window.render_cache.dirty_lines == %{}
      assert window.render_cache.last_context_fingerprint != nil

      # Simulate entering visual mode (changes visual_selection in context).
      # Visual mode uses VisualState as the mode_state, not a nested field.
      visual_state = %Minga.Mode.VisualState{visual_type: :char, visual_anchor: {0, 0}}

      state = %{
        state
        | workspace: %{
            state.workspace
            | editing: %{state.workspace.editing | mode: :visual, mode_state: visual_state}
          }
      }

      # Frame 2: context fingerprint will change due to visual selection
      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      window2 = Map.get(state.workspace.windows.map, win_id)
      # After render, dirty_lines is cleared but a full redraw happened
      assert window2.render_cache.dirty_lines == %{}
      # Fingerprint should be updated
      assert window2.render_cache.last_context_fingerprint !=
               window.render_cache.last_context_fingerprint
    end

    test "cache is pruned to visible range after render" do
      # 20-line buffer but viewport only shows ~10
      lines = Enum.map_join(1..20, "\n", &"line #{&1}")
      state = base_state(content: lines, rows: 12, cols: 80)

      state = RenderPipeline.run(state)
      assert_receive {:"$gen_cast", {:send_commands, _}}

      [{_win_id, window}] = Map.to_list(state.workspace.windows.map)

      # Cache should only contain entries for visible lines (roughly 0..9)
      # Not lines 10..19 which are below the viewport
      max_cached_line = window.render_cache.cached_content |> Map.keys() |> Enum.max()
      assert max_cached_line < 20, "Cache should not contain lines below viewport"

      # All cached lines should be in the visible range
      visible_count = Viewport.content_rows(window.viewport)
      assert map_size(window.render_cache.cached_content) <= visible_count
    end
  end
end
