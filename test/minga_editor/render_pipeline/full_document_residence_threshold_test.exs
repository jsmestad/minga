defmodule MingaEditor.RenderPipeline.FullDocumentResidenceThresholdTest do
  @moduledoc """
  Threshold-guard and residence-emit tests for full-document row residence (#2653).

  Residence ships on by default (`:resident_store_max_lines` default 65_535). These
  tests pin the option explicitly per case (raising, lowering, or disabling it) to
  exercise the threshold boundaries. That mutation forces the module to run
  `async: false`; the option is restored after each test.
  """

  # Mutates the global Config option server (:resident_store_max_lines).
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config
  alias Minga.RenderModel.Window.ScrollPresentation
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    original_lines = Config.get(:resident_store_max_lines)

    on_exit(fn ->
      Config.set(:resident_store_max_lines, original_lines)
    end)

    :ok
  end

  defp run_through_scroll(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, _state} = Scroll.scroll_windows(state, layout)
    scrolls
  end

  defp run_through_scroll_with_state(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {scrolls, state}
  end

  defp warm(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {_contents, _cursor, state} = Content.build_content(state, scrolls)
    state
  end

  defp build_model(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {contents, _cursor, _state} = Content.build_content(state, scrolls)
    [wc | _] = contents
    List.first(wc.models)
  end

  defp scrolled_state(top, opts \\ []) do
    state = gui_state(rows: 10, cols: 40, content: long_content(500))

    if opts[:wrap] do
      BufferProcess.set_option(state.workspace.buffers.active, :wrap, true)
    end

    win_id = state.workspace.windows.active
    window = Map.fetch!(state.workspace.windows.map, win_id)
    window = Window.set_viewport(window, Viewport.put_top(window.viewport, top))
    put_in(state.workspace.windows.map[win_id], window)
  end

  test "a buffer over the configured line threshold falls back to windowed emit" do
    Config.set(:resident_store_max_lines, 100)

    [{_win_id, scroll}] = Map.to_list(run_through_scroll(scrolled_state(250)))

    assert scroll.full_residence == false
    assert Enum.count(scroll.lines) < 500
  end

  test "a buffer under the configured line threshold stays fully resident" do
    Config.set(:resident_store_max_lines, 100_000)

    # First-paint-then-promote (#2679): residence engages on the second frame.
    state = warm(scrolled_state(250))
    [{_win_id, scroll}] = Map.to_list(run_through_scroll(state))

    assert scroll.full_residence == true
    assert Enum.count(scroll.lines) == 500
  end

  test "residence emits every document row regardless of scroll position" do
    Config.set(:resident_store_max_lines, 100_000)

    # First-paint-then-promote (#2679): warm one frame so residence is promoted.
    model = build_model(warm(scrolled_state(250)))
    presentation = ScrollPresentation.from_window(model)

    # The window carries every document row, in buffer order from line 0 to 499.
    assert Enum.map(model.rows, & &1.buf_line) == Enum.to_list(0..499)
    assert presentation.overscan_start_line == 0
    assert presentation.overscan_end_line == 500

    # The gutter stays viewport-windowed so per-frame chrome bytes stay bounded;
    # only the row set becomes resident.
    assert Enum.count(model.gutter.entries) < 100
  end

  test "a wrapped buffer opts out of residence even when it is enabled" do
    Config.set(:resident_store_max_lines, 100_000)

    [{_win_id, scroll}] = Map.to_list(run_through_scroll(scrolled_state(250, wrap: true)))

    assert scroll.full_residence == false
    assert Enum.count(scroll.lines) < 500
  end

  test "toggling residence mid-session forces a full refresh via the render reset fingerprint" do
    # Residence is on by default, so pin it off first to establish a windowed
    # baseline fingerprint before toggling it on below.
    Config.set(:resident_store_max_lines, 0)
    state = scrolled_state(250)

    # Warm up with residence disabled to establish a baseline fingerprint in the
    # window's render cache.
    state = warm(state)

    # Second frame should be stable (no full refresh).
    {scrolls, state} = run_through_scroll_with_state(state)
    [{_win_id, scroll}] = Map.to_list(scrolls)
    assert scroll.full_refresh == false
    assert scroll.full_residence == false

    # Enable residence. First-paint-then-promote (#2679): the first frame after
    # enabling stays windowed (arming promotion), so it neither becomes resident
    # nor forces a refresh yet.
    Config.set(:resident_store_max_lines, 100_000)
    {scrolls, state} = run_through_scroll_with_state(state)
    [{_win_id, arming}] = Map.to_list(scrolls)
    assert arming.full_residence == false

    # The next frame promotes to residence. The fingerprint change forces
    # full_refresh: true so no :patch frame diffs across differently-sized stores.
    {scrolls, _state} = run_through_scroll_with_state(state)
    [{_win_id, scroll}] = Map.to_list(scrolls)
    assert scroll.full_refresh == true
    assert scroll.full_residence == true
  end

  test "gutter stays viewport-bounded under residence even when scrolled deep" do
    Config.set(:resident_store_max_lines, 100_000)

    # First-paint-then-promote (#2679): warm one frame so residence is promoted.
    model = build_model(warm(scrolled_state(400)))
    visible = model.geometry.viewport.rows

    assert Enum.count(model.rows) == 500
    assert Enum.count(model.gutter.entries) <= visible * 3
  end
end
