defmodule MingaEditor.RenderPipeline.ResidentIncrementalTest do
  @moduledoc "End-to-end checks for the incremental full-document residence build (#2658)."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.RenderModel.Window.ContentDigest
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.State, as: EditorState

  import MingaEditor.RenderPipeline.TestHelpers

  # Builds the active window's semantic model for one frame, returning the model
  # and the state carrying the updated resident build cache into the next frame.
  # Resets the per-frame rasterized counter so `Content.rows_rasterized/1` reads
  # only this frame's freshly composed rows.
  defp build_frame(state) do
    state = Content.reset_rows_rasterized(state)
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {contents, _cursor, state} = Content.build_content(state, scrolls)
    model = contents |> List.first() |> Map.fetch!(:models) |> List.first()
    {model, state}
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
      assert model.content_digest == ContentDigest.of_rows(model.rows)
      assert Enum.map(model.rows, & &1.buf_line) == Enum.to_list(0..299)
    end

    test "an off-screen single-line edit splices one row and the digest tracks it" do
      state = warm(resident_state(300))
      buffer = state.workspace.buffers.active

      {before_model, state} = build_frame(state)
      before_digest = before_model.content_digest
      before_hash = row_hash(before_model, 250)

      # Edit an off-screen line (viewport shows the top; line 250 is resident but
      # far below the fold).
      BufferProcess.move_to(buffer, {250, 0})
      BufferProcess.insert_text(buffer, "Z")

      {after_model, _state} = build_frame(state)

      # The edited resident row's content changed, and the digest moved with it,
      # so the frame-emit gate fires rather than dropping a needed frame.
      assert row_hash(after_model, 250) != before_hash
      assert after_model.content_digest != before_digest
      # The digest is still a faithful fingerprint of the whole (spliced) row set.
      assert after_model.content_digest == ContentDigest.of_rows(after_model.rows)
      # No row was dropped or duplicated by the splice.
      assert Enum.map(after_model.rows, & &1.buf_line) == Enum.to_list(0..299)
    end

    test "a pure cursor move reuses the resident rows and leaves the digest unchanged" do
      state = warm(resident_state(300))
      buffer = state.workspace.buffers.active

      {before_model, state} = build_frame(state)
      BufferProcess.move_to(buffer, {120, 0})
      {after_model, _state} = build_frame(state)

      assert after_model.content_digest == before_model.content_digest
      assert after_model.rows == before_model.rows
    end
  end

  describe "AC 3: row insertion and deletion" do
    test "inserting a line off-screen grows the resident set and moves the digest without dropping or duplicating a row" do
      state = warm(resident_state(300))
      buffer = state.workspace.buffers.active

      {before_model, state} = build_frame(state)

      # Insert a whole new line off-screen (row count changes → full rebuild path).
      BufferProcess.move_to(buffer, {250, 0})
      BufferProcess.insert_text(buffer, "new line\n")

      {after_model, _state} = build_frame(state)

      assert length(after_model.rows) == length(before_model.rows) + 1
      assert after_model.content_digest != before_model.content_digest
      assert after_model.content_digest == ContentDigest.of_rows(after_model.rows)
      # Every row id is distinct: no duplicate/dropped frame-emit under insert.
      row_ids = Enum.map(after_model.rows, & &1.row_id)
      assert length(Enum.uniq(row_ids)) == length(row_ids)
      assert Enum.map(after_model.rows, & &1.buf_line) == Enum.to_list(0..300)
    end

    test "deleting a line off-screen shrinks the resident set and keeps the digest faithful" do
      state = warm(resident_state(300))
      buffer = state.workspace.buffers.active

      {before_model, state} = build_frame(state)

      # Remove a whole off-screen line (row count changes → full rebuild path).
      BufferProcess.delete_lines(buffer, 250, 250)

      {after_model, _state} = build_frame(state)

      assert length(after_model.rows) == length(before_model.rows) - 1
      assert after_model.content_digest != before_model.content_digest
      assert after_model.content_digest == ContentDigest.of_rows(after_model.rows)
      assert Enum.map(after_model.rows, & &1.buf_line) == Enum.to_list(0..298)
    end
  end

  describe "AC 1/5: edit-frame build cost is flat across resident sizes" do
    @describetag :perf
    # Operation-count assertion (not wall-clock, per the test strategy): a single
    # off-screen in-place edit rasterizes exactly one row no matter how many rows
    # are resident, so edit-frame build stays O(changed) rather than O(document).
    for line_count <- [500, 5_000, 65_000] do
      test "a single-line edit rasterizes exactly one row at #{line_count} resident lines" do
        line_count = unquote(line_count)
        state = warm(resident_state(line_count))
        buffer = state.workspace.buffers.active

        edit_line = div(line_count, 2)
        BufferProcess.move_to(buffer, {edit_line, 0})
        BufferProcess.insert_text(buffer, "Z")

        {model, state} = build_frame(state)

        assert Content.rows_rasterized(state) == 1
        assert model.content_digest == ContentDigest.of_rows(model.rows)
        assert length(model.rows) == line_count
      end
    end
  end

  defp row_hash(model, buf_line) do
    model.rows
    |> Enum.find(&(&1.buf_line == buf_line))
    |> Map.fetch!(:content_hash)
  end
end
