defmodule MingaEditor.RenderPipeline.LinePatchFastPathTest do
  @moduledoc """
  Acceptance tests for the typing/cursor-motion line-patch fast path (#2287).

  Drives the real render pipeline through `run_pipeline/1` and asserts against
  the `[:minga, :render, :pipeline]` telemetry stop metadata (`path` and
  `rows_rasterized`). The first frame seeds the retained-row cache; subsequent
  frames exercise reuse. Targets come from docs/RETAINED_GUI_RENDERING_SPEC.md.
  """

  # async: false — these tests attach a global `:telemetry` handler to the
  # shared `[:minga, :render, :pipeline, :stop]` event. Under concurrency the
  # handler would observe other tests' render frames, so the suite is
  # serialized to keep the path/rows_rasterized assertions deterministic.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.BufferPrefetch
  alias MingaEditor.RenderPipeline.Classifier
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Input, as: PipelineInput
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers

  setup context do
    # Capture the pipeline span's stop metadata for assertions. Each test gets a
    # unique handler id so the async suite never crosses streams.
    handler_id = {__MODULE__, context.test, self()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:minga, :render, :pipeline, :stop],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:pipeline_stop, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # Runs one render frame and returns {state, pipeline_stop_metadata}.
  defp render_frame(state) do
    state = run_pipeline(state)
    assert_receive {:pipeline_stop, metadata}
    drain_pipeline_stops()
    {state, metadata}
  end

  defp drain_pipeline_stops do
    receive do
      {:pipeline_stop, _} -> drain_pipeline_stops()
    after
      0 -> :ok
    end
  end

  defp warm(state) do
    # Two seed frames: the first frame is the keyframe / first-frame full path
    # with no retained rows; the second establishes a stable retained-row cache.
    {state, _} = render_frame(state)
    {state, _} = render_frame(state)
    state
  end

  defp move_cursor(state, {line, col}) do
    BufferProcess.move_to(state.workspace.buffers.active, {line, col})
    state
  end

  # Builds a GUI state whose active buffer soft-wraps, with several logical
  # lines long enough to wrap into multiple visual rows at the given width.
  defp wrapped_state(opts \\ []) do
    cols = Keyword.get(opts, :cols, 40)
    rows = Keyword.get(opts, :rows, 40)
    line_count = Keyword.get(opts, :line_count, 6)

    content =
      Enum.map_join(1..line_count, "\n", fn i ->
        "line #{i} " <> String.duplicate("word#{i} ", 25)
      end)

    state = gui_state(content: content, cols: cols, rows: rows)
    BufferProcess.set_option(state.workspace.buffers.active, :wrap, true)
    state
  end

  # Re-runs the Content stage's window-model build for the active window and
  # returns its semantic rows. Drives the same prefetch the orchestrator uses.
  defp window_model_rows(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    input = PipelineInput.from_editor_state(state)
    {scrolls, input} = BufferPrefetch.prefetch_scrolls(input, layout)
    win_id = input.workspace.windows.active
    scroll = Map.fetch!(scrolls, win_id)

    {[reuse_frame], _cursor, _st} = Content.build_content(input, %{win_id => scroll})

    fresh_window =
      scroll.window
      |> Window.put_retained_rows(%{})
      |> Window.put_retained_wrap_lines(%{})

    {[fresh_frame], _cursor, _st} =
      Content.build_content(input, %{win_id => %{scroll | window: fresh_window}})

    {reuse_frame.window_model.rows, fresh_frame.window_model.rows}
  end

  describe "AC 1: cursor motion without scrolling" do
    test "produces zero row rasterizations and takes the patch path" do
      state = gui_state(content: "alpha\nbravo\ncharlie\ndelta\necho")
      state = warm(state)

      # Move the cursor down one line, well within the viewport (no scroll).
      state = move_cursor(state, {1, 0})
      {_state, metadata} = render_frame(state)

      assert metadata.path == :patch
      assert metadata.rows_rasterized == 0
    end
  end

  describe "AC 2: one-line scroll" do
    test "rasterizes only the newly exposed row" do
      # A tall enough buffer that scrolling exposes exactly one new row. The
      # rows still on screen keep their row_id and input fingerprint, so the
      # retained-row cache reuses them; only the row scrolled into view composes.
      state = gui_state(content: long_content(100), rows: 8)
      buffer = state.workspace.buffers.active
      state = warm(state)

      # Pin the scroll margin so the one-line-scroll arithmetic is deterministic
      # regardless of the ambient :scroll_margin config.
      BufferProcess.set_option(buffer, :scroll_margin, 2)

      [{_win_id, window}] = Map.to_list(state.workspace.windows.map)
      top = window.viewport.top
      visible = MingaEditor.Viewport.content_rows(window.viewport)
      margin = 2

      # Land the cursor exactly on the first line that triggers a one-row scroll
      # past the bottom margin: new_top = cursor - visible + 1 + margin = top + 1.
      # That advances the viewport by one line, exposing exactly one new row.
      BufferProcess.move_to(buffer, {top + visible - margin, 0})
      {state, first} = render_frame(state)

      [{_id, after_window}] = Map.to_list(state.workspace.windows.map)
      assert after_window.viewport.top == top + 1, "expected a one-line scroll"

      assert first.path == :full
      assert first.rows_rasterized == 1
    end
  end

  describe "AC 3: single-line text edit" do
    test "rasterizes only the affected row" do
      state = gui_state(content: "alpha\nbravo\ncharlie\ndelta\necho")
      buffer = state.workspace.buffers.active
      state = warm(state)

      # Edit one line: insert a character on line 2 (0-based).
      BufferProcess.move_to(buffer, {2, 0})
      BufferProcess.insert_text(buffer, "X")
      {_state, metadata} = render_frame(state)

      assert metadata.rows_rasterized == 1
    end

    test "an untouched second edit on the same line still rasterizes one row" do
      state = gui_state(content: "alpha\nbravo\ncharlie\ndelta\necho")
      buffer = state.workspace.buffers.active
      state = warm(state)

      BufferProcess.move_to(buffer, {0, 0})
      BufferProcess.insert_text(buffer, "Y")
      {state, _} = render_frame(state)

      BufferProcess.insert_text(buffer, "Z")
      {_state, metadata} = render_frame(state)

      assert metadata.rows_rasterized == 1
    end
  end

  describe "AC 4: path classification" do
    test "typing and cursor motion take the patch path" do
      state = gui_state(content: "alpha\nbravo\ncharlie")
      state = warm(state)

      state = move_cursor(state, {1, 0})
      {state, motion_meta} = render_frame(state)
      assert motion_meta.path == :patch

      BufferProcess.insert_text(state.workspace.buffers.active, "!")
      {_state, edit_meta} = render_frame(state)
      assert edit_meta.path == :patch
    end

    test "a viewport scroll takes the full path" do
      state = gui_state(content: long_content(200), rows: 10)
      state = warm(state)

      # Jump far enough to force the viewport to scroll.
      state = move_cursor(state, {150, 0})
      {_state, metadata} = render_frame(state)

      assert metadata.path == :full
    end

    test "the first frame is the full path with no retained rows" do
      state = gui_state(content: "alpha\nbravo")
      {_state, metadata} = render_frame(state)

      assert metadata.path == :full
    end
  end

  describe "AC 5: content-epoch mismatch falls back to full refresh" do
    test "a gutter geometry change forces a conservative full refresh" do
      # Growing the line count past a power-of-ten boundary widens the gutter,
      # which the render cache treats as a geometry reset (epoch bump). The
      # classifier must fall back to :full rather than emit a stale patch.
      state = gui_state(content: Enum.map_join(1..9, "\n", &"line #{&1}"))
      buffer = state.workspace.buffers.active
      state = warm(state)

      # Cross into double-digit line numbers: gutter widens by one column.
      BufferProcess.move_to(buffer, {8, byte_size("line 9")})
      BufferProcess.insert_text(buffer, "\nline 10\nline 11")
      {_state, metadata} = render_frame(state)

      assert metadata.path == :full
    end
  end

  describe "Classifier unit coverage" do
    # Drives prefetch the same way the orchestrator does, then classifies.
    defp classify_after_prefetch(state) do
      state = EditorState.sync_active_window_cursor(state)
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)
      input = PipelineInput.from_editor_state(state)
      {scrolls, input} = BufferPrefetch.prefetch_scrolls(input, layout)
      Classifier.classify(input, scrolls)
    end

    test "cursor motion within the viewport classifies as patch once rows are retained" do
      state = gui_state(content: "alpha\nbravo\ncharlie")
      state = warm(state)
      state = move_cursor(state, {1, 0})

      assert classify_after_prefetch(state) == :patch
    end

    test "a forced keyframe classifies as full" do
      state = gui_state(content: "alpha\nbravo")
      state = warm(state)
      state = %{state | keyframe_pending?: true}

      assert classify_after_prefetch(state) == :full
    end

    test "a theme change classifies as full" do
      # A theme change resets frontend render state (`reset_pending`), which the
      # epoch prep turns into a full refresh. The moduledoc promises :full for
      # theme changes; this guards that the label matches the contract.
      state = gui_state(content: "alpha\nbravo\ncharlie")
      state = warm(state)
      state = EditorState.reset_frontend_render_state(state)

      assert classify_after_prefetch(state) == :full
    end
  end

  describe "AC 6: wrapped windows get true logical-line reuse" do
    test "cursor motion over a wrapped window rasterizes zero rows" do
      # The wrapped path must TRULY reuse unchanged logical lines: skipping both
      # composition and the wrap computation. A pure cursor move therefore
      # reports zero rasterized rows, not a dishonest zero over recomposed work.
      state = wrapped_state()
      state = warm(state)

      state = move_cursor(state, {2, 0})
      {_state, metadata} = render_frame(state)

      assert metadata.path == :patch
      assert metadata.rows_rasterized == 0
    end

    test "editing one wrapped logical line rasterizes only that line's visual rows" do
      # Editing line 3 bumps the buffer version (all lines dirty) but only the
      # edited logical line's fingerprint changes, so only its visual rows
      # recompose; every other wrapped line is reused whole.
      state = wrapped_state()
      buffer = state.workspace.buffers.active
      state = warm(state)

      # Capture the edited line's visual-row count so the assertion is exact.
      {rows, _fresh} = window_model_rows(state)
      line3_rows = Enum.count(rows, &(&1.buf_line == 3))
      assert line3_rows > 1, "expected line 3 to wrap into multiple visual rows"

      BufferProcess.move_to(buffer, {3, 0})
      BufferProcess.insert_text(buffer, "Z")
      {_state, metadata} = render_frame(state)

      assert metadata.rows_rasterized == line3_rows
    end

    test "a reused wrapped window is byte-identical to a freshly built one" do
      # Proves equivalence: the rows replayed from the logical-line cache match a
      # from-scratch compose+wrap exactly (row ids, text, spans, content hashes),
      # so reuse never drifts from a fresh build or destabilizes row identity.
      state = wrapped_state()
      state = warm(state)
      state = move_cursor(state, {2, 0})

      {reused_rows, fresh_rows} = window_model_rows(state)

      assert Enum.map(reused_rows, & &1.row_id) == Enum.map(fresh_rows, & &1.row_id)
      assert reused_rows == fresh_rows
    end

    test "a content-width change invalidates wrapped reuse" do
      # Wrap points depend on width, so a narrower content width must force a
      # recompose+rewrap rather than replaying stale wrap boundaries. Shrinking
      # the window changes the active buffer's wrap width.
      state = wrapped_state(cols: 60)
      state = warm(state)

      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)
      narrower = Window.resize(window, 40, 30)
      new_map = Map.put(state.workspace.windows.map, win_id, narrower)
      state = put_in(state.workspace.windows.map, new_map)
      state = put_in(state.terminal_viewport, MingaEditor.Viewport.new(40, 30))

      {_state, metadata} = render_frame(state)

      # The resize is a structural change (epoch reset), so the frame is full and
      # every visible wrapped row recomposes at the new width.
      assert metadata.path == :full
      assert metadata.rows_rasterized > 0
    end
  end
end
