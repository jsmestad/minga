defmodule MingaEditor.RenderPipeline.ScrollSeqWritebackTest do
  @moduledoc """
  Regression tests for the async render writeback path (#2661).

  In production the renderer runs asynchronously: the editor casts a snapshot,
  the pipeline mutates a *copy* of the windows, and `apply_renderer_writeback/2`
  merges only renderer-owned state back onto the live window via
  `MingaEditor.State.merge_renderer_window/2` (which copies the render cache and
  nothing else). This is the path the earlier synchronous-render tests missed.

  These tests thread the free-scroll state through that merge to prove:

  * `resident` and `scroll_seq` live in the render cache and survive the writeback;
  * `scroll_seq` stays monotonic across frames (its baseline is written back too);
  * a wheel echo does not advance `scroll_seq`, but a later jump does;
  * `scroll_echo_top` is editor-owned and is NOT clobbered by a stale writeback.

  The "pipeline step" here is the exact pair of render-cache mutations that
  `MingaEditor.RenderPipeline.BufferPrefetch` performs for this feature
  (`settle_scroll_seq/1` then `set_resident/2`) applied to the snapshot window,
  rather than the full seven-stage pipeline; that keeps the frame loop
  deterministic (no cursor-follow re-scroll) while still exercising the real
  writeback merge that dropped the state.
  """

  # Mutates the global Config option server (:resident_store_max_lines) and the
  # shell registry, so run serially and restore.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Shell.Identity, as: ShellIdentity
  alias MingaEditor.Shell.Registry, as: ShellRegistry
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    original = Config.get(:resident_store_max_lines)
    Config.set(:resident_store_max_lines, 1_000_000)
    on_exit(fn -> Config.set(:resident_store_max_lines, original) end)
    :ok
  end

  test "residence and scroll_seq survive the async writeback and scroll_seq is monotonic" do
    state = resident_gui_state()
    win_id = state.workspace.windows.active

    # Frame 1: establishes the scroll_seq baseline and records residence. Both
    # come back on the render cache through merge_renderer_window.
    state = render_writeback(state)
    assert Window.resident?(live_window(state, win_id))
    assert Window.scroll_seq(live_window(state, win_id)) == 0

    # A wheel report on the resident GUI window moves the viewport and records the
    # committed top as the free-scroll echo top (real input path).
    state = MingaEditor.Mouse.handle_scroll_batch(state, win_id, 2, :down)
    wheel_top = live_window(state, win_id).viewport.top
    assert wheel_top > 0
    assert live_window(state, win_id).scroll_echo_top == wheel_top

    # Frame 2: the committed top equals the echo top, so scroll_seq does not
    # advance, and residence + echo top are still intact after the writeback.
    state = render_writeback(state)
    assert Window.scroll_seq(live_window(state, win_id)) == 0
    assert Window.resident?(live_window(state, win_id))
    assert live_window(state, win_id).scroll_echo_top == wheel_top

    # A BEAM-initiated jump moves the top to a value that is neither the previous
    # committed top nor the echo top, without touching scroll_echo_top.
    state = put_viewport_top(state, win_id, 40)

    # Frame 3: the jump advances scroll_seq exactly once. The counter is genuinely
    # monotonic because both it and its baseline round-tripped through the render
    # cache writeback rather than recomputing from a stale base.
    state = render_writeback(state)
    assert Window.scroll_seq(live_window(state, win_id)) == 1
  end

  test "a stale async writeback does not clobber the editor-owned scroll_echo_top" do
    state = resident_gui_state()
    win_id = state.workspace.windows.active

    # Snapshot taken while the echo top was 3 (what an in-flight render would carry).
    state = put_scroll_echo_top(state, win_id, 3)
    snapshot = Input.from_editor_state(state)

    # The editor keeps handling input while that render is in flight: a newer wheel
    # advances the live echo top to 9.
    state = put_scroll_echo_top(state, win_id, 9)

    # The in-flight render completes and writes back its (older) windows.
    rendered_windows = render_windows_from_snapshot(snapshot, win_id)
    state = EditorState.apply_renderer_writeback(state, writeback(state, rendered_windows))

    # The renderer-owned residence flag came through on the render cache, but the
    # editor-owned echo top kept the newer live value (merge_renderer_window only
    # copies the render cache, so the stale 3 cannot overwrite the live 9).
    assert Window.resident?(live_window(state, win_id))
    assert live_window(state, win_id).scroll_echo_top == 9
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp resident_gui_state do
    state = gui_state(content: long_content(300), rows: 12, cols: 60, filetype: :text)
    BufferProcess.set_option(state.workspace.buffers.active, :wrap, false)
    state
  end

  # One production-shaped async frame: snapshot the live state, run the two
  # render-cache mutations BufferPrefetch performs for this feature on the
  # snapshot window, then merge the result back via the real writeback path.
  defp render_writeback(state) do
    win_id = state.workspace.windows.active
    snapshot = Input.from_editor_state(state)
    rendered_windows = render_windows_from_snapshot(snapshot, win_id)
    EditorState.apply_renderer_writeback(state, writeback(state, rendered_windows))
  end

  defp render_windows_from_snapshot(%Input{} = snapshot, win_id) do
    windows = snapshot.workspace.windows

    rendered_win =
      windows.map
      |> Map.fetch!(win_id)
      |> Window.settle_scroll_seq()
      |> Window.set_resident(true)

    %{windows | map: Map.put(windows.map, win_id, rendered_win)}
  end

  defp writeback(state, windows) do
    shell_id = EditorState.active_shell_id(state)
    entry = ShellRegistry.get(shell_id)

    %{
      caches: state.caches,
      layout: state.layout,
      focus_tree: state.focus_tree,
      shell_id: shell_id,
      shell_identity: ShellIdentity.new(entry),
      shell_state: state.shell_state,
      windows: windows,
      message_store: state.message_store,
      keyframe?: false,
      frame_seq: 1
    }
  end

  defp live_window(state, win_id), do: Map.fetch!(state.workspace.windows.map, win_id)

  defp put_viewport_top(state, win_id, top) do
    EditorState.update_window(state, win_id, fn window ->
      %{window | viewport: %{window.viewport | top: top}}
    end)
  end

  defp put_scroll_echo_top(state, win_id, top) do
    EditorState.update_window(state, win_id, &Window.mark_scroll_echo(&1, top))
  end
end
