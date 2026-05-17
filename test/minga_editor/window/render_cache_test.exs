defmodule MingaEditor.Window.RenderCacheTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Window.RenderCache

  describe "detect_invalidation/6" do
    test "marks all lines dirty when buffer version changes with the same line count" do
      cache =
        RenderCache.reset()
        |> RenderCache.snapshot(0, 0, 4, 3, 2, 1, :ctx)

      cache = RenderCache.detect_invalidation(cache, 0, 4, 3, 2, 2)

      assert cache.dirty_lines == :all
    end

    test "does not mark all lines dirty for cursor-only movement" do
      cache =
        RenderCache.reset()
        |> RenderCache.snapshot(0, 0, 4, 3, 1, 1, :ctx)

      cache = RenderCache.detect_invalidation(cache, 0, 4, 3, 1, 2)

      assert cache.dirty_lines == %{}
    end
  end

  describe "detect_invalidation/7" do
    test "marks dirty when the viewport cache key changes without moving the logical top" do
      cache =
        RenderCache.reset()
        |> RenderCache.snapshot(0, 0, 4, 3, 1, 1, :ctx)

      cache = RenderCache.detect_invalidation(cache, 0, 1, 4, 3, 1, 1)

      assert cache.dirty_lines == :all
    end
  end
end
