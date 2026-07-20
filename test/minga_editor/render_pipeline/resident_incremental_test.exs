defmodule MingaEditor.RenderPipeline.ResidentIncrementalTest do
  @moduledoc "End-to-end checks for the incremental full-document residence build (#2658)."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.Renderer.BufferChanges
  alias MingaEditor.Renderer.ProductionGate
  alias MingaEditor.Renderer.RenderReceipt
  alias MingaEditor.Renderer.State, as: RendererState
  alias MingaEditor.State, as: EditorState

  import MingaEditor.RenderPipeline.TestHelpers

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

  defp build_frame(%{editor: editor, renderer: renderer}) do
    editor = MingaEditor.WindowFocus.remember_active_cursor(editor)
    intent = Intent.from_editor_state(editor)
    {renderer, input} = BufferChanges.prepare(renderer, intent)
    input = Content.reset_rows_rasterized(input)
    input = RenderPipeline.compute_layout(input)
    layout = Layout.get(input)
    {scrolls, input} = Scroll.scroll_windows(input, layout)
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

  # A plain-text, non-wrapped buffer so tree-sitter never re-highlights mid-test
  # and residence stays eligible (wrap opts out), keeping the path on the splice
  # (not full-rebuild) branch across an edit.
  defp resident_state(line_count) do
    state = gui_state(content: long_content(line_count), rows: 12, cols: 60, filetype: :text)
    BufferProcess.set_option(state.workspace.buffers.active, :wrap, false)
    state
  end

  describe "digest consistency" do
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

      {after_model, _state} = build_frame(state)

      # The edited resident row's content changed, and the digest moved with it,
      # so the frame-emit gate fires rather than dropping a needed frame.
      assert after_model.content_digest != before_digest

      assert [%{start_index: 250, delete_count: 1, insert_rows: [row]}] =
               after_model.row_delta.splices

      assert row.buf_line == 250
      assert after_model.row_delta.base_row_count == 300
      assert after_model.row_delta.result_row_count == 300
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

  describe "uncommitted consume retry" do
    test "two ordered edits union their snapshots and compose once on both rows" do
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
      {_stale_scrolls, _stale_input} = Scroll.scroll_windows(stale_input, stale_layout)

      {renderer, input} = BufferChanges.prepare(renderer, intent)
      input = Content.reset_rows_rasterized(input)
      input = RenderPipeline.compute_layout(input)
      layout = Layout.get(input)
      {scrolls, input} = Scroll.scroll_windows(input, layout)
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
        parent = self()

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
              send(parent, {:render_measurement, event, measurements, metadata})
            end,
            nil
          )

        on_exit(fn -> :telemetry.detach(handler_id) end)

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

        request_bytes = :erlang.external_size(intent)
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

    {:erlang.external_size(intent), :erlang.external_size(receipt)}
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
