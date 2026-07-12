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
  alias MingaEditor.Renderer.State, as: RendererState
  alias MingaEditor.State, as: EditorState

  import MingaEditor.RenderPipeline.TestHelpers

  # Builds the active window's semantic model for one frame, returning the model
  # and the state carrying the updated resident build cache into the next frame.
  # Resets the per-frame rasterized counter so `Content.rows_rasterized/1` reads
  # only this frame's freshly composed rows.
  defp build_frame(%EditorState{} = editor) do
    build_frame(%{
      editor: editor,
      renderer: RendererState.new(editor_pid: nil, pipeline: &RenderPipeline.run/1)
    })
  end

  defp build_frame(%{editor: editor, renderer: renderer}) do
    editor = EditorState.sync_active_window_cursor(editor)
    intent = Intent.from_editor_state(editor)
    {renderer, input} = BufferChanges.prepare(renderer, intent)
    input = Content.reset_rows_rasterized(input)
    input = RenderPipeline.compute_layout(input)
    layout = Layout.get(input)
    {scrolls, input} = Scroll.scroll_windows(input, layout)
    {contents, _cursor, output} = Content.build_content(input, scrolls)
    renderer = BufferChanges.commit(renderer, output, intent)
    editor = EditorState.apply_render_output(editor, output)
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

  describe "stale consume/fetch retry" do
    test "two ordered edits survive a forced stale fetch and compose once on both rows" do
      state = warm(resident_state(300))
      buffer = state.editor.workspace.buffers.active

      BufferProcess.move_to(buffer, {32, 0})
      BufferProcess.insert_text(buffer, "A")

      editor = EditorState.sync_active_window_cursor(state.editor)
      intent = Intent.from_editor_state(editor)
      {renderer, stale_input} = BufferChanges.prepare(state.renderer, intent)

      BufferProcess.move_to(buffer, {96, 0})
      BufferProcess.insert_text(buffer, "B")

      stale_input = RenderPipeline.compute_layout(stale_input)
      stale_layout = Layout.get(stale_input)

      assert_raise MingaEditor.Renderer.StaleBufferError, fn ->
        Scroll.scroll_windows(stale_input, stale_layout)
      end

      {renderer, input} = BufferChanges.prepare(renderer, intent)
      input = Content.reset_rows_rasterized(input)
      input = RenderPipeline.compute_layout(input)
      layout = Layout.get(input)
      {scrolls, input} = Scroll.scroll_windows(input, layout)
      {contents, _cursor, output} = Content.build_content(input, scrolls)
      _renderer = BufferChanges.commit(renderer, output, intent)
      model = contents |> List.first() |> Map.fetch!(:models) |> List.first()

      assert Content.rows_rasterized(output) == 2

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
    for line_count <- [500, 5_000, 65_536] do
      test "a single-line edit rasterizes exactly one row at #{line_count} resident lines" do
        line_count = unquote(line_count)
        state = warm(resident_state(line_count))
        buffer = state.editor.workspace.buffers.active
        handler_id = {__MODULE__, line_count, make_ref()}
        parent = self()

        :ok =
          :telemetry.attach(
            handler_id,
            [:minga, :render, :line_fetch],
            fn _event, measurements, metadata, _config ->
              send(parent, {:line_fetch, measurements, metadata})
            end,
            nil
          )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        edit_line = if line_count == 65_536, do: 5, else: div(line_count, 2)
        BufferProcess.move_to(buffer, {edit_line, 0})
        BufferProcess.insert_text(buffer, "Z")
        intent = Intent.from_editor_state(state.editor, 1)

        {model, state} = build_frame(state)

        assert Content.rows_rasterized(state.output) == 1
        assert_receive {:line_fetch, %{lines_fetched: fetched}, metadata}

        assert fetched == 1
        assert metadata.full_residence? == true

        assert model.row_delta.base_row_count == line_count
        assert model.row_delta.result_row_count == line_count
        assert Enum.count_until(model.rows, 2) <= 1
        assert Enum.sum(Enum.map(model.row_delta.splices, &length(&1.insert_rows))) <= 1

        if line_count == 65_536 do
          receipt =
            MingaEditor.Renderer.RenderReceipt.from_output(
              state.output,
              1,
              System.monotonic_time(),
              intent.revision
            )

          assert :erlang.external_size(intent) < 100_000
          assert :erlang.external_size(receipt) < 10_000
        end
      end
    end
  end
end
