defmodule MingaEditor.RenderPipeline.MixedWheelGeometryTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias Minga.Core.WrapMap
  alias Minga.Editing.Fold.Range, as: FoldRange
  alias Minga.Core.WidthOracle.Monospace
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
  alias MingaEditor.Layout
  alias MingaEditor.Mouse
  alias MingaEditor.RenderModel.Window.SourceOffsetMap
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.BufferPrefetch
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.Renderer.BufferChanges
  alias MingaEditor.Renderer.RenderReceipt
  alias MingaEditor.Renderer.MixedLayout
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.Renderer.State, as: RendererState
  alias MingaEditor.Renderer.TextInteractionIndex
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Renderer.TextPresentation
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Render, as: EditorRender
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowFocus

  import MingaEditor.RenderPipeline.TestHelpers, only: [gui_state: 1]

  @measurements [{WrapMap, :compute, 3}, {WrapMap, :count_rows, 3}, {SourceOffsetMap, :new, 5}]

  test "wheel and render reuse an oversized line's exact geometry with a closed fold offscreen" do
    text = String.duplicate("0123456789ABC", 769)
    tail = Enum.map_join(1..30, "\n", fn _ -> "short" end)
    editor = gui_state(content: text <> "\n" <> tail, rows: 8, cols: 26, filetype: :text)
    buffer = editor.workspace.buffers.active
    id = editor.workspace.windows.active
    assert {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
    assert {:ok, false} = BufferProcess.set_option(buffer, :linebreak, false)
    assert {:ok, :none} = BufferProcess.set_option(buffer, :line_numbers, :none)

    window = editor.workspace.windows.map[id]
    window = window |> Window.set_fold_ranges([FoldRange.new!(3, 30)]) |> Window.fold_at(3)

    workspace =
      SessionState.set_windows(
        editor.workspace,
        Windows.replace_window(editor.workspace.windows, id, window)
      )

    editor = RenderPipeline.compute_layout(%{editor | workspace: workspace})
    renderer = RendererState.new(editor_pid: nil, require_ack?: false)
    {initial, editor, renderer, initial_presentation} = publish_frame(editor, renderer)
    assert initial.row_store_mode == :windowed
    assert %{top: 0, visual_row_offset: 0, cols: wide} = initial.geometry.viewport
    {wide_basis, counts} = TextPresentation.windowed_wrap_counts(initial_presentation)
    total = div(byte_size(text) + wide - 1, wide)
    assert counts == %{0 => total, 1 => 1, 2 => 1}

    session = :trace.session_create(:mixed_wheel_geometry, buffer, [])

    try do
      assert 1 = :trace.process(session, self(), true, [:call])

      {editor, renderer} =
        Enum.reduce(1..3, {editor, renderer}, fn offset, {editor, renderer} ->
          {editor, wheel_measurements} =
            count_measurements(session, fn -> Mouse.handle_scroll_batch(editor, id, 1, :down) end)

          assert wheel_measurements == [0, 0]

          assert Viewport.vertical_anchor(editor.workspace.windows.map[id].viewport) ==
                   {0, offset}

          {{frame, editor, renderer, presentation}, paint_measurements} =
            count_measurements(session, fn -> publish_frame(editor, renderer) end)

          assert paint_measurements == [0, 0]
          assert TextPresentation.windowed_wrap_counts(presentation) == {wide_basis, counts}
          assert_frame(frame, text, offset, wide)
          {editor, renderer}
        end)

      assert BufferProcess.cursor(buffer) == {0, 0}

      assert {:ok, :absolute} = BufferProcess.set_option(buffer, :line_numbers, :absolute)

      {editor, [wheel_wraps, _]} =
        count_measurements(session, fn -> Mouse.handle_scroll_batch(editor, id, 1, :down) end)

      assert wheel_wraps > 0

      {{reflowed, editor, renderer, presentation}, [paint_wraps, paint_projections]} =
        count_measurements(session, fn -> publish_frame(editor, renderer) end)

      assert paint_wraps > 0
      assert paint_projections > 0
      narrow = reflowed.geometry.viewport.cols
      assert narrow < wide
      assert_frame(reflowed, text, 4, narrow)
      {narrow_basis, _counts} = TextPresentation.windowed_wrap_counts(presentation)
      reader = RendererState.text_interaction_reader(renderer)
      version = presentation.source_version
      assert Reader.windowed_wrap_counts(reader, id, buffer, version, wide_basis) == %{}

      edited_text = String.replace(text, "ABC", "XYZ")
      assert :ok = BufferProcess.replace_lines(buffer, 0, 0, edited_text)
      cursor_after_edit = BufferProcess.cursor(buffer)

      {editor, [wheel_wraps, _]} =
        count_measurements(session, fn -> Mouse.handle_scroll_batch(editor, id, 1, :down) end)

      assert wheel_wraps > 0

      {{edited, _editor, _renderer, presentation}, [paint_wraps, paint_projections]} =
        count_measurements(session, fn -> publish_frame(editor, renderer) end)

      assert paint_wraps > 0
      assert paint_projections > 0
      assert presentation.source_version > version
      assert Reader.windowed_wrap_counts(reader, id, buffer, version, narrow_basis) == %{}
      assert_frame(edited, edited_text, 5, narrow)
      assert BufferProcess.cursor(buffer) == cursor_after_edit
    after
      :trace.session_destroy(session)
    end
  end

  test "a same-version inline decoration change invalidates the cached mixed EOF before wheel motion" do
    editor = gui_state(content: "a\nb\nc\nd\ne\nf", filetype: :text)
    buffer = editor.workspace.buffers.active
    id = editor.workspace.windows.active
    folds = FoldMap.new()
    viewport = Viewport.new(2, 10, 0) |> Viewport.put_top_visual(5, 5, 8)
    geometry = {10, %Monospace{}, {0, 0}}

    BufferProcess.add_virtual_text(buffer, {0, 0},
      placement: :above,
      segments: [{"marker", Face.new()}]
    )

    inline_id =
      BufferProcess.add_virtual_text(buffer, {5, 0},
        placement: :inline,
        segments: [{String.duplicate("x", 70), Face.new()}]
      )

    before = BufferProcess.render_snapshot(buffer, 0, 0)

    assert {:ok, page, _, _, _} =
             MixedLayout.page(
               buffer,
               before,
               {folds, before.decorations},
               viewport,
               geometry,
               0,
               nil
             )

    identity = TextPresentation.mixed_wrap_identity(page, %{}, :test)
    presentation = TextPresentation.new(id, buffer, before.version, identity, {:windowed, []}, 1)
    index = TextInteractionIndex.publish_current(TextInteractionIndex.new(), presentation)
    wheel_index = {TextInteractionIndex.reader(index), id}

    assert :ok = BufferProcess.remove_virtual_text(buffer, inline_id)

    assert {:layout_changed, verified} =
             MixedLayout.scroll(
               buffer,
               before,
               {folds, before.decorations},
               viewport,
               geometry,
               -1,
               nil,
               wheel_index
             )

    assert verified.version == before.version

    assert {:ok, fresh, false} =
             MixedLayout.scroll(
               buffer,
               verified,
               {folds, verified.decorations},
               viewport,
               geometry,
               -1,
               nil,
               wheel_index
             )

    assert Viewport.vertical_anchor(fresh) == {3, 0}
  end

  test "following a cursor onto a continuation reuses the complete decorated source group" do
    buffer = start_supervised!({BufferProcess, content: "éabcd"})

    BufferProcess.add_virtual_text(buffer, {0, 1},
      segments: [{"λ", Face.new()}],
      placement: :inline
    )

    before = BufferProcess.render_snapshot(buffer, 0, 0)
    assert {:ok, initial, viewport, _, []} = follow_page(buffer, before)
    assert initial.source_fetch_count == 1
    assert Viewport.vertical_anchor(viewport) == {0, 0}
    presentation = retain_mixed_page(buffer, before, initial)

    # The source cursor is still before the raw wrap edge. Its start affinity
    # puts it after the inline text, exactly at the composed continuation start.
    assert :ok = BufferProcess.move_to(buffer, {0, 2})
    moved = BufferProcess.render_snapshot(buffer, 0, 0)
    assert moved.version == before.version

    assert {:ok, reused, viewport, _, []} = follow_page(buffer, moved, presentation)
    assert reused.source_fetch_count == 0
    assert reused.entries == [{0, {:wrapped, 1}}]
    assert Viewport.vertical_anchor(viewport) == {0, 1}

    assert :ok = BufferProcess.insert_text(buffer, "z")
    assert :stale = follow_page(buffer, moved, presentation)
  end

  test "changing the conceal reveal line invalidates retained cursor geometry" do
    buffer = start_supervised!({BufferProcess, content: "abcd\nz"})

    BufferProcess.batch_decorations(buffer, fn decorations ->
      {_id, decorations} = Decorations.add_conceal(decorations, {0, 0}, {0, 2})
      decorations
    end)

    assert :ok = BufferProcess.move_to(buffer, {0, 2})
    before = BufferProcess.render_snapshot(buffer, 0, 0)
    assert {:ok, initial, viewport, _, []} = follow_page(buffer, before)
    assert Viewport.vertical_anchor(viewport) == {0, 1}
    presentation = retain_mixed_page(buffer, before, initial)

    assert :ok = BufferProcess.move_to(buffer, {1, 0})
    assert :stale = follow_page(buffer, before, presentation)

    moved = BufferProcess.render_snapshot(buffer, 0, 0)
    assert moved.version == before.version
    assert {:ok, fresh, viewport, _, []} = follow_page(buffer, moved, presentation)
    assert fresh.source_fetch_count == 2
    assert DisplayMap.wrap_counts(fresh.sources) == %{0 => 1, 1 => 1}
    assert Viewport.vertical_anchor(viewport) == {1, 0}
  end

  defp follow_page(buffer, snapshot, presentation \\ nil) do
    MixedLayout.page(
      buffer,
      snapshot,
      {FoldMap.new(), snapshot.decorations},
      Viewport.new(1, 2, 0),
      {2, %Monospace{}, snapshot.cursor},
      {:follow, 0},
      nil,
      presentation
    )
  end

  defp retain_mixed_page(buffer, snapshot, page) do
    identity = TextPresentation.mixed_wrap_identity(page, %{}, :test)
    TextPresentation.new(1, buffer, snapshot.version, identity, {:windowed, {}}, 1)
  end

  defp assert_frame(frame, text, offset, width) do
    assert %{top: 0, visual_row_offset: 0, cols: ^width} = frame.geometry.viewport

    assert [
             %{buf_line: 0, row_type: :wrap_continuation, visual_index: ^offset, text: visible}
             | _
           ] =
             frame.rows

    assert visible == binary_part(text, width * offset, width)
    refute frame.cursor_visible
  end

  defp publish_frame(editor, renderer) do
    editor = WindowFocus.remember_active_cursor(editor)
    intent = Intent.from_editor_state(editor)
    {renderer, input} = BufferChanges.prepare(renderer, intent)
    input = input |> Content.reset_rows_rasterized() |> RenderPipeline.compute_layout()
    layout = Layout.get(input)
    {prefetched, input} = BufferPrefetch.prefetch_scrolls(input, layout)
    {scrolls, input} = Scroll.scroll_windows(input, layout, prefetched)
    {[%{models: [model]}], _, output} = Content.build_content(input, scrolls)
    renderer = BufferChanges.commit(renderer, output, intent)
    renderer = RendererState.commit_local_scroll_geometry(renderer, output)
    receipt = RenderReceipt.from_output(output, 0, 0, 0)
    editor = EditorState.integrate_synchronous_renderer_receipt(editor, receipt)
    reader = RendererState.text_interaction_reader(renderer)
    editor = %{editor | render: EditorRender.connect_renderer(editor.render, self(), reader)}
    presentation = RenderWindow.text_presentation(output.windows.map[model.window_id])
    {model, editor, renderer, presentation}
  end

  defp count_measurements(session, fun) do
    Enum.each(@measurements, fn mfa ->
      assert 1 = :trace.function(session, mfa, true, [:call_time])
    end)

    result = fun.()
    pid = self()

    [materialized_wraps, counted_wraps, projections] =
      Enum.map(@measurements, fn mfa ->
        {:call_time, calls} = :trace.info(session, mfa, :call_time)
        {^pid, count, _, _} = List.keyfind(calls, pid, 0, {pid, 0, 0, 0})
        count
      end)

    {result, [materialized_wraps + counted_wraps, projections]}
  end
end
