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

    test "line count changes dirty rows without requesting retained epoch reset" do
      {cache, epoch, _full_refresh?} =
        RenderCache.reset()
        |> RenderCache.prepare_epoch({:window, 1, :geometry})

      cache =
        cache
        |> RenderCache.snapshot(0, 0, 4, 3, 1, 1, :ctx)
        |> RenderCache.detect_invalidation(0, 0, 4, 4, 2, 1)

      assert cache.dirty_lines == :all

      {_cache, next_epoch, full_refresh?} =
        RenderCache.prepare_epoch(cache, {:window, 1, :geometry})

      assert next_epoch == epoch
      assert full_refresh? == false
    end
  end

  describe "prepare_epoch/2" do
    test "keeps epoch stable and full_refresh false when reset fingerprint is unchanged" do
      {cache, epoch, full_refresh?} =
        RenderCache.reset()
        |> RenderCache.prepare_epoch({:window, 1, :geometry})

      assert epoch == 1
      assert full_refresh? == true

      {_cache, next_epoch, next_full_refresh?} =
        RenderCache.prepare_epoch(cache, {:window, 1, :geometry})

      assert next_epoch == epoch
      assert next_full_refresh? == false
    end

    test "bumps epoch and full_refresh when reset fingerprint changes" do
      {cache, epoch, _full_refresh?} =
        RenderCache.reset()
        |> RenderCache.prepare_epoch({:window, 1, :geometry})

      {_cache, next_epoch, next_full_refresh?} =
        RenderCache.prepare_epoch(cache, {:window, 1, :resized})

      assert next_epoch == epoch + 1
      assert next_full_refresh? == true
    end

    test "frontend reset marker bumps epoch and requests a full refresh for unchanged geometry" do
      {cache, epoch, _full_refresh?} =
        RenderCache.reset()
        |> RenderCache.prepare_epoch({:window, 1, :geometry})

      cache = RenderCache.mark_reset_pending(cache)

      {_cache, next_epoch, full_refresh?} =
        RenderCache.prepare_epoch(cache, {:window, 1, :geometry})

      assert next_epoch == epoch + 1
      assert full_refresh? == true
    end
  end
end
