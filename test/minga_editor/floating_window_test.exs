defmodule MingaEditor.FloatingWindowTest do
  use ExUnit.Case, async: true

  alias MingaEditor.FloatingWindow
  alias MingaEditor.FloatingWindow.Spec

  # The cell-grid painter was removed in #2311. The live surface is `box/1`,
  # which resolves the popup's outer rect for the `SurfaceRegistry`/`FocusTree`.
  # These tests assert on that geometry.

  defp spec(overrides) do
    defaults = %{
      viewport: {24, 80}
    }

    struct!(Spec, Map.merge(defaults, Map.new(overrides)))
  end

  describe "box/1 sizing and centering" do
    test "centers a 60% x 50% window in 80x24 viewport" do
      # 60% of 80 = 48 cols, 50% of 24 = 12 rows
      # Center: row = (24-12)/2 = 6, col = (80-48)/2 = 16
      assert {6, 16, 48, 12} =
               FloatingWindow.box(spec(width: {:percent, 60}, height: {:percent, 50}))
    end

    test "centers a fixed-size window" do
      # Center: row = (24-10)/2 = 7, col = (80-40)/2 = 20
      assert {7, 20, 40, 10} = FloatingWindow.box(spec(width: {:cols, 40}, height: {:rows, 10}))
    end

    test "offset from center" do
      # Center would be row=7, col=30. Offset: row=4, col=35
      assert {4, 35, 20, 10} =
               FloatingWindow.box(
                 spec(width: {:cols, 20}, height: {:rows, 10}, position: {-3, 5})
               )
    end

    test "clamps to viewport when window is larger than screen" do
      {row, col, w, h} =
        FloatingWindow.box(spec(width: {:cols, 100}, height: {:rows, 30}, viewport: {24, 80}))

      assert row >= 0 and row + h <= 24
      assert col >= 0 and col + w <= 80
    end

    test "works with small viewport" do
      {row, col, w, h} =
        FloatingWindow.box(
          spec(width: {:percent, 80}, height: {:percent, 80}, viewport: {10, 20})
        )

      # 80% of 20 = 16, 80% of 10 = 8
      assert {w, h} == {16, 8}
      assert row >= 0 and row + h <= 10
      assert col >= 0 and col + w <= 20
    end
  end

  describe "box/1 anchor positioning" do
    test "positions above cursor when there is room" do
      {row, _col, _w, h} =
        FloatingWindow.box(
          spec(position: {:anchor, 15, 10, :above}, height: {:rows, 5}, width: {:cols, 20})
        )

      assert row + h <= 15
    end

    test "flips below cursor when not enough room above" do
      {row, _col, _w, _h} =
        FloatingWindow.box(
          spec(position: {:anchor, 2, 10, :above}, height: {:rows, 5}, width: {:cols, 20})
        )

      assert row >= 2
    end

    test "positions below cursor when preferred" do
      {row, _col, _w, _h} =
        FloatingWindow.box(
          spec(position: {:anchor, 5, 10, :below}, height: {:rows, 5}, width: {:cols, 20})
        )

      assert row > 5
    end

    test "flips above when not enough room below" do
      {row, _col, _w, h} =
        FloatingWindow.box(
          spec(position: {:anchor, 21, 10, :below}, height: {:rows, 5}, width: {:cols, 20})
        )

      assert row + h <= 22
    end

    test "clamps column to viewport" do
      {_row, col, w, _h} =
        FloatingWindow.box(
          spec(position: {:anchor, 10, 70, :above}, height: {:rows, 3}, width: {:cols, 20})
        )

      assert col + w <= 80
    end
  end
end
