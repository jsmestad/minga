defmodule MingaEditor.RenderPipeline.WrappedFreeScrollTest do
  @moduledoc """
  Regression tests for wheel/trackpad free-scroll on soft-wrapped GUI windows
  (#2674, symptom B).

  The wheel path (`Mouse.handle_scroll_batch/4`) commits a new `viewport.top` on
  the live window and records it as the free-scroll echo top
  (`Window.mark_scroll_echo/2`). On wrapped active windows the render pipeline's
  `BufferPrefetch.maybe_adjust_wrapped_viewport/1` used to re-derive the emitted
  viewport from the cursor unconditionally: because the wheel does not drag the
  cursor on a wrapped window, the cursor fell above the fetched range and the
  frame re-anchored to `top: cursor_line` every frame. The emitted top never
  advanced past the cursor line, so the GUI appeared to snap back and no new
  content loaded.

  These tests drive the production-shaped async frame: snapshot the live state,
  run the real scroll stage on the snapshot copy (this is what the frontend
  receives), then merge only the render cache back (`merge_renderer_window`
  semantics). They assert the emitted top tracks the free-scrolled top, does not
  re-anchor to the cursor, and does not bump `scroll_seq` on the user's own echo.
  """

  # gui_state/1 seeds the global shell registry, so keep this serial.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Input, as: PipelineInput
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.State, as: EditorState

  import MingaEditor.RenderPipeline.TestHelpers

  # One production-shaped async frame: snapshot the live state, run the real
  # scroll stage on the snapshot copy (what the frontend receives), then merge
  # only the render cache back onto the live window (merge_renderer_window only
  # copies the render cache; the viewport is NOT written back).
  @spec render_frame(EditorState.t()) :: {EditorState.t(), map()}
  defp render_frame(state) do
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    snapshot = PipelineInput.from_editor_state(state)
    {scrolls, _out} = Scroll.scroll_windows(snapshot, layout)

    win_id = state.workspace.windows.active
    scroll = Map.fetch!(scrolls, win_id)

    state =
      EditorState.update_window(state, win_id, fn live ->
        %{live | render_cache: scroll.window.render_cache}
      end)

    trace = %{
      emitted_top: scroll.viewport.top,
      emitted_offset: scroll.viewport.visual_row_offset,
      scroll_seq: scroll.scroll_seq,
      live_top: live(state, win_id).viewport.top,
      echo_top: live(state, win_id).scroll_echo_top
    }

    {state, trace}
  end

  defp live(state, win_id), do: Map.fetch!(state.workspace.windows.map, win_id)

  defp wheel_down(state, win_id, delta),
    do: MingaEditor.Mouse.handle_scroll_batch(state, win_id, delta, :down)

  @spec build(keyword()) :: EditorState.t()
  defp build(opts) do
    wrap = Keyword.fetch!(opts, :wrap)
    rows = Keyword.get(opts, :rows, 17)
    cols = Keyword.get(opts, :cols, 100)

    # Long lines so each logical line wraps into several visual rows at cols=100.
    content =
      Enum.map_join(1..200, "\n", fn i ->
        "line #{i} " <> String.duplicate("word ", 30)
      end)

    state = gui_state(content: content, rows: rows, cols: cols, filetype: :text)
    BufferProcess.set_option(state.workspace.buffers.active, :wrap, wrap)
    BufferProcess.move_to(state.workspace.buffers.active, {0, 0})
    state
  end

  describe "wrapped free-scroll (#2674 symptom B)" do
    test "the emitted viewport advances with the wheel and does not snap back to the cursor" do
      state = build(wrap: true)
      win_id = state.workspace.windows.active

      # Warm frame establishes the scroll_seq baseline.
      {state, warm} = render_frame(state)
      assert warm.emitted_top == 0
      assert warm.scroll_seq == 0

      # Six downward wheel batches, rendering a production-shaped frame between
      # each, exactly like the live interleaving.
      {_state, tops} =
        Enum.reduce(1..6, {state, []}, fn _i, {st, acc} ->
          st = wheel_down(st, win_id, 3)
          {st, t} = render_frame(st)

          # The frame the frontend receives tracks the free-scrolled top: it does
          # not re-anchor to the cursor line (0), and matches the echo top.
          assert t.emitted_top == t.live_top,
                 "emitted top #{t.emitted_top} should equal free-scrolled live top #{t.live_top}"

          assert t.emitted_top == t.echo_top,
                 "emitted top #{t.emitted_top} should equal echo top #{t.echo_top} (no re-anchor)"

          assert t.emitted_top > 0, "must not snap back to cursor line 0"

          {st, [t.emitted_top | acc]}
        end)

      # The emitted top strictly advances and stays advanced across frames.
      advancing = Enum.reverse(tops)

      assert advancing
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [prev, next] -> next > prev end),
             "emitted tops must strictly increase across frames, got #{inspect(advancing)}"
    end

    test "scroll_seq does not bump on the user's own echoed scrolls under wrap" do
      state = build(wrap: true)
      win_id = state.workspace.windows.active

      {state, warm} = render_frame(state)
      baseline = warm.scroll_seq

      state =
        Enum.reduce(1..6, state, fn _i, st ->
          st = wheel_down(st, win_id, 3)
          {st, t} = render_frame(st)

          assert t.scroll_seq == baseline,
                 "scroll_seq must not advance on an echoed wheel scroll (#2668 contract)"

          st
        end)

      # A BEAM-initiated jump to a top that is neither the previous committed top
      # nor the echoed top still advances scroll_seq exactly once.
      state =
        EditorState.update_window(state, win_id, fn w ->
          %{w | viewport: %{w.viewport | top: 120, visual_row_offset: 0}}
        end)

      # Move the cursor to the jump target so cursor-follow keeps it, then let the
      # scroll gesture decay by clearing the velocity/detach state (gesture end).
      BufferProcess.move_to(state.workspace.buffers.active, {120, 0})

      state =
        EditorState.update_window(state, win_id, fn w ->
          %{
            w
            | scroll_velocity: MingaEditor.Window.ScrollVelocity.new(),
              scroll_detach_cursor: nil
          }
        end)

      {_state, jump} = render_frame(state)
      assert jump.scroll_seq == baseline + 1
    end

    test "cursor-follow still re-anchors a wrapped window when the cursor moves off-screen" do
      # No wheel gesture: fresh (idle) scroll velocity means scroll_follow_cursor?
      # returns true, so the cursor-anchoring path must still run under wrap.
      state = build(wrap: true)
      win_id = state.workspace.windows.active

      # Simulate a settled scroll far below, with the cursor left at line 0.
      state =
        EditorState.update_window(state, win_id, fn w ->
          %{w | viewport: %{w.viewport | top: 60, visual_row_offset: 0}}
        end)

      {_state, t} = render_frame(state)

      # Cursor at line 0 is above the viewport, so the frame re-anchors up toward
      # the cursor rather than staying at the free-scroll position.
      assert t.emitted_top < 60
      assert t.emitted_top <= 5
    end
  end

  describe "non-wrapped parity control" do
    test "the emitted viewport tracks the wheel without snap-back (wrap off)" do
      state = build(wrap: false)
      win_id = state.workspace.windows.active

      {state, _warm} = render_frame(state)

      Enum.reduce(1..6, state, fn _i, st ->
        st = wheel_down(st, win_id, 3)
        {st, t} = render_frame(st)
        assert t.emitted_top == t.live_top
        assert t.emitted_top == t.echo_top
        assert t.scroll_seq == 0
        st
      end)
    end
  end
end
