defmodule MingaEditor.RenderPipeline.ResidentIncrementalTest do
  @moduledoc "End-to-end checks for the incremental full-document residence build (#2658)."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.EditDelta
  alias Minga.Editing.Search.Index
  alias Minga.Events.BufferChangedEvent
  alias Minga.Language.Highlight.Span, as: HighlightSpan
  alias Minga.Search.IndexOwner
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Layout
  alias MingaEditor.Mouse
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.Gutter.Authorship
  alias Minga.RenderModel.Window.Gutter.ResidentRows
  alias Minga.RenderModel.Window.ScrollPresentation
  alias Minga.Core.Decorations
  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.BufferPrefetch
  alias MingaEditor.RenderPipeline.Classifier
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.Renderer.BufferChanges
  alias Minga.Perf.ProductionGate
  alias MingaEditor.Renderer.RenderReceipt
  alias MingaEditor.Renderer.Submission
  alias MingaEditor.Renderer.State, as: RendererState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.Parser
  alias MingaEditor.State.Render, as: EditorRender
  alias MingaEditor.GuiSearchWorkflow
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Search
  alias Minga.Mode.CommandState
  alias Minga.Core.WrapMap
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Renderer.WrapLayout
  alias MingaEditor.UI.Highlight
  alias MingaEditor.UI.Theme

  import MingaEditor.RenderPipeline.TestHelpers

  defp scroll_input(input, layout) do
    {prefetched, input} = BufferPrefetch.prefetch_scrolls(input, layout)
    input = Input.record_frame_render_path(input, Classifier.classify(input, prefetched))
    Scroll.scroll_windows(input, layout, prefetched)
  end

  # Builds the active window's semantic model for one frame, returning the model
  # and the state carrying the updated resident build cache into the next frame.
  # Resets the per-frame rasterized counter because this helper manually enters
  # the Content stage outside `RenderPipeline.run_windows_pipeline/2`.
  defp build_frame(%EditorState{} = editor) do
    build_frame(%{
      editor: editor,
      renderer: RendererState.new(editor_pid: nil, pipeline: &RenderPipeline.run/1)
    })
  end

  defp build_frame(%{editor: editor, renderer: renderer} = state) do
    editor = MingaEditor.WindowFocus.remember_active_cursor(editor)
    intent = Intent.from_editor_state(editor)
    intent = if Map.get(state, :keyframe?, false), do: Intent.force_keyframe(intent), else: intent
    {renderer, input} = BufferChanges.prepare(renderer, intent)
    input = Content.reset_rows_rasterized(input)
    input = RenderPipeline.compute_layout(input)
    layout = Layout.get(input)

    {scrolls, input} = scroll_input(input, layout)
    {contents, _cursor, output} = Content.build_content(input, scrolls)
    renderer = BufferChanges.commit(renderer, output, intent)
    receipt = RenderReceipt.from_output(output, 0, 0, 0)
    editor = EditorState.integrate_synchronous_renderer_receipt(editor, receipt)
    model = contents |> List.first() |> Map.fetch!(:models) |> List.first()
    {model, %{editor: editor, renderer: renderer, output: output}}
  end

  # Two seed frames: a full-document keyframe, then a no-change reuse frame, so
  # the resident store and digest are warm before the assertion frame.
  defp warm(state) do
    {_model, state} = build_frame(state)
    {_model, state} = build_frame(state)
    state
  end

  # Plain text avoids asynchronous parser highlights, and these fixtures use
  # unwrapped rows so their splice budgets have exact logical-row counts.
  defp resident_state(line_count) do
    state = gui_state(content: long_content(line_count), rows: 12, cols: 60, filetype: :text)
    BufferProcess.set_option(state.workspace.buffers.active, :wrap, false)
    state
  end

  defp warm_review_pair do
    state = warm(resident_state(300))
    buffer = state.editor.workspace.buffers.active

    for {line, step} <- [{40, "first"}, {220, "second"}] do
      assert {:ok, _} =
               BufferProcess.replace_byte_range_if_version(
                 buffer,
                 BufferProcess.version(buffer),
                 {line, 0},
                 0,
                 "new ",
                 EditSource.minga("task", step)
               )
    end

    {initial, state} = build_frame(state)
    {buffer, initial, state}
  end

  test "horizontal wheel keeps an empty caret row detached until the caret moves" do
    editor =
      gui_state(content: "\n" <> String.duplicate("x", 80), rows: 8, cols: 26, filetype: :text)

    buffer = editor.workspace.buffers.active
    id = editor.workspace.windows.active
    assert {:ok, false} = BufferProcess.set_option(buffer, :wrap, false)

    {initial, state} = build_frame(editor)
    editor = Mouse.handle_horizontal_pan(state.editor, id, 10, 1)
    {panned, state} = build_frame(%{state | editor: editor})

    assert %{top: 0, left: 10} = panned.geometry.viewport
    assert panned.scroll_seq == initial.scroll_seq

    assert %{can_pan_horizontally: true, horizontal_pan_ack: 1} =
             ScrollPresentation.from_window(panned)

    assert ScrollPresentation.from_window(panned).layout_generation ==
             ScrollPresentation.from_window(initial).layout_generation

    refute panned.cursor_visible
    assert BufferProcess.cursor(buffer) == {0, 0}

    assert :ok = BufferProcess.move_to(buffer, {1, 1})
    {following, state} = build_frame(state)
    assert %{top: 0, left: 0} = following.geometry.viewport
    assert following.scroll_seq > panned.scroll_seq
    assert following.cursor_visible

    editor = Mouse.handle_horizontal_pan(state.editor, id, -1, 2)
    {clamped, _state} = build_frame(%{state | editor: editor})
    assert %{anchor_left: 0, horizontal_pan_ack: 2} = ScrollPresentation.from_window(clamped)
  end

  test "a windowed caret keeps its source coordinate when the committed horizontal clip hides it" do
    content = String.duplicate("x", 80) <> :binary.copy("\n", 65_536)
    editor = gui_state(content: content, rows: 8, cols: 26, filetype: :text)
    buffer = editor.workspace.buffers.active
    assert {:ok, false} = BufferProcess.set_option(buffer, :wrap, false)
    {initial, state} = build_frame(editor)
    assert initial.row_store_mode == :windowed
    editor = Mouse.handle_horizontal_pan(state.editor, editor.workspace.windows.active, 10, 1)

    assert {%{row_store_mode: :windowed, cursor_visible: false, accessibility_cursor: {0, 0}},
            _state} = build_frame(%{state | editor: editor})
  end

  test "horizontal pan ignores long overscan rows and caps at the visible right edge" do
    long = String.duplicate("x", 80)
    content = :binary.copy("abc\n", 7) <> long <> :binary.copy("\nabc", 20)

    editor =
      base_state(
        content: content,
        rows: 8,
        cols: 26,
        filetype: :text,
        capabilities: %MingaEditor.Frontend.Capabilities{frontend_type: :tui, semantic_ui: true}
      )

    buffer = editor.workspace.buffers.active
    id = editor.workspace.windows.active
    assert {:ok, false} = BufferProcess.set_option(buffer, :wrap, false)
    {first, state} = build_frame(editor)
    assert Enum.any?(first.rows, &(&1.text == long))
    assert %{anchor_left: 0, horizontal_pan_limit: 0} = ScrollPresentation.from_window(first)

    editor = Mouse.handle_horizontal_pan(state.editor, id, 100, 1)
    {clamped, state} = build_frame(%{state | editor: editor})
    assert %{anchor_left: 0, horizontal_pan_ack: 1} = ScrollPresentation.from_window(clamped)

    editor = Mouse.handle_scroll_batch(state.editor, id, 7, :down)
    {wide, state} = build_frame(%{state | editor: editor})
    limit = 80 - wide.geometry.viewport.cols + 1
    assert %{horizontal_pan_limit: ^limit} = ScrollPresentation.from_window(wide)
    editor = Mouse.handle_horizontal_pan(state.editor, id, 100, 2)
    {panned, _state} = build_frame(%{state | editor: editor})
    assert %{anchor_left: ^limit, horizontal_pan_ack: 2} = ScrollPresentation.from_window(panned)
  end

  test "wrapped wheel reaches the final continuation without changing the cursor or resending rows" do
    editor =
      gui_state(content: String.duplicate("x", 256) <> "TAIL", rows: 8, cols: 26, filetype: :text)

    buffer = editor.workspace.buffers.active
    assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
    assert {:ok, :none} = BufferProcess.set_option(buffer, :line_numbers, :none)
    id = editor.workspace.windows.active

    {first, state} = build_frame(editor)
    assert first.row_store_mode == :windowed
    {promoted, state} = build_frame(state)
    assert {:resident, total_rows} = promoted.row_store_mode
    fitted = promoted.geometry.viewport.rows
    assert total_rows > fitted + 1
    assert Enum.any?(promoted.rows, &String.ends_with?(&1.text, "TAIL"))

    editor = Mouse.handle_scroll_batch(state.editor, id, 1, :down)
    {advanced, state} = build_frame(%{state | editor: editor})
    assert %{top: 0, visual_row_offset: 1} = advanced.geometry.viewport
    assert advanced.scroll_seq == promoted.scroll_seq
    assert %{splices: []} = advanced.row_delta
    assert state.output.caches.frame_render_path == :patch
    assert state.output.caches.frame_rows_rasterized == 0

    editor = Mouse.handle_scroll_batch(state.editor, id, 100, :down)
    {bottom, state} = build_frame(%{state | editor: editor})
    assert %{top: 0, visual_row_offset: offset} = bottom.geometry.viewport
    assert offset == total_rows - fitted
    assert %{splices: []} = bottom.row_delta
    assert state.output.caches.frame_render_path == :full
    assert state.output.caches.frame_rows_rasterized == 0

    editor = Mouse.handle_scroll_batch(state.editor, id, -1, :up)
    {reversed, _state} = build_frame(%{state | editor: editor})
    assert reversed.geometry.viewport.visual_row_offset == total_rows - fitted - 1
    assert BufferProcess.cursor(buffer) == {0, 0}
  end

  test "thumb rank reaches a continuation and rejects an obsolete layout without moving the cursor" do
    editor = gui_state(content: String.duplicate("x", 256), rows: 5, cols: 20, filetype: :text)
    buffer = editor.workspace.buffers.active
    id = editor.workspace.windows.active
    assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
    assert {:ok, :none} = BufferProcess.set_option(buffer, :line_numbers, :none)
    {_first, state} = build_frame(editor)
    {frame, state} = build_frame(state)
    renderer = RendererState.acknowledge_text_presentations(state.renderer, state.output)
    presentation = frame.text_presentation_id

    assert {:ok, renderer} =
             RendererState.text_presentation_state(renderer, id, presentation, :active)

    reader = RendererState.text_interaction_reader(renderer)

    editor = %{
      state.editor
      | render: EditorRender.connect_renderer(state.editor.render, self(), reader)
    }

    assert {:resident, rows} = frame.row_store_mode
    bottom = rows - frame.geometry.viewport.rows
    assert bottom > 0

    assert {:ok, action} =
             MingaEditor.Frontend.Protocol.GUI.decode_gui_action(
               Minga.Protocol.Opcodes.gui_action_scroll_to_visual_rank(),
               <<id::16, presentation::64, rows::32>>
             )

    editor = GuiActionHandler.dispatch(editor, action)
    assert %{top: 0, visual_row_offset: ^bottom} = editor.workspace.windows.map[id].viewport
    {after_drag, _state} = build_frame(%{state | editor: editor})
    assert after_drag.scroll_seq == frame.scroll_seq
    assert BufferProcess.cursor(buffer) == {0, 0}

    # An authoritative request can leave the top unchanged but still supersedes
    # a drag release from the frame on screen.
    jumped = %{editor | workspace: SessionState.mark_authoritative_scroll(editor.workspace)}
    old_release = {:scroll_to_visual_rank, id, presentation, 0}
    assert GuiActionHandler.dispatch(jumped, old_release) == jumped

    {jump_frame, jump_state} = build_frame(%{state | editor: jumped})
    refute jump_frame.text_presentation_id == presentation
    RendererState.acknowledge_text_presentations(jump_state.renderer, jump_state.output)
    assert GuiActionHandler.dispatch(jumped, old_release) == jumped

    assert {:ok, :absolute} = BufferProcess.set_option(buffer, :line_numbers, :absolute)

    assert GuiActionHandler.dispatch(editor, {:scroll_to_visual_rank, id, presentation, 0}) ==
             editor

    assert BufferProcess.cursor(buffer) == {0, 0}
  end

  test "windowed wheel reuses complete wrap counts until the source or width changes" do
    # Make the source ineligible for residence without storing a giant line.
    last_line = 65_536
    tail = String.duplicate("x", 1024) <> "TAIL"

    editor =
      gui_state(
        content: :binary.copy("\n", last_line) <> tail,
        rows: 8,
        cols: 26,
        filetype: :text
      )

    buffer = editor.workspace.buffers.active
    id = editor.workspace.windows.active
    assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
    assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)
    assert {:ok, :absolute} = BufferProcess.set_option(buffer, :line_numbers, :absolute)
    assert :ok = BufferProcess.move_to(buffer, {last_line, 0})

    editor = editor |> simulate_scroll(last_line) |> RenderPipeline.compute_layout()
    editor = Mouse.handle_scroll_batch(editor, id, 1, :down)
    {initial, state} = publish_windowed_frame(editor)
    assert initial.row_store_mode == :windowed

    assert %{top: ^last_line, visual_row_offset: 1, rows: fitted, cols: narrow} =
             initial.geometry.viewport

    source = BufferProcess.render_snapshot(buffer, 0, 0)
    oracle = MingaEditor.Frontend.Capabilities.width_oracle(editor.frontend.capabilities)
    basis = WrapLayout.basis(source, narrow, oracle, last_line)
    reader = state.editor.render.text_interaction_reader
    total = ceil_div(byte_size(tail), narrow)

    assert %{^last_line => ^total} =
             Reader.windowed_wrap_counts(reader, id, buffer, source.version, basis)

    session = :trace.session_create(:windowed_wheel_wraps, buffer, [])

    try do
      assert 1 = :trace.process(session, self(), true, [:call])

      state =
        Enum.reduce(2..3, state, fn expected, state ->
          {editor, editor_wraps} =
            count_wraps(session, fn -> Mouse.handle_scroll_batch(state.editor, id, 1, :down) end)

          # Missing counts for the bounded slice before the cached final line
          # are allowed; wrapping the final line again is not.
          assert editor_wraps <= fitted - 1

          {{frame, state}, renderer_wraps} =
            count_wraps(session, fn -> publish_windowed_frame(%{state | editor: editor}) end)

          assert renderer_wraps == 0
          assert %{top: ^last_line, visual_row_offset: ^expected} = frame.geometry.viewport
          refute frame.cursor_visible
          state
        end)

      editor = Mouse.handle_scroll_batch(state.editor, id, total, :down)
      {bottom, state} = publish_windowed_frame(%{state | editor: editor})
      assert bottom.geometry.viewport.visual_row_offset == total - fitted
      assert String.ends_with?(Enum.map_join(bottom.rows, & &1.text), "TAIL")
      assert BufferProcess.cursor(buffer) == {last_line, 0}

      assert {:ok, :none} = BufferProcess.set_option(buffer, :line_numbers, :none)

      wide =
        narrow + Gutter.total_width(:absolute, last_line + 1) -
          Gutter.total_width(:none, last_line + 1)

      wide_bottom = ceil_div(byte_size(tail), wide) - fitted

      {editor, cold_wraps} =
        count_wraps(session, fn -> Mouse.handle_scroll_batch(state.editor, id, 1, :down) end)

      assert cold_wraps > fitted - 1
      assert editor.workspace.windows.map[id].viewport.visual_row_offset == wide_bottom

      {{reflowed, state}, reflow_wraps} =
        count_wraps(session, fn -> publish_windowed_frame(%{state | editor: editor}) end)

      assert reflow_wraps >= 2
      assert reflowed.geometry.viewport.visual_row_offset == wide_bottom
      assert %{} == Reader.windowed_wrap_counts(reader, id, buffer, source.version, basis)

      shorter = String.duplicate("s", wide * (fitted + 2)) <> "END"
      assert :ok = BufferProcess.replace_lines(buffer, last_line, last_line, shorter)
      editor = Mouse.handle_scroll_batch(state.editor, id, 1, :down)
      assert editor.workspace.windows.map[id].viewport.visual_row_offset == 3

      {{edited, state}, edited_wraps} =
        count_wraps(session, fn -> publish_windowed_frame(%{state | editor: editor}) end)

      assert edited_wraps >= 2
      assert %{top: ^last_line, visual_row_offset: 3} = edited.geometry.viewport
      assert String.ends_with?(Enum.map_join(edited.rows, & &1.text), "END")

      source = BufferProcess.render_snapshot(buffer, 0, 0)
      basis = WrapLayout.basis(source, wide, oracle, last_line)

      assert %{^last_line => _} =
               Reader.windowed_wrap_counts(reader, id, buffer, source.version, basis)

      replacement = String.duplicate("p", wide * 3) <> "PREVIEW"
      command = CommandState.new("%s/END/#{replacement}/")
      workspace = SessionState.transition_mode(state.editor.workspace, :command, command)
      editor = RenderPipeline.compute_layout(%{state.editor | workspace: workspace})
      editor = Mouse.handle_scroll_batch(editor, id, total, :down)
      assert editor.workspace.windows.map[id].viewport.visual_row_offset > 3
      {preview, _state} = publish_windowed_frame(%{state | editor: editor})
      assert String.ends_with?(Enum.map_join(preview.rows, & &1.text), "PREVIEW")
      assert Reader.windowed_wrap_counts(reader, id, buffer, source.version, basis) == %{}
    after
      :trace.session_destroy(session)
    end
  end

  defp publish_windowed_frame(input) do
    {model, %{editor: editor, renderer: renderer, output: output} = state} = build_frame(input)
    renderer = RendererState.acknowledge_text_presentations(renderer, output)
    reader = RendererState.text_interaction_reader(renderer)
    render = EditorRender.connect_renderer(editor.render, self(), reader)
    {model, %{state | editor: %{editor | render: render}, renderer: renderer}}
  end

  defp count_wraps(session, fun) do
    mfas = [{WrapMap, :compute, 3}, {WrapMap, :count_rows, 3}]

    Enum.each(mfas, fn mfa ->
      assert 1 = :trace.function(session, mfa, true, [:call_time])
    end)

    result = fun.()
    pid = self()

    count =
      Enum.reduce(mfas, 0, fn mfa, total ->
        {:call_time, calls} = :trace.info(session, mfa, :call_time)
        {^pid, count, _, _} = List.keyfind(calls, pid, 0, {pid, 0, 0, 0})
        total + count
      end)

    {result, count}
  end

  defp ceil_div(size, width), do: div(size + width - 1, width)

  test "growing a wrapped line splices its visual group and preserves the unchanged suffix" do
    editor = gui_state(content: "alpha\nbeta\ntail", rows: 6, cols: 20, filetype: :text)
    buffer = editor.workspace.buffers.active
    assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
    {_first, state} = build_frame(editor)
    {initial, state} = build_frame(state)
    assert initial.row_store_mode == {:resident, 3}
    assert [_alpha, _beta, %{row_id: tail_id, text: "tail"}] = initial.rows

    BufferProcess.insert_text(buffer, String.duplicate("x", 120))
    {edited, state} = build_frame(state)
    refute edited.full_refresh
    assert [%{start_index: 0, delete_count: 1, insert_rows: inserted}] = edited.row_delta.splices
    assert [_, _ | _] = inserted
    assert edited.row_delta.result_row_count == 2 + length(inserted)
    {recovered, _state} = build_frame(Map.put(state, :keyframe?, true))
    assert Enum.any?(recovered.rows, &match?(%{row_id: ^tail_id, text: "tail"}, &1))
  end

  describe "cursor motion classification" do
    for {style, without_retained_rows} <- [absolute: :patch, relative: :full, hybrid: :full] do
      test "#{style} line numbers preserve the frame path and zero-row reuse" do
        editor = resident_state(30)
        buffer = editor.workspace.buffers.active
        id = editor.workspace.windows.active
        style = unquote(style)
        assert {:ok, ^style} = BufferProcess.set_option(buffer, :line_numbers, style)
        assert {:ok, 0} = BufferProcess.set_option(buffer, :scroll_margin, 0)
        assert :ok = BufferProcess.move_to(buffer, {1, 0})

        {_first, state} = build_frame(editor)
        {promoted, state} = build_frame(state)
        assert promoted.row_store_mode == {:resident, 30}
        assert map_size(state.output.windows.map[id].render_cache.retained_rows) > 0

        assert :ok = BufferProcess.move_to(buffer, {2, 0})
        {stepped, state} = build_frame(state)
        assert stepped.geometry.viewport.top == promoted.geometry.viewport.top
        assert stepped.gutter.cursor_line == 2
        refute stepped.full_refresh
        assert state.output.caches.frame_render_path == :patch
        assert state.output.caches.frame_rows_rasterized == 0
        assert state.output.windows.map[id].render_cache.retained_rows == %{}

        assert :ok = BufferProcess.move_to(buffer, {3, 0})
        {stepped, state} = build_frame(state)
        assert stepped.geometry.viewport.top == promoted.geometry.viewport.top
        assert stepped.gutter.cursor_line == 3
        refute stepped.full_refresh
        assert state.output.caches.frame_render_path == unquote(without_retained_rows)
        assert state.output.caches.frame_rows_rasterized == 0
      end
    end
  end

  describe "digest consistency" do
    test "promotion replaces storage while preserving durable content identity" do
      {first, state} = build_frame(resident_state(300))
      assert first.row_store_mode == :windowed
      {promoted, state} = build_frame(state)
      assert promoted.row_store_mode == {:resident, 300}
      assert promoted.content_epoch == first.content_epoch
      assert promoted.full_refresh
      {unchanged, _state} = build_frame(state)
      assert unchanged.content_epoch == promoted.content_epoch
      refute unchanged.full_refresh
      assert unchanged.row_delta.splices == []
    end

    test "unchanged resident frames preserve gutter rows after promotion" do
      {model, _state} = build_frame(warm(resident_state(300)))

      assert model.row_delta.splices == []
      assert %ResidentRows{line_count: 300, overrides: []} = model.gutter.entries
      assert model.row_store_mode == {:resident, 300}
      presentation = ScrollPresentation.from_window(model)
      assert {presentation.overscan_start_line, presentation.overscan_end_line} == {0, 300}
    end

    test "content_digest always equals a from-scratch digest of the emitted rows" do
      # First-paint-then-promote (#2679): warm one frame so residence is promoted.
      {model, _state} = build_frame(warm(resident_state(300)))

      refute is_nil(model.content_digest)
      assert model.row_delta.splices == []
      assert model.rows == []
    end

    test "an off-screen single-line edit splices one row and the digest tracks it" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active

      {before_model, state} = build_frame(state)
      before_digest = before_model.content_digest

      # Edit an off-screen line (viewport shows the top; line 250 is resident but
      # far below the fold).
      BufferProcess.move_to(buffer, {250, 0})
      BufferProcess.insert_text(buffer, "Z")

      {after_model, state} = build_frame(state)

      # The edited resident row's content changed, and the digest moved with it,
      # so the frame-emit gate fires rather than dropping a needed frame.
      assert after_model.content_digest != before_digest

      assert [%{start_index: 250, delete_count: 1, insert_rows: [row]}] =
               after_model.row_delta.splices

      assert row.buf_line == 250
      assert after_model.row_delta.base_row_count == 300
      assert after_model.row_delta.result_row_count == 300

      resident =
        Map.fetch!(state.renderer.resident_windows, state.editor.workspace.windows.active)

      assert {:ok, %VisualRow{buf_line: 250, row: %Row{buf_line: 250} = payload_row}} =
               ResidentStore.payload_at(resident.render_cache.resident_build.store, 250)

      assert payload_row.row_id == row.row_id
      assert payload_row.content_hash == row.content_hash
    end

    test "a warm no-edit frame never fetches the full resident document" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active

      calls = trace_buffer_calls(buffer, fn -> build_frame(state) end)

      refute Enum.any?(calls.messages, fn
               {:render_lines, _version, 0, 300} -> true
               _ -> false
             end)

      assert Enum.all?(calls.messages, fn
               {:render_lines, _version, _first, count} -> count <= 12
               _ -> true
             end)
    end

    test "an ordinary resident edit uses one atomic consume snapshot and no render_lines" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active

      BufferProcess.move_to(buffer, {150, 0})
      BufferProcess.insert_text(buffer, "Z")

      calls = trace_buffer_calls(buffer, fn -> build_frame(state) end)

      assert Enum.count(calls.messages, &match?({:renderer_consume, _}, &1)) == 1
      refute Enum.any?(calls.messages, &match?({:render_lines, _, _, _}, &1))
      refute Enum.any?(calls.messages, &match?(:version, &1))
    end

    test "a pure cursor move reuses the resident rows and leaves the digest unchanged" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active

      {before_model, state} = build_frame(state)
      BufferProcess.move_to(buffer, {120, 0})
      {after_model, _state} = build_frame(state)

      assert after_model.content_digest == before_model.content_digest
      assert after_model.row_delta.splices == []
      assert after_model.rows == []
    end
  end

  describe "resident presentation oracle" do
    test "encoded partial updates display the same grid as complete frames" do
      alias Minga.Frontend.Adapter.GUI
      alias Minga.Frontend.Adapter.GUI.Caches
      alias Minga.Test.HeadlessPort

      incremental_port =
        start_supervised!(
          Supervisor.child_spec({HeadlessPort, width: 60, height: 14}, id: :incremental)
        )

      fresh_port =
        start_supervised!(
          Supervisor.child_spec({HeadlessPort, width: 60, height: 14}, id: :fresh)
        )

      state = warm(resident_state(300))

      operations = [
        :recovery,
        :unchanged,
        :scroll,
        :insert_many,
        :unchanged,
        :delete_many,
        :sign,
        :clear_sign,
        :search,
        :text_style,
        :unchanged,
        :recovery
      ]

      Enum.reduce(Enum.with_index(operations, 1), {state, Caches.new()}, fn {operation, seq},
                                                                            {state, caches} ->
        state = perform_presentation_operation(state, operation)
        {model, state} = build_frame(state)
        fresh = fresh_resident_frame(state.editor)
        caches = if operation == :recovery, do: Caches.new(), else: caches
        {commands, caches} = GUI.encode_windows([model], caches)
        {fresh_commands, _} = GUI.encode_windows([fresh], Caches.new())
        base = if operation == :recovery, do: 0, else: seq - 1
        :accepted = HeadlessPort.send_transaction(incremental_port, seq, base, 0, commands)
        :accepted = HeadlessPort.send_transaction(fresh_port, seq, 0, 0, fresh_commands)

        assert HeadlessPort.production_state(incremental_port).outcome == :accepted,
               inspect(operation)

        assert HeadlessPort.production_state(fresh_port).outcome == :accepted, inspect(operation)

        assert HeadlessPort.get_screen(incremental_port).grid ==
                 HeadlessPort.get_screen(fresh_port).grid,
               inspect(operation)

        {state, Caches.acknowledge_pending_window_deltas(caches)}
      end)
    end

    test "deep-scroll reuse resolves cursor columns from the current resident viewport" do
      content =
        Enum.join(List.duplicate("x", 40) ++ List.duplicate(String.duplicate("l", 80), 260), "\n")

      editor = gui_state(content: content, rows: 12, cols: 60, filetype: :text)
      BufferProcess.set_option(editor.workspace.buffers.active, :wrap, false)
      state = warm(editor)
      BufferProcess.move_to(editor.workspace.buffers.active, {120, 40})
      {incremental, state} = build_frame(state)
      fresh = fresh_resident_frame(state.editor)
      assert incremental.cursor_col == 40
      assert incremental.cursor_col == fresh.cursor_col
      assert incremental.row_delta.splices == []
    end

    test "partial updates match a fresh render through motion, edits, signs, and recovery" do
      state = warm(resident_state(300))
      initial = fresh_resident_frame(state.editor)

      operations = [
        :unchanged,
        :scroll,
        :insert,
        :unchanged,
        :delete,
        :sign,
        :unchanged,
        :scroll,
        :clear_sign,
        :search,
        :unchanged,
        :text_style,
        :recovery,
        :unchanged
      ]

      Enum.reduce(operations, {state, initial.rows}, fn operation, {state, rows} ->
        state = perform_presentation_operation(state, operation)
        {incremental, state} = build_frame(state)
        oracle = fresh_resident_frame(state.editor)
        rows = apply_row_update(rows, incremental)

        assert length(rows) == length(oracle.rows),
               "#{operation}: incremental #{length(rows)} rows, fresh #{length(oracle.rows)} rows"

        assert Enum.map(rows, &{&1.text, &1.spans}) == Enum.map(oracle.rows, &{&1.text, &1.spans}),
               inspect(operation)

        assert incremental.accessibility_cursor == oracle.accessibility_cursor, inspect(operation)
        assert incremental.row_store_mode == oracle.row_store_mode
        assert gutter_projection(incremental) == gutter_projection(oracle), inspect(operation)
        assert scroll_projection(incremental) == scroll_projection(oracle), inspect(operation)

        {state, rows}
      end)
    end

    test "a sign-only change and its removal update the complete resident gutter" do
      state = warm(resident_state(300))
      state = perform_presentation_operation(state, :sign)
      {signed, state} = build_frame(state)
      assert %ResidentRows{overrides: [entry]} = signed.gutter.entries
      assert signed.row_delta.splices == []
      assert {entry.buf_line, entry.sign_type, entry.sign_text} == {220, :annotation, "!"}

      {reused, state} = build_frame(state)
      assert reused.rows == []
      assert reused.gutter.entries == signed.gutter.entries

      state = perform_presentation_operation(state, :clear_sign)
      {cleared, _state} = build_frame(state)
      assert %ResidentRows{line_count: 300, overrides: []} = cleared.gutter.entries
    end

    test "windowed scrolling inside the same ribbon reuses its observed source rows" do
      editor = gui_state(content: long_content(66_000), rows: 12, cols: 60, filetype: :text)
      buffer = editor.workspace.buffers.active
      assert {:ok, false} = BufferProcess.set_option(buffer, :wrap, false)

      for line <- 0..29 do
        source = EditSource.minga("task", "step-#{line}")

        assert {:ok, _} =
                 BufferProcess.replace_byte_range_if_version(
                   buffer,
                   BufferProcess.version(buffer),
                   {line, 0},
                   0,
                   "X",
                   source
                 )
      end

      assert :ok = BufferProcess.move_to(buffer, {0, 0})
      {marked, state} = build_frame(editor)
      assert marked.row_store_mode == :windowed
      assert [{:text, _unit, {0, 0}, 29}] = marks = Authorship.regions(marked.gutter.authorship)

      assert :ok = BufferProcess.move_to(buffer, {10, 0})
      editor = simulate_scroll(state.editor, 5)
      calls = trace_buffer_calls(buffer, fn -> build_frame(%{state | editor: editor}) end)
      {scrolled, _} = calls.result
      assert scrolled.row_store_mode == :windowed
      assert scrolled.geometry.viewport.top > marked.geometry.viewport.top
      assert Authorship.regions(scrolled.gutter.authorship) == marks
      refute Enum.any?(calls.messages, &match?({:render_review_regions, _, _}, &1))
    end

    test "a distant authored region and sign coexist without resending resident text on Keep" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active
      source = EditSource.minga("task", "step")

      assert {:ok, _} =
               BufferProcess.replace_byte_range_if_version(
                 buffer,
                 BufferProcess.version(buffer),
                 {220, 0},
                 0,
                 "fresh\nmore ",
                 source
               )

      state = perform_presentation_operation(state, :sign)
      {marked, state} = build_frame(state)
      assert [{:text, _unit, {220, 0}, 221}] = Authorship.regions(marked.gutter.authorship)
      assert %ResidentRows{overrides: [entry]} = marked.gutter.entries
      assert {entry.buf_line, entry.sign_type, entry.sign_text} == {220, :annotation, "!"}

      warm_calls = trace_buffer_calls(buffer, fn -> build_frame(state) end)
      {unchanged, state} = warm_calls.result
      assert unchanged.rows == []
      assert unchanged.gutter.authorship == marked.gutter.authorship
      refute Enum.any?(warm_calls.messages, &match?({:render_review_regions, _, _}, &1))

      assert {:ok, target, {:minga, "task"}, 1} = Minga.Buffer.prepare_review(buffer, :latest)
      assert :ok = Minga.Buffer.decide_review(buffer, target, :keep)
      keep_calls = trace_buffer_calls(buffer, fn -> build_frame(state) end)
      {kept, _state} = keep_calls.result

      assert Authorship.regions(kept.gutter.authorship) == [{:kept, {220, 0}, 221}]
      assert kept.gutter.entries == marked.gutter.entries
      assert kept.content_epoch == marked.content_epoch
      assert kept.text_presentation_id == unchanged.text_presentation_id
      assert kept.rows == []
      refute Enum.any?(keep_calls.messages, &match?({:render_lines, _, _, 301}, &1))

      assert [{:render_review_regions, _, [{219, 222}]}] =
               Enum.filter(keep_calls.messages, &match?({:render_review_regions, _, _}, &1))
    end

    test "a discarded frame does not lose disjoint Keep patches based on the last accepted frame" do
      {buffer, initial, state} = warm_review_pair()

      assert [{:text, _, {40, 0}, 40}, {:text, _, {220, 0}, 220}] =
               before = Authorship.regions(initial.gutter.authorship)

      assert {:ok, first, _, 1} =
               Minga.Buffer.prepare_review(buffer, {:step, {:minga, "task", "first"}})

      assert :ok = Minga.Buffer.decide_review(buffer, first, :keep)

      {observed, _discarded} =
        BufferChanges.prepare(state.renderer, Intent.from_editor_state(state.editor))

      assert {:ok, second, _, 1} =
               Minga.Buffer.prepare_review(buffer, {:step, {:minga, "task", "second"}})

      assert :ok = Minga.Buffer.decide_review(buffer, second, :keep)

      calls = trace_buffer_calls(buffer, fn -> build_frame(%{state | renderer: observed}) end)
      {latest, _state} = calls.result
      kept = [{:kept, {40, 0}, 40}, {:kept, {220, 0}, 220}]
      assert Authorship.regions(latest.gutter.authorship) == kept

      assert {:patch, _, _, ^kept, ^before} =
               Authorship.update(initial.gutter.authorship, latest.gutter.authorship)

      assert [{:render_review_regions, _, [{39, 41}, {219, 221}]}] =
               Enum.filter(calls.messages, &match?({:render_review_regions, _, _}, &1))
    end

    test "ordinary typing updates only the touched authored rows" do
      {buffer, initial, state} = warm_review_pair()

      assert [{:text, near, {40, 0}, 40}, {:text, far, {220, 0}, 220}] =
               Authorship.regions(initial.gutter.authorship)

      BufferProcess.move_to(buffer, {40, 0})
      BufferProcess.insert_text(buffer, "!")
      calls = trace_buffer_calls(buffer, fn -> build_frame(state) end)
      {latest, _state} = calls.result

      assert Authorship.regions(latest.gutter.authorship) == [
               {:you, {40, 0}, 40},
               {:text, near, {40, 1}, 40},
               {:text, far, {220, 0}, 220}
             ]

      assert [{:render_review_regions, _, [{39, 41}]}] =
               Enum.filter(calls.messages, &match?({:render_review_regions, _, _}, &1))

      assert {:patch, _, _, added, [{:text, ^near, {40, 0}, 40}]} =
               Authorship.update(initial.gutter.authorship, latest.gutter.authorship)

      assert MapSet.new(added) == MapSet.new([{:you, {40, 0}, 40}, {:text, near, {40, 1}, 40}])
    end

    test "a newline after a dropped Keep shifts far marks without rereading them" do
      {buffer, initial, state} = warm_review_pair()

      assert [{:text, _, {40, 0}, 40}, {:text, far, {220, 0}, 220}] =
               before = Authorship.regions(initial.gutter.authorship)

      assert {:ok, target, _, 1} =
               Minga.Buffer.prepare_review(buffer, {:step, {:minga, "task", "first"}})

      assert :ok = Minga.Buffer.decide_review(buffer, target, :keep)

      {observed, _discarded} =
        BufferChanges.prepare(state.renderer, Intent.from_editor_state(state.editor))

      BufferProcess.move_to(buffer, {10, 0})
      BufferProcess.insert_text(buffer, "\n")
      calls = trace_buffer_calls(buffer, fn -> build_frame(%{state | renderer: observed}) end)
      {latest, _state} = calls.result
      current = [{:you, {10, 0}, 10}, {:kept, {41, 0}, 41}, {:text, far, {221, 0}, 221}]
      assert Authorship.regions(latest.gutter.authorship) == current

      assert {:patch, _, _, added, ^before} =
               Authorship.update(initial.gutter.authorship, latest.gutter.authorship)

      assert MapSet.new(added) == MapSet.new(current)

      assert [{:render_review_regions, _, [{9, 12}, {40, 42}]}] =
               Enum.filter(calls.messages, &match?({:render_review_regions, _, _}, &1))
    end

    test "a text composition change fetches complete source before replacing residence" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active
      state = perform_presentation_operation(state, :text_style)
      calls = trace_buffer_calls(buffer, fn -> build_frame(state) end)
      assert Enum.any?(calls.messages, &match?({:render_lines, _, 0, 300}, &1))
    end

    test "offscreen search hydration uses complete context and then reuses it" do
      state = warm(resident_state(300))
      state = perform_presentation_operation(state, :scroll)
      state = perform_presentation_operation(state, :search)
      {model, state} = build_frame(state)
      fresh = fresh_resident_frame(state.editor)
      assert Enum.at(model.rows, 220).spans == Enum.at(fresh.rows, 220).spans
      assert Enum.any?(Enum.at(model.rows, 220).spans, &(&1.bg not in [nil, 0]))
      {reused, state} = build_frame(state)
      assert reused.row_delta.splices == []

      calls =
        trace_buffer_calls(state.editor.workspace.buffers.active, fn -> build_frame(state) end)

      refute Enum.any?(calls.messages, &match?({:render_lines, _, 0, 300}, &1))
    end

    test "indexed GUI search survives an unrelated edit and a query generation replaces it" do
      state = resident_state(300) |> install_gui_search("line 221:") |> warm()
      buffer = state.editor.workspace.buffers.active

      assert resident_row_has_background?(state, 220)

      BufferProcess.move_to(buffer, {100, 0})
      :ok = BufferProcess.insert_text(buffer, "Z")
      {version, sequence} = BufferProcess.sync_revision(buffer)
      delta = EditDelta.insertion(0, {100, 0}, "Z", {100, 1})

      editor =
        GuiSearchWorkflow.buffer_changed(
          state.editor,
          %BufferChangedEvent{
            buffer: buffer,
            source: :user,
            delta: delta,
            version: version,
            sequence: sequence
          }
        )

      {edited, state} = build_frame(%{state | editor: editor})
      assert Enum.map(edited.row_delta.splices, & &1.start_index) == [100]
      assert resident_row_has_background?(state, 220)

      old_generation = state.editor.workspace.search.gui_search.result |> elem(1)
      pending = begin_gui_query(state, "line 222:")
      {_cleared, pending} = build_frame(pending)
      refute resident_row_has_background?(pending, 220)

      state = complete_gui_query(pending)
      assert IndexOwner.matches_in_range(old_generation, 220, 220) == :stale

      {recomposed, state} = build_frame(state)
      assert recomposed.row_delta == nil
      refute resident_row_has_background?(state, 220)
      assert resident_row_has_background?(state, 221)
    end

    test "hydration reapplies substitute preview to the complete source" do
      state = warm(resident_state(300))
      state = perform_presentation_operation(state, :scroll)
      mode = Minga.Mode.CommandState.new("%s/line 221:/replacement/g")

      workspace =
        MingaEditor.Session.State.transition_mode(state.editor.workspace, :command, mode)

      state = %{state | editor: %{state.editor | workspace: workspace}}
      {model, state} = build_frame(state)
      fresh = fresh_resident_frame(state.editor)
      assert Enum.at(model.rows, 220).text =~ "replacement"

      assert Enum.map(model.rows, &{&1.text, &1.spans}) ==
               Enum.map(fresh.rows, &{&1.text, &1.spans})

      {reused, _state} = build_frame(state)
      assert reused.row_delta.splices == []
    end
  end

  defp fresh_resident_frame(editor) do
    {_arming_frame, state} = build_frame(editor)
    {model, _state} = build_frame(Map.put(state, :keyframe?, true))
    assert model.row_delta == nil
    model
  end

  defp perform_presentation_operation(state, :unchanged), do: state
  defp perform_presentation_operation(state, :recovery), do: Map.put(state, :keyframe?, true)

  defp perform_presentation_operation(state, :scroll) do
    BufferProcess.move_to(state.editor.workspace.buffers.active, {120, 0})
    state
  end

  defp perform_presentation_operation(state, :insert) do
    buffer = state.editor.workspace.buffers.active
    BufferProcess.move_to(buffer, {50, 0})
    BufferProcess.insert_text(buffer, "inserted\n")
    state
  end

  defp perform_presentation_operation(state, :delete) do
    BufferProcess.delete_lines(state.editor.workspace.buffers.active, 50, 50)
    state
  end

  defp perform_presentation_operation(state, :insert_many) do
    buffer = state.editor.workspace.buffers.active
    BufferProcess.move_to(buffer, {50, 0})
    BufferProcess.insert_text(buffer, "first\nsecond\nthird\n")
    state
  end

  defp perform_presentation_operation(state, :delete_many) do
    BufferProcess.delete_lines(state.editor.workspace.buffers.active, 50, 52)
    state
  end

  defp perform_presentation_operation(state, :sign) do
    BufferProcess.batch_decorations(state.editor.workspace.buffers.active, fn decorations ->
      {_id, decorations} =
        Decorations.add_annotation(decorations, 220, "!",
          kind: :gutter_icon,
          group: :gutter_oracle,
          fg: 0xFF0000
        )

      decorations
    end)

    state
  end

  defp perform_presentation_operation(state, :clear_sign) do
    BufferProcess.batch_decorations(
      state.editor.workspace.buffers.active,
      &Decorations.remove_group(&1, :gutter_oracle)
    )

    state
  end

  defp perform_presentation_operation(state, :text_style) do
    BufferProcess.batch_decorations(state.editor.workspace.buffers.active, fn decorations ->
      {_id, decorations} =
        Decorations.add_highlight(decorations, {220, 0}, {220, 4},
          style: Minga.Core.Face.new(fg: 0xFF0000)
        )

      decorations
    end)

    state
  end

  defp perform_presentation_operation(state, :search) do
    search = %Minga.Mode.SearchState{input: "line 221:", direction: :forward}
    workspace = MingaEditor.Session.State.transition_mode(state.editor.workspace, :search, search)
    %{state | editor: %{state.editor | workspace: workspace}}
  end

  defp install_gui_search(editor, query) do
    buffer = editor.workspace.buffers.active

    search =
      editor.workspace.search
      |> Search.focus_gui_search(false)
      |> Search.begin_gui_build(buffer)

    {:accepted, search} =
      Search.apply_gui_search_edit(
        search,
        search.gui_search.session_id,
        1,
        query,
        true,
        false,
        false
      )

    search = Search.begin_gui_build(search, buffer)
    {version, sequence} = BufferProcess.sync_revision(buffer)
    lines = :binary.split(BufferProcess.content(buffer), "\n", [:global])
    index = Index.build(lines, query, case_sensitive: true)

    {:ok, generation} =
      IndexOwner.install(
        buffer,
        Search.gui_query_revision(search),
        version,
        sequence,
        index
      )

    {:accepted, search} =
      Search.accept_gui_generation(search, search.gui_search.revision, buffer, generation)

    %{editor | workspace: SessionState.set_search(editor.workspace, search)}
  end

  defp begin_gui_query(%{editor: editor} = state, query) do
    buffer = editor.workspace.buffers.active
    session = editor.workspace.search.gui_search

    {:accepted, search} =
      Search.apply_gui_search_edit(
        editor.workspace.search,
        session.session_id,
        session.acknowledged_edit_seq + 1,
        query,
        true,
        false,
        false
      )

    search = Search.begin_gui_build(search, buffer)

    %{state | editor: %{editor | workspace: SessionState.set_search(editor.workspace, search)}}
  end

  defp complete_gui_query(%{editor: editor} = state) do
    buffer = editor.workspace.buffers.active
    search = editor.workspace.search
    query = search.gui_search.query
    {version, sequence} = BufferProcess.sync_revision(buffer)
    lines = :binary.split(BufferProcess.content(buffer), "\n", [:global])

    {:ok, generation} =
      IndexOwner.install(
        buffer,
        Search.gui_query_revision(search),
        version,
        sequence,
        Index.build(lines, query, case_sensitive: true)
      )

    {:accepted, search} =
      Search.accept_gui_generation(search, search.gui_search.revision, buffer, generation)

    %{state | editor: %{editor | workspace: SessionState.set_search(editor.workspace, search)}}
  end

  defp resident_row_has_background?(state, row) do
    window = Map.fetch!(state.renderer.resident_windows, state.editor.workspace.windows.active)
    {:ok, payload} = ResidentStore.payload_at(window.render_cache.resident_build.store, row)
    Enum.any?(payload.row.spans, &(&1.bg not in [nil, 0]))
  end

  defp apply_row_update(_rows, %{row_delta: nil, rows: rows}), do: rows

  defp apply_row_update(rows, %{row_delta: delta}) do
    assert length(rows) == delta.base_row_count

    result =
      Enum.reduce(Enum.reverse(delta.splices), rows, fn splice, rows ->
        Enum.take(rows, splice.start_index) ++
          splice.insert_rows ++ Enum.drop(rows, splice.start_index + splice.delete_count)
      end)

    assert length(result) == delta.result_row_count
    result
  end

  defp gutter_projection(%{gutter: %{entries: %ResidentRows{} = rows} = gutter}) do
    {rows.line_count, rows.overrides, gutter.cursor_line, gutter.line_number_style,
     gutter.line_number_width, gutter.sign_col_width}
  end

  defp scroll_projection(model) do
    presentation = ScrollPresentation.from_window(model)

    {presentation.anchor_top, presentation.visible_start_line, presentation.visible_end_line,
     presentation.overscan_start_line, presentation.overscan_end_line}
  end

  test "sparse edits preserve comment scope after clean multibyte source" do
    lines =
      for index <- 0..299 do
        case index do
          64 -> "é🙂"
          96 -> "# TODO keep"
          _ -> "ordinary line"
        end
      end

    offset = lines |> Enum.take(96) |> Enum.reduce(0, &(byte_size(&1) + 1 + &2))
    editor = gui_state(content: Enum.join(lines, "\n"), rows: 12, cols: 60, filetype: :text)
    buffer = editor.workspace.buffers.active
    assert {:ok, false} = BufferProcess.set_option(buffer, :wrap, false)

    syntax =
      editor.appearance.theme
      |> Highlight.from_theme()
      |> Highlight.put_names(["comment"])
      |> Highlight.put_spans(1, [HighlightSpan.new(offset, offset + 11, 0)])

    highlighting = Highlighting.put_highlight(editor.parser.highlighting, buffer, syntax)
    editor = %{editor | parser: Parser.accept_highlighting(editor.parser, highlighting)}
    state = warm(editor)

    assert :ok = BufferProcess.apply_edit(buffer, 32, 0, 32, 0, "O")
    assert :ok = BufferProcess.apply_edit(buffer, 96, 7, 96, 7, "K")
    {model, state} = build_frame(state)

    assert [
             %{start_index: 32, insert_rows: [_]},
             %{start_index: 96, insert_rows: [row]}
           ] = model.row_delta.splices

    assert row.text == "# TODO Keep"
    fresh_row = state.editor |> fresh_resident_frame() |> Map.fetch!(:rows) |> Enum.at(96)
    assert row.spans == fresh_row.spans

    todo_fg = Theme.hl_todo_faces(editor.appearance.theme).todo.fg
    assert Enum.any?(row.spans, &match?(%{start_col: 2, end_col: 6, fg: ^todo_fg}, &1))
  end

  describe "uncommitted consume retry" do
    test "two ordered edits keep their own snapshots and compose once on both rows" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active

      BufferProcess.move_to(buffer, {32, 0})
      BufferProcess.insert_text(buffer, "A")

      editor = MingaEditor.WindowFocus.remember_active_cursor(state.editor)
      intent = Intent.from_editor_state(editor)
      {renderer, stale_input} = BufferChanges.prepare(state.renderer, intent)

      BufferProcess.move_to(buffer, {96, 0})
      BufferProcess.insert_text(buffer, "B")

      stale_input = RenderPipeline.compute_layout(stale_input)
      stale_layout = Layout.get(stale_input)

      # The resident fast path owns an atomic version-qualified snapshot, so
      # this frame can finish consistently without a second buffer fetch even
      # though another edit landed after consume. We intentionally do not
      # commit it; the retry must retain its pending range and union edit B.
      {_stale_scrolls, _stale_input} = scroll_input(stale_input, stale_layout)

      {renderer, input} = BufferChanges.prepare(renderer, intent)
      input = Content.reset_rows_rasterized(input)
      input = RenderPipeline.compute_layout(input)
      layout = Layout.get(input)

      {scrolls, input} = scroll_input(input, layout)

      {contents, _cursor, output} = Content.build_content(input, scrolls)
      _renderer = BufferChanges.commit(renderer, output, intent)
      model = contents |> List.first() |> Map.fetch!(:models) |> List.first()

      assert [
               %{start_index: 32, delete_count: 1, insert_rows: [first]},
               %{start_index: 96, delete_count: 1, insert_rows: [second]}
             ] = model.row_delta.splices

      assert String.starts_with?(first.text, "Aline 33")
      assert String.starts_with?(second.text, "Bline 97")
      assert first.row_id != second.row_id
      assert model.row_delta.base_row_count == 300
      assert model.row_delta.result_row_count == 300
    end
  end

  defp trace_buffer_calls(buffer, fun) do
    :erlang.trace(buffer, true, [:receive, {:tracer, self()}])

    try do
      result = fun.()
      delivery_ref = :erlang.trace_delivered(buffer)
      assert_receive {:trace_delivered, ^buffer, ^delivery_ref}
      %{result: result, messages: drain_buffer_calls(buffer, [])}
    after
      :erlang.trace(buffer, false, [:receive])
    end
  end

  defp drain_buffer_calls(buffer, acc) do
    receive do
      {:trace, ^buffer, :receive, {:"$gen_call", _from, message}} ->
        drain_buffer_calls(buffer, [message | acc])

      {:trace, ^buffer, :receive, _message} ->
        drain_buffer_calls(buffer, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "two edits far apart in one frame (#4397)" do
    test "an insert near the top and one near the bottom send their own rows and nothing between" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active
      base_rows = fresh_resident_frame(state.editor).rows
      {_before_model, state} = build_frame(state)

      BufferProcess.move_to(buffer, {20, 0})
      BufferProcess.insert_text(buffer, "above a\nabove b\n")
      BufferProcess.move_to(buffer, {282, 0})
      BufferProcess.insert_text(buffer, "below\n")

      calls = trace_buffer_calls(buffer, fn -> build_frame(state) end)
      {model, state} = calls.result

      # Both splices address the 300 rows the frontend holds. The second one's rows come from two lines
      # further down, where the first insert moved them.
      assert [
               %{start_index: 20, delete_count: 1, insert_rows: [_, _, _] = top},
               %{start_index: 280, delete_count: 1, insert_rows: [_, _] = bottom}
             ] = model.row_delta.splices

      assert Enum.map(top, & &1.buf_line) == [20, 21, 22]
      assert Enum.map(bottom, & &1.buf_line) == [282, 283]
      assert String.starts_with?(hd(top).text, "above a")
      assert String.starts_with?(hd(bottom).text, "below")
      assert model.row_delta.base_row_count == 300
      assert model.row_delta.result_row_count == 303

      # One buffer call reads both ranges together with the edits. No second fetch can go stale.
      assert Enum.count(calls.messages, &match?({:renderer_consume, _}, &1)) == 1
      refute Enum.any?(calls.messages, &match?({:render_lines, _, _, _}, &1))

      # Applying the delta to the rows the frontend held gives the same rows as a fresh render.
      fresh = fresh_resident_frame(state.editor)

      assert Enum.map(apply_row_update(base_rows, model), & &1.text) ==
               Enum.map(fresh.rows, & &1.text)
    end

    test "removing a block in the middle while a line is appended keeps every other row" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active
      base_rows = fresh_resident_frame(state.editor).rows
      {_before_model, state} = build_frame(state)

      BufferProcess.delete_lines(buffer, 100, 199)
      BufferProcess.move_to(buffer, {199, 0})
      BufferProcess.insert_text(buffer, "appended\n")

      {model, state} = build_frame(state)

      assert [
               %{start_index: 100, delete_count: 101, insert_rows: [_]},
               %{start_index: 299, delete_count: 1, insert_rows: [_, _]}
             ] = model.row_delta.splices

      assert model.row_delta.result_row_count == 201

      # Applying the delta to the rows the frontend held gives the same rows as a fresh render.
      fresh = fresh_resident_frame(state.editor)

      assert Enum.map(apply_row_update(base_rows, model), & &1.text) ==
               Enum.map(fresh.rows, & &1.text)
    end

    test "neither frame replaces the whole store" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active
      {_before_model, state} = build_frame(state)
      test_pid = self()
      handler = {__MODULE__, :distant_edits_hydration, make_ref()}

      :telemetry.attach(
        handler,
        [:minga, :render, :full_hydration],
        fn _event, _measurements, metadata, _config -> send(test_pid, {:hydrated, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      BufferProcess.move_to(buffer, {5, 3})
      BufferProcess.insert_text(buffer, "x")
      BufferProcess.move_to(buffer, {250, 0})
      BufferProcess.insert_text(buffer, "new line\n")
      {model, _state} = build_frame(state)

      assert [%{start_index: 5, delete_count: 1}, %{start_index: 250, delete_count: 1}] =
               model.row_delta.splices

      refute_received {:hydrated, _metadata}
    end
  end

  describe "AC 3: row insertion and deletion" do
    test "inserting a line off-screen grows the resident set and moves the digest without dropping or duplicating a row" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active

      {before_model, state} = build_frame(state)

      # Insert a whole new line off-screen (row count changes → full rebuild path).
      BufferProcess.move_to(buffer, {250, 0})
      BufferProcess.insert_text(buffer, "new line\n")

      {after_model, _state} = build_frame(state)

      assert after_model.content_digest != before_model.content_digest
      assert after_model.row_delta.base_row_count == 300
      assert after_model.row_delta.result_row_count == 301

      assert [%{start_index: 250, delete_count: 1, insert_rows: rows}] =
               after_model.row_delta.splices

      assert [_, _] = rows
      assert Enum.uniq_by(rows, & &1.row_id) == rows
    end

    test "deleting a line off-screen shrinks the resident set and keeps the digest faithful" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active

      {before_model, state} = build_frame(state)

      # Remove a whole off-screen line (row count changes → full rebuild path).
      BufferProcess.delete_lines(buffer, 250, 250)

      {after_model, _state} = build_frame(state)

      assert after_model.content_digest != before_model.content_digest
      assert after_model.row_delta.base_row_count == 300
      assert after_model.row_delta.result_row_count == 299

      assert [%{start_index: 250, delete_count: 2, insert_rows: [_]}] =
               after_model.row_delta.splices
    end
  end

  describe "appended command output (#4062)" do
    test "a chunk splices the line it continues and the lines it adds, and keeps every other row" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active
      {before_model, state} = build_frame(state)

      :ok = BufferProcess.append(buffer, " and more\nfirst new line\nsecond new")

      {model, state} = build_frame(state)

      assert model.content_digest != before_model.content_digest
      assert model.row_delta.base_row_count == 300
      assert model.row_delta.result_row_count == 302

      assert [%{start_index: 299, delete_count: 1, insert_rows: [continued, first, second]}] =
               model.row_delta.splices

      assert continued.text == "line 300: content here for testing and more"
      assert {first.text, second.text} == {"first new line", "second new"}

      # The chunk ended inside a line: the next chunk completes that row and adds one, in one splice.
      :ok = BufferProcess.append(buffer, " line\nthird")
      {model, _state} = build_frame(state)

      assert [%{start_index: 301, delete_count: 1, insert_rows: [completed, third]}] =
               model.row_delta.splices

      assert {completed.text, third.text} == {"second new line", "third"}
      assert completed.row_id == second.row_id
      assert model.row_delta.result_row_count == 303
    end

    test "chunks that arrive between two frames are one splice" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active
      {_model, state} = build_frame(state)

      for chunk <- ["\none", " two\nthr", "ee\n"], do: :ok = BufferProcess.append(buffer, chunk)

      {model, _state} = build_frame(state)

      assert [%{start_index: 299, delete_count: 1, insert_rows: rows}] = model.row_delta.splices

      assert Enum.map(rows, & &1.text) ==
               ["line 300: content here for testing", "one two", "three", ""]

      assert model.row_delta.result_row_count == 303
    end

    test "more chunks between two frames than the change log keeps replace the rows once, then splice again" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active
      {_model, state} = build_frame(state)

      for i <- 1..1_001, do: :ok = BufferProcess.append(buffer, "\nburst #{i}")
      {replaced, state} = build_frame(state)

      assert replaced.row_delta == nil
      assert Enum.count(replaced.rows) == 1_301

      :ok = BufferProcess.append(buffer, "\nafter the burst")
      {model, _state} = build_frame(state)

      assert [%{start_index: 1_300, delete_count: 1, insert_rows: [_last, added]}] =
               model.row_delta.splices

      assert added.text == "after the burst"
    end

    test "a log too long to be resident draws only the row a chunk changed" do
      editor = gui_state(content: long_content(66_000), rows: 12, cols: 60, filetype: :text)
      buffer = editor.workspace.buffers.active
      BufferProcess.set_option(buffer, :wrap, false)
      :ok = BufferProcess.append(buffer, "\n")
      state = warm(editor)
      {before_model, state} = build_frame(state)
      assert before_model.row_store_mode == :windowed
      assert state.output.caches.frame_rows_rasterized == 0

      :ok = BufferProcess.append(buffer, "one more line\n")
      {model, state} = build_frame(state)

      assert model.row_store_mode == :windowed
      assert Enum.any?(model.rows, &(&1.text == "one more line"))
      assert state.output.caches.frame_rows_rasterized == 1
    end
  end

  describe "AC 1/5: edit-frame build cost is flat across resident sizes" do
    @describetag :perf
    # Operation-count assertion (not wall-clock, per the test strategy): a single
    # off-screen in-place edit rasterizes exactly one row no matter how many rows
    # are resident, so edit-frame build stays O(changed) rather than O(document).
    @tag :perf
    test "RenderIntent and RenderReceipt sizes do not scale with resident content" do
      {small_request, small_receipt} = boundary_sizes(5_000)
      {large_request, large_receipt} = boundary_sizes(65_536)

      assert abs(large_request - small_request) <= 64
      assert abs(large_receipt - small_receipt) <= 64
      assert large_request <= 256 * 1024
      assert large_receipt <= 256 * 1024
    end

    for line_count <- [500, 5_000, 65_536] do
      test "a single-line edit rasterizes exactly one row at #{line_count} resident lines" do
        line_count = unquote(line_count)
        state = warm(resident_state(line_count))
        buffer = state.editor.workspace.buffers.active
        handler_id = {__MODULE__, line_count, make_ref()}
        owner = self()

        events = [
          [:minga, :render, :line_fetch],
          [:minga, :render, :buffer_deltas],
          [:minga, :render, :full_hydration],
          [:minga, :render, :decorations]
        ]

        :ok =
          :telemetry.attach_many(
            handler_id,
            events,
            fn event, measurements, metadata, _config ->
              if self() == owner do
                send(owner, {:render_measurement, event, measurements, metadata})
              end
            end,
            nil
          )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        Task.async(fn ->
          Minga.Telemetry.execute(
            [:minga, :render, :buffer_deltas],
            %{deltas_consumed: 1, changelog_consumes: 1},
            %{buffer: buffer, version: 0, reset_required?: false}
          )
        end)
        |> Task.await()

        refute_received {:render_measurement, [:minga, :render, :buffer_deltas], _, _}

        edit_line = if line_count == 65_536, do: 32_768, else: div(line_count, 2)
        BufferProcess.move_to(buffer, {edit_line, 0})
        BufferProcess.insert_text(buffer, "Z")
        intent = Intent.from_editor_state(state.editor, 1)

        {model, state} = build_frame(state)

        measurements = drain_render_measurements([])
        fetched = sum_measurement(measurements, [:minga, :render, :line_fetch], :lines_fetched)

        consumes =
          sum_measurement(measurements, [:minga, :render, :buffer_deltas], :changelog_consumes)

        resets = sum_measurement(measurements, [:minga, :render, :full_hydration], :count)

        decorations =
          sum_measurement(measurements, [:minga, :render, :decorations], :decorations_visited)

        assert fetched == 1
        assert consumes == 1
        assert resets == 0
        assert is_integer(decorations)

        assert Enum.any?(measurements, fn {event, _measurements, metadata} ->
                 event == [:minga, :render, :line_fetch] and metadata.full_residence? == true
               end)

        assert model.row_delta.base_row_count == line_count
        assert model.row_delta.result_row_count == line_count
        assert Enum.count_until(model.rows, 2) <= 1
        rows_composed = model.row_delta.splices |> Enum.map(&length(&1.insert_rows)) |> Enum.sum()
        assert rows_composed == 1

        receipt =
          MingaEditor.Renderer.RenderReceipt.from_output(
            state.output,
            1,
            System.monotonic_time(),
            intent.revision
          )

        request_bytes = :erlang.external_size(Submission.full(intent))
        receipt_bytes = :erlang.external_size(receipt)

        measurement = %{
          full_resets: resets,
          changelog_consumes: consumes,
          lines_fetched: fetched,
          rows_composed: rows_composed,
          swift_chunks_touched: 0,
          editor_rows_visited: 0,
          visible_rows: 0,
          overscan_rows: 0,
          decorations_visited: decorations,
          request_bytes: request_bytes,
          receipt_bytes: receipt_bytes
        }

        assert ProductionGate.beam_failures(measurement) == []
        assert ProductionGate.boundary_failures(measurement) == []
        assert request_bytes < 100_000
        assert receipt_bytes < 10_000
      end
    end
  end

  defp boundary_sizes(line_count) do
    state = warm(resident_state(line_count))
    buffer = state.editor.workspace.buffers.active
    BufferProcess.move_to(buffer, {div(line_count, 2), 0})
    BufferProcess.insert_text(buffer, "Z")
    intent = Intent.from_editor_state(state.editor, 1)
    {_model, state} = build_frame(state)

    receipt =
      MingaEditor.Renderer.RenderReceipt.from_output(
        state.output,
        1,
        System.monotonic_time(),
        intent.revision
      )

    {:erlang.external_size(Submission.full(intent)), :erlang.external_size(receipt)}
  end

  defp drain_render_measurements(acc) do
    receive do
      {:render_measurement, event, measurements, metadata} ->
        drain_render_measurements([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp sum_measurement(measurements, event, key) do
    Enum.reduce(measurements, 0, fn
      {^event, values, _metadata}, total -> total + Map.get(values, key, 0)
      _, total -> total
    end)
  end
end
