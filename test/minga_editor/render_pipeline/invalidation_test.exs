defmodule MingaEditor.RenderPipeline.InvalidationTest do
  @moduledoc """
  Tests for the first-class Stage 1 (Invalidation) output struct
  introduced as the foundation for the dirty-tracking work in #1431.
  """

  # async: false — `sanity_mode?/0` test mutates `MINGA_RENDER_SANITY` env var
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Invalidation
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.RenderPipeline.WindowDirty
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers

  describe "Invalidation struct" do
    test "default is full_redraw with empty per-window and chrome maps" do
      inv = %Invalidation{}
      assert inv.full_redraw == true
      assert inv.windows == %{}
      assert inv.chrome_regions == nil
      assert inv.global_reasons == []
    end

    test "full_redraw/1 builds a struct with reasons attached" do
      inv = Invalidation.full_redraw([:resize, :theme_changed])
      assert inv.full_redraw == true
      assert inv.global_reasons == [:resize, :theme_changed]
      assert MapSet.size(inv.chrome_regions) == 0
    end

    test "sanity_mode?/0 reads the MINGA_RENDER_SANITY env var" do
      System.delete_env("MINGA_RENDER_SANITY")
      refute Invalidation.sanity_mode?()

      System.put_env("MINGA_RENDER_SANITY", "1")
      assert Invalidation.sanity_mode?()

      System.put_env("MINGA_RENDER_SANITY", "0")
      refute Invalidation.sanity_mode?()

      System.delete_env("MINGA_RENDER_SANITY")
    end
  end

  describe "from_input/2" do
    test "marks a previously rendered window dirty when horizontal scroll changes" do
      state = base_state(content: "hello world") |> run_pipeline()
      win_id = state.workspace.windows.active
      assert_receive {:"$gen_cast", {:send_commands, _commands}}

      scrolled_window =
        state.workspace.windows.map
        |> Map.fetch!(win_id)
        |> Window.scroll_horizontal(4)

      state = put_in(state.workspace.windows.map[win_id], scrolled_window)
      input = state |> Input.from_editor_state() |> Layout.put()
      invalidation = Invalidation.from_input(input, Layout.get(input))

      assert Invalidation.window_dirty(invalidation, win_id).mode == :all
      assert Invalidation.window_dirty(invalidation, win_id).reason == :context_changed
    end

    test "marks a previously rendered window dirty when vertical scroll changes" do
      state = base_state(content: long_content(20)) |> run_pipeline()
      win_id = state.workspace.windows.active
      assert_receive {:"$gen_cast", {:send_commands, _commands}}

      scrolled_window =
        state.workspace.windows.map
        |> Map.fetch!(win_id)
        |> Window.scroll_viewport(1, 20)

      state = put_in(state.workspace.windows.map[win_id], scrolled_window)
      input = state |> Input.from_editor_state() |> Layout.put()
      invalidation = Invalidation.from_input(input, Layout.get(input))

      assert Invalidation.window_dirty(invalidation, win_id).mode == :all
      assert Invalidation.window_dirty(invalidation, win_id).reason == :context_changed
    end

    test "marks a previously rendered window dirty when content rect changes" do
      state = base_state(content: long_content(20)) |> run_pipeline()
      win_id = state.workspace.windows.active
      assert_receive {:"$gen_cast", {:send_commands, _commands}}

      cached_rect = Map.fetch!(state.workspace.windows.map, win_id).render_cache.last_content_rect
      resized_viewport = %{state.terminal_viewport | rows: state.terminal_viewport.rows - 1}
      state = %{state | terminal_viewport: resized_viewport} |> Layout.invalidate()
      input = state |> Input.from_editor_state() |> Layout.put()
      layout = Layout.get(input)

      refute Map.fetch!(layout.window_layouts, win_id).content == cached_rect

      invalidation = Invalidation.from_input(input, layout)

      assert Invalidation.window_dirty(invalidation, win_id).mode == :all
      assert Invalidation.window_dirty(invalidation, win_id).reason == :context_changed
    end

    test "marks a previously rendered window dirty when buffer dirty flag changes" do
      {state, _layout} = rendered_state(content: "hello world")
      win_id = state.workspace.windows.active
      state = normalize_cached_decorations_version(state, win_id)
      input = state |> Input.from_editor_state() |> Layout.put()
      layout = Layout.get(input)

      assert Invalidation.window_dirty(Invalidation.from_input(input, layout), win_id).mode ==
               :clean

      state = put_in(state.workspace.windows.map[win_id].render_cache.last_buffer_dirty, true)
      input = state |> Input.from_editor_state() |> Layout.put()
      invalidation = Invalidation.from_input(input, Layout.get(input))

      assert Invalidation.window_dirty(invalidation, win_id).mode == :all
      assert Invalidation.window_dirty(invalidation, win_id).reason == :buffer_dirty_changed
    end
  end

  defp rendered_state(opts) do
    state =
      opts
      |> base_state()
      |> EditorState.sync_active_window_cursor()
      |> RenderPipeline.compute_layout()

    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {_frames, _cursor, state} = Content.build_content(state, scrolls)
    {state, layout}
  end

  defp normalize_cached_decorations_version(state, win_id) do
    window = Map.fetch!(state.workspace.windows.map, win_id)
    fingerprint = window.render_cache.last_context_fingerprint
    decorations_version = Buffer.decorations_version(window.buffer)

    put_in(
      state.workspace.windows.map[win_id].render_cache.last_context_fingerprint,
      put_elem(fingerprint, 10, decorations_version)
    )
  end

  describe "WindowDirty struct" do
    test "clean/0 marks the window as nothing-to-do" do
      d = WindowDirty.clean()
      assert d.mode == :clean
      assert WindowDirty.clean?(d)
      refute WindowDirty.full?(d)
    end

    test "all/1 marks the whole window dirty with a reason" do
      d = WindowDirty.all(:buffer_edit)
      assert d.mode == :all
      assert d.reason == :buffer_edit
      assert WindowDirty.full?(d)
      refute WindowDirty.clean?(d)
    end

    test "rows/2 marks only listed lines dirty" do
      d = WindowDirty.rows([3, 7, 9], :viewport_scroll)
      assert d.mode == :rows
      assert d.reason == :viewport_scroll
      assert d.dirty_rows == %{3 => true, 7 => true, 9 => true}
      refute WindowDirty.clean?(d)
      refute WindowDirty.full?(d)
    end
  end
end
