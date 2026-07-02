defmodule MingaEditor.WindowTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Popup.Active, as: PopupActive
  alias MingaEditor.UI.Popup.Rule, as: PopupRule
  alias MingaEditor.Window

  defp make_window(opts \\ []) do
    buffer = Keyword.get_lazy(opts, :buffer, fn -> spawn(fn -> :ok end) end)
    Window.new(1, buffer, 24, 80)
  end

  describe "construction and resizing" do
    test "new windows initialize viewport, content, popup metadata, and empty render cache sentinels" do
      buffer = spawn(fn -> :ok end)
      window = Window.new(1, buffer, 24, 80)

      assert window.id == 1
      assert window.buffer == buffer
      assert window.viewport.rows == 24
      assert window.viewport.cols == 80
      assert window.viewport.top == 0
      assert window.viewport.left == 0
      assert window.popup_meta == nil
      refute Window.popup?(window)
      assert window.render_cache.dirty_lines == %{}

      for field <- [
            :last_viewport_top,
            :last_viewport_cache_key,
            :last_gutter_w,
            :last_line_count,
            :last_cursor_line,
            :last_buf_version
          ] do
        assert Map.fetch!(window.render_cache, field) == -1
      end
    end

    test "resize updates viewport and fully invalidates cached render state" do
      window =
        make_window()
        |> cached_window()
        |> with_tracking(last_buf_version: 5, last_context_fingerprint: :fp, dirty_lines: %{})

      resized = Window.resize(window, 12, 40)

      assert resized.id == 1
      assert resized.viewport.rows == 12
      assert resized.viewport.cols == 40
      assert_fully_invalidated(resized)
    end
  end

  describe "dirty-line tracking and invalidation" do
    test "mark_dirty, dirty?, and invalidate handle targeted and full redraw states" do
      window = make_window()
      refute Window.dirty?(window, 0)
      refute Window.dirty?(window, 5)

      window = window |> Window.mark_dirty([5]) |> Window.mark_dirty([10, 15])
      assert Window.dirty?(window, 5)
      assert Window.dirty?(window, 10)
      assert Window.dirty?(window, 15)
      refute Window.dirty?(window, 6)

      window = Window.mark_dirty(window, :all)
      assert window.render_cache.dirty_lines == :all
      assert Window.dirty?(window, 0)
      assert Window.dirty?(window, 999)

      assert Window.mark_dirty(window, [5, 10]).render_cache.dirty_lines == :all
      assert_fully_invalidated(Window.invalidate(cached_window(make_window())))
    end

    test "detect_invalidation only invalidates on structural render changes and preserves targeted dirtiness otherwise" do
      window = Window.snapshot_after_render(make_window(), 0, 4, 100, 10, 5, :test_fp)
      assert Window.detect_invalidation(window, 0, 4, 100, 5).render_cache.dirty_lines == %{}

      invalidating_inputs = [
        {5, 4, 100, 5},
        {0, 5, 100, 5},
        {0, 4, 101, 5},
        {0, 4, 100, 6}
      ]

      for {viewport_top, gutter_w, line_count, version} <- invalidating_inputs do
        result = Window.detect_invalidation(window, viewport_top, gutter_w, line_count, version)
        assert result.render_cache.dirty_lines == :all
      end

      first_frame = Window.detect_invalidation(make_window(), 0, 4, 100, 1)
      assert first_frame.render_cache.dirty_lines == :all

      targeted = Window.mark_dirty(window, [5, 10])

      assert Window.detect_invalidation(targeted, 0, 4, 100, 5).render_cache.dirty_lines ==
               Map.new([5, 10], &{&1, true})
    end
  end

  describe "render cache lifecycle" do
    test "snapshot stores tracking fields and clears the dirty set" do
      window = make_window()

      window = Window.invalidate(window)
      assert window.render_cache.dirty_lines == :all

      window = Window.snapshot_after_render(window, 10, 77, 5, 200, 25, 42, :test_fp)
      assert window.render_cache.dirty_lines == %{}
      assert window.render_cache.last_viewport_top == 10
      assert window.render_cache.last_viewport_cache_key == 77
      assert window.render_cache.last_gutter_w == 5
      assert window.render_cache.last_line_count == 200
      assert window.render_cache.last_cursor_line == 25
      assert window.render_cache.last_buf_version == 42
    end

    test "full dirty-line lifecycle covers first frame, clean frame, edit invalidation, and scroll invalidation" do
      window = make_window()
      assert window.render_cache.dirty_lines == %{}

      window = Window.detect_invalidation(window, 0, 4, 100, 1)
      assert window.render_cache.dirty_lines == :all
      assert Window.dirty?(window, 0)
      assert Window.dirty?(window, 99)

      window = Window.snapshot_after_render(window, 0, 4, 100, 5, 1, :test_fp)
      assert window.render_cache.dirty_lines == %{}

      clean = Window.detect_invalidation(window, 0, 4, 100, 1)
      assert clean.render_cache.dirty_lines == %{}
      refute Window.dirty?(clean, 0)

      edited = Window.detect_invalidation(window, 0, 4, 100, 2)
      assert edited.render_cache.dirty_lines == :all

      assert Window.snapshot_after_render(edited, 0, 4, 100, 5, 2, :test_fp).render_cache.dirty_lines ==
               %{}

      scrolled =
        window
        |> Window.snapshot_after_render(0, 4, 100, 5, 1, :test_fp)
        |> Window.detect_invalidation(10, 4, 100, 1)

      assert scrolled.render_cache.dirty_lines == :all
    end
  end

  describe "context changes and popups" do
    test "context fingerprint changes invalidate only after an initial fingerprint exists" do
      first_frame = make_window()
      assert first_frame.render_cache.last_context_fingerprint == nil
      assert Window.detect_context_change(first_frame, :fp_a).render_cache.dirty_lines == %{}

      window = Window.snapshot_after_render(make_window(), 0, 4, 100, 5, 1, :fp_a)
      assert Window.detect_context_change(window, :fp_a).render_cache.dirty_lines == %{}
      assert Window.detect_context_change(window, :fp_b).render_cache.dirty_lines == :all

      oracle1 = Minga.Core.WidthOracle.Measured.new(%{"wide" => 50})
      oracle2 = Minga.Core.WidthOracle.Measured.new(%{"narrow" => 7})
      fp1 = Minga.Core.WidthOracle.fingerprint(oracle1)
      fp2 = Minga.Core.WidthOracle.fingerprint(oracle2)
      refute fp1 == fp2

      assert make_window()
             |> Window.snapshot_after_render(0, 4, 100, 5, 1, fp1)
             |> Window.detect_context_change(fp2)
             |> Map.fetch!(:render_cache)
             |> Map.fetch!(:dirty_lines) == :all

      complex1 = {:visual, {:char, {0, 0}, {5, 10}}, [], nil, %{}, %{}, 0, true}
      complex2 = {:visual, nil, [], nil, %{}, %{}, 0, true}

      assert make_window()
             |> Window.snapshot_after_render(0, 4, 100, 5, 1, complex1)
             |> Window.detect_context_change(complex2)
             |> Map.fetch!(:render_cache)
             |> Map.fetch!(:dirty_lines) == :all
    end

    test "popup? reflects popup metadata" do
      window = make_window()
      refute Window.popup?(window)
      assert window.popup_meta == nil

      popup_window = %{window | popup_meta: PopupActive.new(PopupRule.new("*test*"), 2, 1)}
      assert Window.popup?(popup_window)
    end
  end

  describe "scroll authority sequence (#2661)" do
    test "new windows default to non-resident with scroll_seq 0 and no echo top" do
      window = make_window()
      refute Window.resident?(window)
      assert Window.scroll_seq(window) == 0
      assert window.scroll_echo_top == nil
    end

    test "set_resident/2 records the render pipeline's residence decision in the render cache" do
      window = make_window()
      assert Window.resident?(Window.set_resident(window, true))
      refute Window.resident?(Window.set_resident(window, false))
    end

    test "mark_scroll_echo/2 records the committed top on the window (not the render cache)" do
      window = Window.mark_scroll_echo(make_window(), 7)
      assert window.scroll_echo_top == 7
    end

    test "settle_scroll_seq/1 establishes the baseline without bumping on the first settle" do
      window = make_window() |> at_top(0) |> Window.settle_scroll_seq()
      assert Window.scroll_seq(window) == 0
    end

    test "settle_scroll_seq/1 bumps when the top moves to a non-echo value" do
      window =
        make_window()
        |> at_top(0)
        |> Window.settle_scroll_seq()
        |> at_top(5)
        |> Window.settle_scroll_seq()

      assert Window.scroll_seq(window) == 1
    end

    test "settle_scroll_seq/1 does not bump when the top matches the reported free-scroll top" do
      window =
        make_window()
        |> at_top(0)
        |> Window.settle_scroll_seq()
        |> at_top(5)
        |> Window.mark_scroll_echo(5)
        |> Window.settle_scroll_seq()

      assert Window.scroll_seq(window) == 0
    end

    test "settle_scroll_seq/1 is a no-op when the top did not change" do
      window =
        make_window()
        |> at_top(3)
        |> Window.settle_scroll_seq()
        |> Window.settle_scroll_seq()

      assert Window.scroll_seq(window) == 0
    end

    test "settle_scroll_seq/1 stays monotonic across repeated jumps" do
      window =
        make_window()
        |> at_top(0)
        |> Window.settle_scroll_seq()
        |> at_top(5)
        |> Window.settle_scroll_seq()
        |> at_top(10)
        |> Window.settle_scroll_seq()

      assert Window.scroll_seq(window) == 2
    end
  end

  defp cached_window(window) do
    # Put the window in a "clean, previously rendered" state so a later
    # resize/invalidate is observable as a transition back to a full redraw.
    Window.snapshot_after_render(window, 0, 4, 100, 5, 1, :test_fp)
  end

  defp with_tracking(window, updates) do
    %{window | render_cache: Map.merge(window.render_cache, Map.new(updates))}
  end

  defp at_top(window, top) do
    %{window | viewport: %{window.viewport | top: top}}
  end

  defp assert_fully_invalidated(window) do
    assert window.render_cache.dirty_lines == :all
    assert window.render_cache.last_viewport_top == -1
    assert window.render_cache.last_gutter_w == -1
    assert window.render_cache.last_line_count == -1
    assert window.render_cache.last_cursor_line == -1
    assert window.render_cache.last_buf_version == -1
    assert window.render_cache.last_context_fingerprint == nil
  end
end
