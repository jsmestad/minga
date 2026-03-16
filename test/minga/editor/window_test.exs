defmodule Minga.Editor.WindowTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Window
  alias Minga.Popup.Active, as: PopupActive
  alias Minga.Popup.Rule, as: PopupRule

  defp make_window(opts \\ []) do
    buffer = Keyword.get_lazy(opts, :buffer, fn -> spawn(fn -> :ok end) end)
    Window.new(1, buffer, 24, 80)
  end

  describe "new/4" do
    test "creates a window with the given id, buffer, and dimensions" do
      buffer = spawn(fn -> :ok end)
      window = Window.new(1, buffer, 24, 80)

      assert window.id == 1
      assert window.buffer == buffer
      assert window.viewport.rows == 24
      assert window.viewport.cols == 80
      assert window.viewport.top == 0
      assert window.viewport.left == 0
    end

    test "initializes with empty dirty set (sentinel values trigger full redraw on first detect)" do
      window = make_window()
      assert window.dirty_lines == %{}
    end

    test "initializes with empty caches" do
      window = make_window()
      assert window.cached_gutter == %{}
      assert window.cached_content == %{}
    end

    test "initializes tracking fields to sentinel values" do
      window = make_window()
      assert window.last_viewport_top == -1
      assert window.last_gutter_w == -1
      assert window.last_line_count == -1
      assert window.last_cursor_line == -1
      assert window.last_buf_version == -1
    end
  end

  describe "resize/3" do
    test "updates viewport dimensions" do
      window = make_window()
      resized = Window.resize(window, 12, 40)

      assert resized.viewport.rows == 12
      assert resized.viewport.cols == 40
      assert resized.id == 1
    end

    test "marks all lines dirty and clears caches" do
      window = make_window()
      # Simulate a previous render with populated caches
      window = Window.cache_line(window, 0, [{0, 0, "1", []}], [{0, 4, "hi", []}])
      window = %{window | dirty_lines: %{}, last_buf_version: 5, last_context_fingerprint: :fp}
      resized = Window.resize(window, 12, 40)

      assert resized.dirty_lines == :all
      assert resized.cached_gutter == %{}
      assert resized.cached_content == %{}
      assert resized.last_buf_version == -1
      assert resized.last_context_fingerprint == nil
    end
  end

  describe "mark_dirty/2" do
    test "marks specific lines dirty" do
      window = %{make_window() | dirty_lines: %{}}
      window = Window.mark_dirty(window, [5, 10, 15])

      assert Map.has_key?(window.dirty_lines, 5)
      assert Map.has_key?(window.dirty_lines, 10)
      assert Map.has_key?(window.dirty_lines, 15)
      refute Map.has_key?(window.dirty_lines, 6)
    end

    test "accumulates dirty lines across calls" do
      window = %{make_window() | dirty_lines: %{}}
      window = Window.mark_dirty(window, [5])
      window = Window.mark_dirty(window, [10])

      assert Map.has_key?(window.dirty_lines, 5)
      assert Map.has_key?(window.dirty_lines, 10)
    end

    test "marks all lines dirty with :all" do
      window = %{make_window() | dirty_lines: Map.new([1, 2, 3], &{&1, true})}
      window = Window.mark_dirty(window, :all)
      assert window.dirty_lines == :all
    end

    test "adding specific lines to :all is a no-op" do
      window = Window.invalidate(make_window())
      assert window.dirty_lines == :all
      window = Window.mark_dirty(window, [5, 10])
      assert window.dirty_lines == :all
    end
  end

  describe "invalidate/1" do
    test "sets dirty_lines to :all and clears all render state" do
      window = make_window()
      window = Window.cache_line(window, 0, [{0, 0, "1", []}], [{0, 4, "hi", []}])

      window = %{
        window
        | dirty_lines: Map.new([1, 2], &{&1, true}),
          last_buf_version: 5,
          last_context_fingerprint: :fp
      }

      window = Window.invalidate(window)

      assert window.dirty_lines == :all
      assert window.cached_gutter == %{}
      assert window.cached_content == %{}
      assert window.last_viewport_top == -1
      assert window.last_gutter_w == -1
      assert window.last_line_count == -1
      assert window.last_cursor_line == -1
      assert window.last_buf_version == -1
      assert window.last_context_fingerprint == nil
    end
  end

  describe "dirty?/2" do
    test "returns true for any line when dirty_lines is :all" do
      window = Window.invalidate(make_window())
      assert Window.dirty?(window, 0)
      assert Window.dirty?(window, 999)
    end

    test "returns true only for lines in the dirty set" do
      window = %{make_window() | dirty_lines: Map.new([5, 10], &{&1, true})}
      assert Window.dirty?(window, 5)
      assert Window.dirty?(window, 10)
      refute Window.dirty?(window, 0)
      refute Window.dirty?(window, 6)
    end

    test "returns false for any line when dirty set is empty" do
      window = %{make_window() | dirty_lines: %{}}
      refute Window.dirty?(window, 0)
      refute Window.dirty?(window, 5)
    end
  end

  describe "detect_invalidation/5" do
    setup do
      window = make_window()

      # Simulate a previous render that set tracking fields
      window =
        Window.snapshot_after_render(
          window,
          _viewport_top = 0,
          _gutter_w = 4,
          _line_count = 100,
          _cursor_line = 10,
          _buf_version = 5,
          _fingerprint = :test_fp
        )

      %{window: window}
    end

    test "no invalidation when nothing changed", %{window: window} do
      result = Window.detect_invalidation(window, 0, 4, 100, 5)
      assert result.dirty_lines == %{}
    end

    test "full invalidation when viewport scrolled", %{window: window} do
      result = Window.detect_invalidation(window, 5, 4, 100, 5)
      assert result.dirty_lines == :all
    end

    test "full invalidation when gutter width changed", %{window: window} do
      result = Window.detect_invalidation(window, 0, 5, 100, 5)
      assert result.dirty_lines == :all
    end

    test "full invalidation when line count changed", %{window: window} do
      result = Window.detect_invalidation(window, 0, 4, 101, 5)
      assert result.dirty_lines == :all
    end

    test "full invalidation when buffer version changed", %{window: window} do
      result = Window.detect_invalidation(window, 0, 4, 100, 6)
      assert result.dirty_lines == :all
    end

    test "full invalidation on first frame (sentinel tracking values)", %{window: _window} do
      # Fresh window has sentinel last_buf_version=-1 → always full redraw
      fresh = %{make_window() | dirty_lines: %{}}
      result = Window.detect_invalidation(fresh, 0, 4, 100, 1)
      assert result.dirty_lines == :all
    end

    test "preserves existing dirty lines when no full invalidation needed", %{window: window} do
      window = Window.mark_dirty(window, [5, 10])
      result = Window.detect_invalidation(window, 0, 4, 100, 5)
      assert result.dirty_lines == Map.new([5, 10], &{&1, true})
    end
  end

  describe "cache_line/4" do
    test "stores gutter and content draws for a buffer line" do
      window = make_window()
      gutter = [{0, 0, "  1", []}]
      content = [{0, 4, "hello world", []}]

      window = Window.cache_line(window, 0, gutter, content)

      assert window.cached_gutter[0] == gutter
      assert window.cached_content[0] == content
    end

    test "overwrites previous cache for the same line" do
      window = make_window()
      old_content = [{0, 4, "old text", []}]
      new_content = [{0, 4, "new text", []}]

      window = Window.cache_line(window, 5, [], old_content)
      window = Window.cache_line(window, 5, [], new_content)

      assert window.cached_content[5] == new_content
    end

    test "caching multiple lines builds up the map" do
      window = make_window()

      window = Window.cache_line(window, 0, [{0, 0, "1", []}], [{0, 4, "line 0", []}])
      window = Window.cache_line(window, 1, [{1, 0, "2", []}], [{1, 4, "line 1", []}])
      window = Window.cache_line(window, 2, [{2, 0, "3", []}], [{2, 4, "line 2", []}])

      assert map_size(window.cached_gutter) == 3
      assert map_size(window.cached_content) == 3
    end
  end

  describe "snapshot_after_render/7" do
    test "clears the dirty set" do
      window = Window.invalidate(make_window())
      assert window.dirty_lines == :all

      window = Window.snapshot_after_render(window, 0, 4, 100, 10, 5, :test_fp)
      assert window.dirty_lines == %{}
    end

    test "updates all tracking fields" do
      window = make_window()
      window = Window.snapshot_after_render(window, 10, 5, 200, 25, 42, :test_fp)

      assert window.last_viewport_top == 10
      assert window.last_gutter_w == 5
      assert window.last_line_count == 200
      assert window.last_cursor_line == 25
      assert window.last_buf_version == 42
    end
  end

  describe "detect_context_change/2" do
    test "marks all dirty when fingerprint changes" do
      window = make_window()
      window = Window.snapshot_after_render(window, 0, 4, 100, 5, 1, :fp_a)
      assert window.dirty_lines == %{}

      window = Window.detect_context_change(window, :fp_b)
      assert window.dirty_lines == :all
    end

    test "no-op when fingerprint is the same" do
      window = make_window()
      window = Window.snapshot_after_render(window, 0, 4, 100, 5, 1, :fp_a)
      assert window.dirty_lines == %{}

      window = Window.detect_context_change(window, :fp_a)
      assert window.dirty_lines == %{}
    end

    test "no-op when last fingerprint is nil (first frame)" do
      window = make_window()
      assert window.last_context_fingerprint == nil

      window = Window.detect_context_change(window, :fp_a)
      assert window.dirty_lines == %{}
    end

    test "detects changes in complex fingerprint tuples" do
      fp1 = {:visual, {:char, {0, 0}, {5, 10}}, [], nil, %{}, %{}, 0, true}
      fp2 = {:visual, nil, [], nil, %{}, %{}, 0, true}

      window = make_window()
      window = Window.snapshot_after_render(window, 0, 4, 100, 5, 1, fp1)
      window = Window.detect_context_change(window, fp2)
      assert window.dirty_lines == :all
    end
  end

  describe "prune_cache/3" do
    test "removes entries outside the visible range" do
      window = make_window()

      window =
        Enum.reduce(0..20, window, fn line, w ->
          Window.cache_line(w, line, [{line, 0, "#{line}", []}], [{line, 4, "text", []}])
        end)

      assert map_size(window.cached_content) == 21

      window = Window.prune_cache(window, 5, 15)

      assert map_size(window.cached_content) == 11
      refute Map.has_key?(window.cached_content, 4)
      assert Map.has_key?(window.cached_content, 5)
      assert Map.has_key?(window.cached_content, 15)
      refute Map.has_key?(window.cached_content, 16)
    end

    test "gutter cache is also pruned" do
      window = make_window()

      window =
        Enum.reduce(0..10, window, fn line, w ->
          Window.cache_line(w, line, [{line, 0, "#{line}", []}], [])
        end)

      window = Window.prune_cache(window, 3, 7)
      assert map_size(window.cached_gutter) == 5
    end

    test "handles empty cache gracefully" do
      window = make_window()
      window = Window.prune_cache(window, 0, 10)
      assert window.cached_content == %{}
      assert window.cached_gutter == %{}
    end
  end

  describe "full dirty-line lifecycle" do
    test "first frame: detect_invalidation → all dirty → render → snapshot → next frame clean" do
      window = make_window()

      # Before detect_invalidation, window has empty dirty set
      assert window.dirty_lines == %{}

      # detect_invalidation sees sentinel values → marks all dirty
      window = Window.detect_invalidation(window, 0, 4, 100, 1)
      assert window.dirty_lines == :all
      assert Window.dirty?(window, 0)
      assert Window.dirty?(window, 99)

      # Simulate rendering lines 0-9
      window =
        Enum.reduce(0..9, window, fn line, w ->
          Window.cache_line(w, line, [{line, 0, "#{line}", []}], [{line, 4, "text", []}])
        end)

      # Snapshot after render
      window = Window.snapshot_after_render(window, 0, 4, 100, 5, 1, :test_fp)
      assert window.dirty_lines == %{}

      # Frame 2: nothing changed → nothing dirty
      window = Window.detect_invalidation(window, 0, 4, 100, 1)
      assert window.dirty_lines == %{}
      refute Window.dirty?(window, 0)
      refute Window.dirty?(window, 5)
    end

    test "edit cycle: snapshot → mark dirty → detect → only edited lines dirty" do
      window = make_window()

      # Initial render complete
      window =
        Enum.reduce(0..9, window, fn line, w ->
          Window.cache_line(w, line, [{line, 0, "#{line}", []}], [{line, 4, "text", []}])
        end)

      window = Window.snapshot_after_render(window, 0, 4, 100, 5, 1, :test_fp)

      # User types a character on line 5 → buffer version bumps to 2
      # The pipeline detects version change and marks :all dirty
      # (conservative; future optimization can narrow this)
      window = Window.detect_invalidation(window, 0, 4, 100, 2)
      assert window.dirty_lines == :all

      # After rendering, snapshot with new version
      window = Window.snapshot_after_render(window, 0, 4, 100, 5, 2, :test_fp)
      assert window.dirty_lines == %{}
    end

    test "scroll cycle: viewport_top changes → full invalidation" do
      window = make_window()
      window = Window.snapshot_after_render(window, 0, 4, 100, 5, 1, :test_fp)

      # Scroll down
      window = Window.detect_invalidation(window, 10, 4, 100, 1)
      assert window.dirty_lines == :all
    end
  end

  describe "popup?/1" do
    test "returns false for a normal window" do
      window = make_window()
      refute Window.popup?(window)
    end

    test "returns true for a window with popup metadata" do
      rule = PopupRule.new("*test*")
      active = PopupActive.new(rule, 2, 1)
      window = %{make_window() | popup_meta: active}
      assert Window.popup?(window)
    end
  end

  describe "popup_meta field" do
    test "defaults to nil" do
      window = make_window()
      assert window.popup_meta == nil
    end
  end
end
