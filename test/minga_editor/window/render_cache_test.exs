defmodule MingaEditor.Window.RenderCacheTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.EditDelta
  alias Minga.RenderModel.Window.LineIdentity
  alias MingaEditor.Renderer.WindowCache, as: RenderCache
  alias Minga.Core.WidthOracle.Monospace
  alias Minga.RenderModel.Window.RowSlotAllocator
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.RenderModel.Window.ReviewLayout
  alias MingaEditor.UI.Theme

  describe "detect_invalidation/6" do
    test "marks the cache fully dirty when buffer version changes with the same line count" do
      cache =
        RenderCache.reset()
        |> RenderCache.snapshot(0, 0, 4, 3, 2, 1, :ctx)

      cache = RenderCache.detect_invalidation(cache, 0, 4, 3, 2, 2)

      assert cache.fully_dirty?
    end

    test "a version change with pending deltas preserves the prior full-invalidation flag" do
      cache = RenderCache.snapshot(%RenderCache{}, 0, 0, 4, 3, 1, 1, :ctx)
      delta = EditDelta.insertion(0, {1, 0}, "Z", {1, 1})

      for cache <- [cache, RenderCache.mark_fully_dirty(cache)] do
        updated =
          cache
          |> RenderCache.apply_edit_deltas(self(), [delta], nil)
          |> RenderCache.detect_invalidation(0, 4, 3, 2, 1)

        assert updated.fully_dirty? == cache.fully_dirty?
        assert RenderCache.pending_edit_deltas(updated) == [delta]
      end
    end

    test "does not mark the cache fully dirty for cursor-only movement" do
      cache =
        RenderCache.reset()
        |> RenderCache.snapshot(0, 0, 4, 3, 1, 1, :ctx)

      cache = RenderCache.detect_invalidation(cache, 0, 4, 3, 1, 2)

      refute cache.fully_dirty?
    end
  end

  describe "detect_invalidation/7" do
    test "marks the cache fully dirty when the viewport key changes without moving the logical top" do
      cache =
        RenderCache.reset()
        |> RenderCache.snapshot(0, 0, 4, 3, 1, 1, :ctx)

      cache = RenderCache.detect_invalidation(cache, 0, 1, 4, 3, 1, 1)

      assert cache.fully_dirty?
    end

    test "line count changes mark full invalidation without requesting an epoch reset" do
      {cache, epoch, _full_refresh?} =
        RenderCache.reset()
        |> RenderCache.prepare_epoch({:window, 1, :geometry})

      cache =
        cache
        |> RenderCache.snapshot(0, 0, 4, 3, 1, 1, :ctx)
        |> RenderCache.detect_invalidation(0, 0, 4, 4, 2, 1)

      assert cache.fully_dirty?

      {_cache, next_epoch, full_refresh?} =
        RenderCache.prepare_epoch(cache, {:window, 1, :geometry})

      assert next_epoch == epoch
      assert full_refresh? == false
    end
  end

  describe "sync_line_identity/3" do
    test "switching buffers starts a fresh content epoch even when line counts match" do
      first_buffer = start_supervised!({Buffer, content: "same\nlines"}, id: :first_buffer)
      second_buffer = start_supervised!({Buffer, content: "same\nlines"}, id: :second_buffer)
      first_snapshot = Buffer.render_snapshot(first_buffer, 0, 0)
      second_snapshot = Buffer.render_snapshot(second_buffer, 0, 0)

      first_cache =
        RenderCache.reset()
        |> RenderCache.sync_line_identity(first_buffer, first_snapshot)

      second_cache =
        RenderCache.sync_line_identity(first_cache, second_buffer, second_snapshot)

      assert RenderCache.content_epoch(second_cache) > RenderCache.content_epoch(first_cache)

      assert LineIdentity.content_epoch(RenderCache.line_identity(second_cache)) ==
               RenderCache.content_epoch(second_cache)
    end

    test "lineage that disagrees with the snapshot is rebuilt in a fresh epoch in the same frame" do
      buffer = start_supervised!({Buffer, content: "one\ntwo"})
      snapshot = Buffer.render_snapshot(buffer, 0, 0)
      cache = RenderCache.sync_line_identity(RenderCache.reset(), buffer, snapshot)

      disagreeing = [
        line_count: %{snapshot | line_count: snapshot.line_count + 3},
        change_sequence: %{snapshot | change_sequence: snapshot.change_sequence + 1}
      ]

      for {field, observed} <- disagreeing do
        synced = RenderCache.sync_line_identity(cache, buffer, observed)
        identity = RenderCache.line_identity(synced)

        refute is_nil(identity), "#{field} mismatch left no line identity"
        assert LineIdentity.line_count(identity) == observed.line_count
        assert RenderCache.content_epoch(synced) > RenderCache.content_epoch(cache)
        assert LineIdentity.content_epoch(identity) == RenderCache.content_epoch(synced)
        assert RenderCache.applied_change_sequence(synced) == observed.change_sequence
        assert synced.reset_pending
      end
    end
  end

  describe "prepare_epoch/2" do
    test "keeps epoch stable and full_refresh false when reset fingerprint is unchanged" do
      {cache, epoch, full_refresh?} =
        RenderCache.reset()
        |> RenderCache.prepare_epoch({:window, 1, :geometry})

      assert epoch > 0
      assert full_refresh? == true

      {_cache, next_epoch, next_full_refresh?} =
        RenderCache.prepare_epoch(cache, {:window, 1, :geometry})

      assert next_epoch == epoch
      assert next_full_refresh? == false
    end

    test "preserves content epoch while refreshing changed layout fingerprint" do
      {cache, epoch, _full_refresh?} =
        RenderCache.reset()
        |> RenderCache.prepare_epoch({:window, 1, :geometry})

      {_cache, next_epoch, next_full_refresh?} =
        RenderCache.prepare_epoch(cache, {:window, 1, :resized})

      assert next_epoch == epoch
      assert next_full_refresh? == true
    end

    test "frontend reset marker preserves content epoch and requests a full refresh" do
      {cache, epoch, _full_refresh?} =
        RenderCache.reset()
        |> RenderCache.prepare_epoch({:window, 1, :geometry})

      cache = RenderCache.mark_reset_pending(cache)

      {_cache, next_epoch, full_refresh?} =
        RenderCache.prepare_epoch(cache, {:window, 1, :geometry})

      assert next_epoch == epoch
      assert full_refresh? == true
    end
  end

  describe "resident review identity" do
    test "content refresh preserves epoch while frontend recovery reuses retained rows" do
      layout = review_layout(80)
      preview = Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "before", "first"))

      {:ok, _projection, nil, cache} =
        RenderCache.project_review(RenderCache.reset(), preview, :workspace, layout)

      {cache, epoch, true} = RenderCache.prepare_epoch(cache, :review)

      preview = Preview.set_diff(preview, DiffReview.new("selected.ex", "before", "second"))

      {:ok, projection, delta, cache} =
        RenderCache.project_review(cache, preview, :workspace, layout)

      assert delta != nil
      {cache, same_epoch, false} = RenderCache.prepare_epoch(cache, :review)
      assert same_epoch == epoch

      cache = RenderCache.mark_reset_pending(cache)

      {:ok, reused, nil, cache} =
        RenderCache.project_review(cache, Preview.scroll_down(preview, 4), :workspace, layout)

      assert :erts_debug.same(projection, reused)
      {_cache, same_epoch, true} = RenderCache.prepare_epoch(cache, :review)
      assert same_epoch == epoch
    end

    test "layout incompatibility replaces the projection and allocator in one new epoch" do
      preview =
        Preview.set_diff(
          Preview.new(),
          DiffReview.new("selected.ex", "before", String.duplicate("wide ", 30))
        )

      {:ok, previous, nil, cache} =
        RenderCache.project_review(RenderCache.reset(), preview, :workspace, review_layout(80))

      {cache, previous_epoch, true} = RenderCache.prepare_epoch(cache, :review)

      {:ok, updated, nil, cache} =
        RenderCache.project_review(cache, preview, :workspace, review_layout(20))

      assert updated.row_count > previous.row_count
      {_cache, next_epoch, true} = RenderCache.prepare_epoch(cache, :review)
      assert next_epoch > previous_epoch
      assert Map.keys(RenderCache.row_slot_allocator(cache).next) == [{next_epoch, 0, :normal}]
    end

    test "slot exhaustion publishes one complete fresh-epoch projection instead of partial rows" do
      layout = review_layout(80)
      preview = Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "before", "first"))

      {:ok, _previous, nil, cache} =
        RenderCache.project_review(RenderCache.reset(), preview, :workspace, layout)

      {cache, previous_epoch, true} = RenderCache.prepare_epoch(cache, :review)
      allocator = RenderCache.row_slot_allocator(cache)

      exhausted = %RowSlotAllocator{
        slots: allocator.slots,
        next: %{{previous_epoch, 0, :normal} => 0x1000_0000}
      }

      cache = RenderCache.put_row_slot_allocator(cache, exhausted)

      preview = Preview.set_diff(preview, DiffReview.new("selected.ex", "before", "second"))
      {:ok, updated, nil, cache} = RenderCache.project_review(cache, preview, :workspace, layout)
      assert Enum.any?(updated.rows, &(&1.text == "+ second"))
      refute Enum.any?(updated.rows, &(&1.text == "+ first"))
      assert length(Enum.uniq_by(updated.rows, & &1.row_id)) == updated.row_count
      {_cache, next_epoch, true} = RenderCache.prepare_epoch(cache, :review)
      assert next_epoch > previous_epoch
    end
  end

  defp review_layout(width),
    do: ReviewLayout.new(width, %Monospace{}, Theme.get!(:minga_default), 4)
end
