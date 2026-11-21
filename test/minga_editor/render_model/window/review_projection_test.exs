defmodule MingaEditor.RenderModel.Window.ReviewProjectionTest do
  use ExUnit.Case, async: true

  alias Minga.Core.WidthOracle.Monospace
  alias Minga.RenderModel.Window.ContentDigest
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.RowDelta
  alias Minga.RenderModel.Window.RowSlotAllocator
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.RenderModel.Window.ReviewLayout
  alias MingaEditor.RenderModel.Window.ReviewProjection
  alias MingaEditor.UI.Theme
  alias MingaEditor.UI.Theme.Builder, as: ThemeBuilder

  @selection {:workspace, 1, nil}
  @epoch 10
  @scope {@epoch, 0, :normal}

  test "duplicate insertion occurrences preserve distinct identities when an earlier hunk appears" do
    first = insertion_review(["same", "same"])
    preview = Preview.set_diff(Preview.new(), first)
    {:ok, previous, allocator, nil} = project(nil, preview, RowSlotAllocator.new())
    previous_ids = ids_with_text(previous, "+ same")
    assert length(Enum.uniq(previous_ids)) == 2

    current = insertion_review(["earlier", "same", "same"])
    preview = Preview.set_diff(preview, current)
    assert {:ok, updated, _allocator, %RowDelta{} = delta} = project(previous, preview, allocator)
    assert ids_with_text(updated, "+ same") == previous_ids
    assert apply_delta(previous.rows, delta) == updated.rows
    assert updated.content_digest == ContentDigest.of_rows(updated.rows)
  end

  test "baseline rows keep their identity when temporarily absent from context" do
    original = Enum.map(0..29, &"line #{&1}")
    before = Enum.join(original, "\n")

    first =
      DiffReview.new(
        "selected.ex",
        before,
        original |> List.replace_at(1, "first") |> Enum.join("\n")
      )

    preview = Preview.set_diff(Preview.new(), first)
    {:ok, previous, allocator, nil} = project(nil, preview, RowSlotAllocator.new())
    [original_id] = ids_with_text(previous, "- line 1")

    distant =
      DiffReview.new(
        "selected.ex",
        before,
        original |> List.replace_at(25, "distant") |> Enum.join("\n")
      )

    preview = Preview.set_diff(preview, distant)
    {:ok, middle, allocator, _delta} = project(previous, preview, allocator)
    assert ids_with_text(middle, "- line 1") == []

    returned =
      DiffReview.new(
        "selected.ex",
        before,
        original |> List.replace_at(1, "returned") |> Enum.join("\n")
      )

    preview = Preview.set_diff(preview, returned)
    {:ok, updated, _allocator, _delta} = project(middle, preview, allocator)
    assert ids_with_text(updated, "- line 1") == [original_id]
  end

  test "scrolling, hunk navigation and stale marking reuse the exact resident projection" do
    before = Enum.map_join(1..12, "\n", &"line #{&1}")

    after_content =
      before |> String.replace("line 1\n", "first\n") |> String.replace("line 12", "last")

    preview =
      Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", before, after_content))

    {:ok, previous, allocator, nil} = project(nil, preview, RowSlotAllocator.new())

    inputs = [
      Preview.scroll_down(preview, 4),
      Preview.navigate_hunk(preview, :next),
      Preview.refresh_after_write(preview, "selected.ex"),
      Preview.refresh_after_write(preview, "other.ex")
    ]

    for input <- inputs do
      assert {:ok, reused, retained, nil} = project(previous, input, allocator)
      assert :erts_debug.same(previous, reused)
      assert :erts_debug.same(allocator, retained)
    end
  end

  test "restyling a review updates the changed row without rebuilding source evidence" do
    preview = Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "baseline", "first"))
    {:ok, previous, allocator, nil} = project(nil, preview, RowSlotAllocator.new())
    styled = recolored_layout()

    assert {:ok, updated, _allocator, %RowDelta{} = delta} =
             project(previous, preview, allocator, styled)

    assert [header, removed, %{text: "+ first"} = added] = updated.rows
    assert [^header, ^removed, original_added] = previous.rows
    assert added.row_id == original_added.row_id
    assert added.spans == [ReviewLayout.span(styled, :added)]
    assert added.spans != original_added.spans
    assert added.content_hash == Row.compute_hash(added.text, added.spans)
    assert [%{start_index: 2, delete_count: 1, insert_rows: [^added]}] = delta.splices
    assert apply_delta(previous.rows, delta) == updated.rows
    assert updated.content_digest == ContentDigest.of_rows(updated.rows)
    assert :erts_debug.same(updated.baseline, previous.baseline)
    assert :erts_debug.same(updated.hunk_lineages, previous.hunk_lineages)
  end

  test "matching preview counters do not reuse source evidence for a different review" do
    preview = Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "baseline", "first"))
    {:ok, previous, allocator, nil} = project(nil, preview, RowSlotAllocator.new())
    styled = recolored_layout()

    different_baseline =
      Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "other baseline", "first"))

    assert project(previous, different_baseline, allocator, styled) == :reset_required

    different_edit =
      Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "baseline", "second"))

    assert {:ok, updated, _allocator, %RowDelta{} = delta} =
             project(previous, different_edit, allocator, styled)

    assert [old_header, old_removed, old_added] = previous.rows
    assert [new_header, new_removed, %{text: "+ second"} = new_added] = updated.rows
    assert new_removed.row_id == old_removed.row_id
    refute new_header.row_id == old_header.row_id
    refute new_added.row_id == old_added.row_id
    assert apply_delta(previous.rows, delta) == updated.rows
  end

  test "constant-size hunk churn retires old rows instead of retaining a revision history" do
    preview =
      Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "baseline", "change 0"))

    {:ok, initial, allocator, nil} = project(nil, preview, RowSlotAllocator.new())
    [baseline_id] = ids_with_text(initial, "- baseline")

    Enum.reduce(1..100, {initial, allocator, preview, -1}, fn revision,
                                                              {previous, allocator, preview,
                                                               last_id} ->
      preview =
        Preview.set_diff(preview, DiffReview.new("selected.ex", "baseline", "change #{revision}"))

      {:ok, updated, allocator, _delta} = project(previous, preview, allocator)
      [new_id] = ids_with_text(updated, "+ change #{revision}")
      assert new_id > last_id
      assert ids_with_text(updated, "- baseline") == [baseline_id]
      assert map_size(allocator.slots) == 3
      assert map_size(allocator.next) == 1
      assert map_size(updated.line_cache) == 3
      assert map_size(updated.hunk_lineages) == 1
      assert MapSet.size(updated.baseline_keys) == 1
      {updated, allocator, preview, new_id}
    end)
  end

  test "layout, source, baseline and epoch incompatibility require an explicit identity reset" do
    preview =
      Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "baseline", "changed"))

    {:ok, previous, allocator, nil} = project(nil, preview, RowSlotAllocator.new())

    assert ReviewProjection.refresh(previous, preview, @selection, layout(20), allocator, @epoch) ==
             :reset_required

    assert ReviewProjection.refresh(
             previous,
             preview,
             {:workspace, 2, nil},
             layout(),
             allocator,
             @epoch
           ) == :reset_required

    assert ReviewProjection.refresh(
             previous,
             preview,
             @selection,
             layout(),
             allocator,
             @epoch + 1
           ) == :reset_required

    different_baseline =
      Preview.set_diff(preview, DiffReview.new("selected.ex", "other baseline", "changed"))

    assert project(previous, different_baseline, allocator) == :reset_required
  end

  test "tab expansion and wrapping preserve Unicode and source-fragment identities across refresh" do
    text = "\te\u0301界 " <> String.duplicate("wide 界 ", 8)
    preview = Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "before", text))
    {:ok, previous, allocator, nil} = project(nil, preview, RowSlotAllocator.new(), layout(16))
    added_lineage = Map.fetch!(previous.hunk_lineages, 0)

    keys =
      Enum.filter(allocator.slots, fn {{{_epoch, _source, _kind}, key}, _slot} ->
        match?({:added, ^added_lineage, _, _}, key)
      end)

    assert length(keys) > 1
    refute Enum.any?(previous.rows, &String.contains?(&1.text, "\t"))
    assert Enum.any?(previous.rows, &String.contains?(&1.text, "e\u0301界"))
    assert Enum.all?(previous.rows, &String.valid?(&1.text))

    for {row, rank} <- Enum.with_index(previous.rows) do
      assert row.buf_line == rank
    end

    refreshed = Preview.set_diff(preview, Preview.diff_review(preview))
    {:ok, updated, _allocator, _delta} = project(previous, refreshed, allocator, layout(16))
    assert Enum.map(updated.rows, & &1.row_id) == Enum.map(previous.rows, & &1.row_id)
  end

  test "exhaustion returns no partial projection and unavailable content stays explicit" do
    preview = Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "before", "after"))
    exhausted = %RowSlotAllocator{next: %{@scope => 0x1000_0000}}
    assert project(nil, preview, exhausted) == :reset_required
    assert project(nil, Preview.new(), RowSlotAllocator.new()) == {:error, :review_unavailable}
  end

  defp project(previous, preview, allocator, layout \\ layout()) do
    ReviewProjection.refresh(previous, preview, @selection, layout, allocator, @epoch)
  end

  defp layout(width \\ 80),
    do: ReviewLayout.new(width, %Monospace{}, Theme.get!(:minga_default), 4)

  defp recolored_layout do
    theme =
      ThemeBuilder.apply_overrides(Theme.get!(:minga_default), %{git: %{added_fg: 0x123456}})

    ReviewLayout.new(80, %Monospace{}, theme, 4)
  end

  defp insertion_review(lines) do
    hunks =
      lines
      |> Enum.with_index()
      |> Enum.map(fn {_line, index} ->
        %{type: :added, start_line: index, count: 1, old_start: 0, old_count: 0, old_lines: []}
      end)

    DiffReview.from_hunks("selected.ex", Enum.join(lines, "\n"), hunks)
  end

  defp ids_with_text(projection, text) do
    projection.rows |> Enum.filter(&(&1.text == text)) |> Enum.map(& &1.row_id)
  end

  defp apply_delta(rows, delta) do
    Enum.reduce(Enum.reverse(delta.splices), rows, fn splice, rows ->
      Enum.take(rows, splice.start_index) ++
        splice.insert_rows ++ Enum.drop(rows, splice.start_index + splice.delete_count)
    end)
  end
end
