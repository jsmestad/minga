defmodule MingaEditor.Shell.Board.LayoutTest do
  @moduledoc """
  Tests for Board grid layout computation.

  Verifies golden ratio proportions, responsive column adaptation,
  and invariants (non-overlap, bounds containment) via property tests.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaEditor.Shell.Board.Layout
  alias MingaEditor.Shell.Board.State

  # ── Helpers ────────────────────────────────────────────────────────────

  defp build_board(card_count) do
    Enum.reduce(1..card_count, State.new(), fn _, acc ->
      {acc, _card} = State.create_card(acc, task: "task")
      acc
    end)
  end

  defp rects_overlap?({r1, c1, w1, h1}, {r2, c2, w2, h2}) do
    not (r1 + h1 <= r2 or r2 + h2 <= r1 or c1 + w1 <= c2 or c2 + w2 <= c1)
  end

  # ── Empty board ────────────────────────────────────────────────────────

  describe "empty board" do
    test "produces no card rects" do
      layout = Layout.compute(State.new(), 80, 24)
      assert layout.card_rects == %{}
      assert layout.grid_rows == 0
    end

    test "still has header and content area" do
      layout = Layout.compute(State.new(), 80, 24)
      assert layout.header_rect == {0, 0, 80, 1}
      {row, _col, _w, h} = layout.content_area
      assert row == 1
      assert h > 0
    end
  end

  # ── Single card ────────────────────────────────────────────────────────

  describe "single card" do
    test "produces one card rect" do
      state = build_board(1)
      layout = Layout.compute(state, 80, 24)

      assert map_size(layout.card_rects) == 1
      assert layout.grid_cols >= 1
      assert layout.grid_rows == 1
    end

    test "card has positive dimensions" do
      state = build_board(1)
      layout = Layout.compute(state, 80, 24)

      [{_id, {_row, _col, w, h}}] = Map.to_list(layout.card_rects)
      assert w > 0
      assert h > 0
    end

    test "card approximates golden ratio aspect ratio" do
      state = build_board(1)
      layout = Layout.compute(state, 120, 40)

      [{_id, {_row, _col, w, h}}] = Map.to_list(layout.card_rects)
      ratio = w / h
      # Golden ratio is ~1.618, allow generous tolerance for cell grid
      assert ratio > 1.0, "card should be wider than tall (got #{ratio})"
      assert ratio < 2.5, "card shouldn't be excessively wide (got #{ratio})"
    end
  end

  # ── Multiple cards ─────────────────────────────────────────────────────

  describe "multiple cards" do
    test "4 cards on 80x24 produce a 2+ column grid" do
      state = build_board(4)
      layout = Layout.compute(state, 80, 24)

      assert map_size(layout.card_rects) == 4
      assert layout.grid_cols >= 2
    end

    test "wide viewport produces more columns" do
      state = build_board(6)
      narrow = Layout.compute(state, 60, 30)
      wide = Layout.compute(state, 160, 30)

      assert wide.grid_cols >= narrow.grid_cols
    end

    test "all cards get the same dimensions within a grid" do
      state = build_board(6)
      layout = Layout.compute(state, 100, 30)

      sizes =
        layout.card_rects
        |> Map.values()
        |> Enum.map(fn {_r, _c, w, h} -> {w, h} end)
        |> Enum.uniq()

      # All cards should have the same size (possibly last row truncated)
      assert length(sizes) <= 2, "expected at most 2 unique sizes, got #{inspect(sizes)}"
    end
  end

  # ── Column adaptation ──────────────────────────────────────────────────

  describe "responsive columns" do
    test "very narrow viewport forces single column" do
      state = build_board(4)
      layout = Layout.compute(state, 30, 24)
      assert layout.grid_cols == 1
    end

    test "columns increase with viewport width" do
      state = build_board(10)

      cols_by_width =
        for w <- [40, 80, 120, 160, 200] do
          layout = Layout.compute(state, w, 30)
          layout.grid_cols
        end

      # Columns should be non-decreasing as width grows
      assert cols_by_width == Enum.sort(cols_by_width)
    end
  end

  # ── Card internal padding ──────────────────────────────────────────────

  describe "card_padding/2" do
    test "vertical padding is larger than horizontal (golden ratio)" do
      {top, right, bottom, left} = Layout.card_padding(40, 20)

      assert top >= left, "top (#{top}) should be >= left (#{left})"
      assert bottom >= right, "bottom (#{bottom}) should be >= right (#{right})"
    end

    test "padding is at least 1 cell on all sides" do
      {top, right, bottom, left} = Layout.card_padding(10, 5)
      assert top >= 1
      assert right >= 1
      assert bottom >= 1
      assert left >= 1
    end

    test "padding doesn't consume more than half the card" do
      {top, right, bottom, left} = Layout.card_padding(20, 10)
      assert top + bottom < 10
      assert left + right < 20
    end
  end

  # ── Property: non-overlap invariant ────────────────────────────────────

  property "card rects never overlap for any viewport size and card count" do
    check all(
            width <- integer(20..200),
            height <- integer(8..60),
            card_count <- integer(1..20)
          ) do
      state = build_board(card_count)
      layout = Layout.compute(state, width, height)

      rects = Map.values(layout.card_rects)

      for {r1, i} <- Enum.with_index(rects),
          {r2, j} <- Enum.with_index(rects),
          i < j do
        refute rects_overlap?(r1, r2),
               "Cards #{i} and #{j} overlap at #{width}x#{height}: #{inspect(r1)} vs #{inspect(r2)}"
      end
    end
  end

  # ── Property: bounds invariant ─────────────────────────────────────────

  property "all card rects fit within viewport bounds" do
    check all(
            width <- integer(20..200),
            height <- integer(8..60),
            card_count <- integer(1..20)
          ) do
      state = build_board(card_count)
      layout = Layout.compute(state, width, height)

      for {_id, {row, col, w, h}} <- layout.card_rects do
        assert row >= 0, "row #{row} is negative"
        assert col >= 0, "col #{col} is negative"
        assert w > 0, "width #{w} is not positive"
        assert h > 0, "height #{h} is not positive"

        assert col + w <= width,
               "card exceeds viewport width: col=#{col} w=#{w} viewport=#{width}"
      end
    end
  end

  # ── Property: all cards get a rect ─────────────────────────────────────

  property "every card gets a rect in the layout" do
    check all(
            width <- integer(30..200),
            height <- integer(10..60),
            card_count <- integer(1..15)
          ) do
      state = build_board(card_count)
      layout = Layout.compute(state, width, height)

      assert map_size(layout.card_rects) == card_count
    end
  end

  # ── Degenerate viewports ───────────────────────────────────────────────

  describe "degenerate viewports" do
    test "tiny terminal (20x8) with 4 cards doesn't crash" do
      state = build_board(4)
      layout = Layout.compute(state, 20, 8)

      assert map_size(layout.card_rects) == 4

      for {_id, {_r, _c, w, h}} <- layout.card_rects do
        assert w > 0
        assert h > 0
      end
    end

    test "minimum viewport (20x8) with 1 card" do
      state = build_board(1)
      layout = Layout.compute(state, 20, 8)

      [{_id, {row, col, w, h}}] = Map.to_list(layout.card_rects)
      assert row >= 0
      assert col >= 0
      assert w > 0
      assert h > 0
    end
  end
end
