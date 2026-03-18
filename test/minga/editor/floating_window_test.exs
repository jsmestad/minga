defmodule Minga.Editor.FloatingWindowTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.DisplayList
  alias Minga.Editor.FloatingWindow
  alias Minga.Editor.FloatingWindow.Spec

  @theme %{fg: 0xFFFFFF, bg: 0x333333, border_fg: 0x888888}

  defp spec(overrides \\ []) do
    defaults = %{
      theme: @theme,
      viewport: {24, 80}
    }

    struct!(Spec, Map.merge(defaults, Map.new(overrides)))
  end

  describe "render/1 basic output" do
    test "returns a non-empty list of draws" do
      draws = FloatingWindow.render(spec())
      assert is_list(draws)
      assert draws != []
    end

    test "all draws are valid {row, col, text, Face.t()} tuples" do
      draws = FloatingWindow.render(spec())

      Enum.each(draws, fn {row, col, text, style} ->
        assert is_integer(row) and row >= 0
        assert is_integer(col) and col >= 0
        assert is_binary(text)
        assert %Minga.Face{} = style
      end)
    end
  end

  describe "centering" do
    test "centers a 60% x 50% window in 80x24 viewport" do
      draws = FloatingWindow.render(spec(width: {:percent, 60}, height: {:percent, 50}))
      # 60% of 80 = 48 cols, 50% of 24 = 12 rows
      # Center: row = (24-12)/2 = 6, col = (80-48)/2 = 16
      rows = draws |> Enum.map(fn {r, _, _, _} -> r end) |> Enum.uniq() |> Enum.sort()
      cols = draws |> Enum.map(fn {_, c, _, _} -> c end) |> Enum.min()
      assert Enum.min(rows) == 6
      assert Enum.max(rows) == 17
      assert cols == 16
    end

    test "centers a fixed-size window" do
      draws = FloatingWindow.render(spec(width: {:cols, 40}, height: {:rows, 10}))
      # Center: row = (24-10)/2 = 7, col = (80-40)/2 = 20
      rows = draws |> Enum.map(fn {r, _, _, _} -> r end) |> Enum.uniq() |> Enum.sort()
      cols = draws |> Enum.map(fn {_, c, _, _} -> c end) |> Enum.min()
      assert Enum.min(rows) == 7
      assert cols == 20
    end

    test "offset from center" do
      draws =
        FloatingWindow.render(spec(width: {:cols, 20}, height: {:rows, 10}, position: {-3, 5}))

      # Center would be row=7, col=30. Offset: row=4, col=35
      min_row = draws |> Enum.map(fn {r, _, _, _} -> r end) |> Enum.min()
      min_col = draws |> Enum.map(fn {_, c, _, _} -> c end) |> Enum.min()
      assert min_row == 4
      assert min_col == 35
    end

    test "clamps to viewport when window is larger than screen" do
      draws =
        FloatingWindow.render(spec(width: {:cols, 100}, height: {:rows, 30}, viewport: {24, 80}))

      rows = draws |> Enum.map(fn {r, _, _, _} -> r end)
      cols = draws |> Enum.map(fn {_, c, _, _} -> c end)
      assert Enum.min(rows) >= 0
      assert Enum.max(rows) < 24
      assert Enum.min(cols) >= 0
    end

    test "works with small viewport" do
      draws =
        FloatingWindow.render(
          spec(width: {:percent, 80}, height: {:percent, 80}, viewport: {10, 20})
        )

      # 80% of 20 = 16, 80% of 10 = 8
      rows = draws |> Enum.map(fn {r, _, _, _} -> r end)
      cols = draws |> Enum.map(fn {_, c, _, _} -> c end)
      assert Enum.min(rows) >= 0
      assert Enum.max(rows) < 10
      assert Enum.min(cols) >= 0
      assert Enum.max(cols) < 20
    end
  end

  describe "border styles" do
    test "rounded border uses correct characters" do
      draws =
        FloatingWindow.render(spec(width: {:cols, 10}, height: {:rows, 5}, border: :rounded))

      texts = draws |> Enum.map(fn {_, _, t, _} -> t end)
      top_border = Enum.find(texts, &String.starts_with?(&1, "╭"))
      bottom_border = Enum.find(texts, &String.starts_with?(&1, "╰"))
      assert top_border != nil
      assert bottom_border != nil
      assert String.ends_with?(top_border, "╮")
      assert String.ends_with?(bottom_border, "╯")
    end

    test "single border uses correct characters" do
      draws = FloatingWindow.render(spec(width: {:cols, 10}, height: {:rows, 5}, border: :single))
      texts = draws |> Enum.map(fn {_, _, t, _} -> t end)
      assert Enum.any?(texts, &String.starts_with?(&1, "┌"))
      assert Enum.any?(texts, &String.starts_with?(&1, "└"))
    end

    test "double border uses correct characters" do
      draws = FloatingWindow.render(spec(width: {:cols, 10}, height: {:rows, 5}, border: :double))
      texts = draws |> Enum.map(fn {_, _, t, _} -> t end)
      assert Enum.any?(texts, &String.starts_with?(&1, "╔"))
      assert Enum.any?(texts, &String.starts_with?(&1, "╚"))
    end

    test "no border omits border characters" do
      draws = FloatingWindow.render(spec(width: {:cols, 10}, height: {:rows, 5}, border: :none))
      texts = draws |> Enum.map(fn {_, _, t, _} -> t end)
      border_chars = ["╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "╔", "╗", "╚", "╝", "│", "║"]

      refute Enum.any?(texts, fn t ->
               Enum.any?(border_chars, &String.contains?(t, &1))
             end)
    end

    test "sides are drawn between top and bottom" do
      draws =
        FloatingWindow.render(spec(width: {:cols, 10}, height: {:rows, 5}, border: :rounded))

      side_draws = Enum.filter(draws, fn {_, _, t, _} -> t == "│" end)
      # 5 rows - 2 (top/bottom) = 3 interior rows, 2 sides each = 6 side draws
      assert length(side_draws) == 6
    end
  end

  describe "title and footer" do
    test "title appears in the top border row" do
      draws = FloatingWindow.render(spec(title: "Hello", width: {:cols, 30}, height: {:rows, 10}))
      # Top border row is the minimum row
      min_row = draws |> Enum.map(fn {r, _, _, _} -> r end) |> Enum.min()

      title_draw =
        Enum.find(draws, fn {r, _, t, _} -> r == min_row and String.contains?(t, "Hello") end)

      assert title_draw != nil
    end

    test "footer appears in the bottom border row" do
      draws =
        FloatingWindow.render(spec(footer: "Press q", width: {:cols, 30}, height: {:rows, 10}))

      max_row = draws |> Enum.map(fn {r, _, _, _} -> r end) |> Enum.max()

      footer_draw =
        Enum.find(draws, fn {r, _, t, _} -> r == max_row and String.contains?(t, "Press q") end)

      assert footer_draw != nil
    end

    test "title is truncated when window is narrow" do
      draws =
        FloatingWindow.render(
          spec(
            title: "This is a very long title that should be truncated",
            width: {:cols, 15},
            height: {:rows, 5}
          )
        )

      min_row = draws |> Enum.map(fn {r, _, _, _} -> r end) |> Enum.min()

      title_draw =
        Enum.find(draws, fn {r, _, t, _} -> r == min_row and String.contains?(t, "…") end)

      assert title_draw != nil
    end

    test "nil title produces no title draws" do
      draws = FloatingWindow.render(spec(title: nil, width: {:cols, 20}, height: {:rows, 5}))
      min_row = draws |> Enum.map(fn {r, _, _, _} -> r end) |> Enum.min()
      # Only the border draw should be on the top row (no extra title overlay)
      top_draws = Enum.filter(draws, fn {r, _, _, _} -> r == min_row end)
      # Background fill + border = 2 draws on top row
      assert length(top_draws) <= 2
    end

    test "title and footer with no border are not rendered" do
      draws =
        FloatingWindow.render(
          spec(
            title: "Hello",
            footer: "World",
            border: :none,
            width: {:cols, 20},
            height: {:rows, 5}
          )
        )

      texts = draws |> Enum.map(fn {_, _, t, _} -> t end)
      refute Enum.any?(texts, &String.contains?(&1, "Hello"))
      refute Enum.any?(texts, &String.contains?(&1, "World"))
    end
  end

  describe "content" do
    test "content draws are offset into the interior" do
      content = [DisplayList.draw(0, 0, "hello", Minga.Face.new(fg: 0xFFFFFF))]

      draws =
        FloatingWindow.render(
          spec(content: content, width: {:cols, 20}, height: {:rows, 10}, border: :rounded)
        )

      # Find the content draw (not border/background)
      content_draw = Enum.find(draws, fn {_, _, t, _} -> t == "hello" end)
      assert content_draw != nil

      {row, col, _, _} = content_draw
      # With a 20x10 window centered in 80x24:
      # Box starts at row=7, col=30. Interior starts at row=8, col=31
      assert row == 8
      assert col == 31
    end

    test "content is clipped when it exceeds interior height" do
      # Interior of a 10-row bordered window = 8 rows (0..7)
      content =
        for r <- 0..15 do
          DisplayList.draw(r, 0, "line #{r}")
        end

      draws =
        FloatingWindow.render(
          spec(content: content, width: {:cols, 20}, height: {:rows, 10}, border: :rounded)
        )

      content_draws = Enum.filter(draws, fn {_, _, t, _} -> String.starts_with?(t, "line") end)
      # Only 8 interior rows should have content
      assert length(content_draws) == 8
    end

    test "content text is truncated at the right edge" do
      content = [DisplayList.draw(0, 0, "this is a long text that overflows")]

      draws =
        FloatingWindow.render(
          spec(content: content, width: {:cols, 15}, height: {:rows, 5}, border: :rounded)
        )

      content_draw = Enum.find(draws, fn {_, _, t, _} -> String.starts_with?(t, "this") end)
      assert content_draw != nil
      {_, _, text, _} = content_draw
      # Interior width = 15 - 2 = 13. Text should be truncated to 13 chars
      assert String.length(text) <= 13
    end

    test "content with no border gets full box dimensions" do
      content = [DisplayList.draw(0, 0, "hello")]

      draws =
        FloatingWindow.render(
          spec(content: content, width: {:cols, 20}, height: {:rows, 10}, border: :none)
        )

      content_draw = Enum.find(draws, fn {_, _, t, _} -> t == "hello" end)
      assert content_draw != nil

      {row, col, _, _} = content_draw
      # No border inset, so content starts at box origin
      # Box: row=7, col=30 (centered 20x10 in 80x24)
      assert row == 7
      assert col == 30
    end

    test "empty content produces no content draws" do
      draws = FloatingWindow.render(spec(content: [], width: {:cols, 20}, height: {:rows, 5}))
      # Should only have background + border draws
      assert draws != []
    end
  end

  describe "interior_size/1" do
    test "returns interior dimensions for bordered window" do
      s = spec(width: {:cols, 40}, height: {:rows, 20}, border: :rounded)
      assert FloatingWindow.interior_size(s) == {18, 38}
    end

    test "returns full dimensions for borderless window" do
      s = spec(width: {:cols, 40}, height: {:rows, 20}, border: :none)
      assert FloatingWindow.interior_size(s) == {20, 40}
    end

    test "returns clamped dimensions when window exceeds viewport" do
      s = spec(width: {:cols, 100}, height: {:rows, 50}, viewport: {24, 80}, border: :rounded)
      {h, w} = FloatingWindow.interior_size(s)
      assert h == 22
      assert w == 78
    end
  end

  describe "background fill" do
    test "background covers the entire box" do
      draws = FloatingWindow.render(spec(width: {:cols, 10}, height: {:rows, 5}))
      # Background draws should cover all 5 rows of the box
      bg_draws =
        Enum.filter(draws, fn {_, _, t, _} -> String.length(t) == 10 and String.trim(t) == "" end)

      assert length(bg_draws) == 5
    end
  end

  # ── Anchor positioning ─────────────────────────────────────────────────────

  describe "anchor positioning" do
    test "positions above cursor when there is room" do
      s = spec(position: {:anchor, 15, 10, :above}, height: {:rows, 5}, width: {:cols, 20})
      draws = FloatingWindow.render(s)
      rows = Enum.map(draws, fn {r, _c, _text, _s} -> r end)
      max_row = Enum.max(rows)
      assert max_row < 15
    end

    test "flips below cursor when not enough room above" do
      s = spec(position: {:anchor, 2, 10, :above}, height: {:rows, 5}, width: {:cols, 20})
      draws = FloatingWindow.render(s)
      rows = Enum.map(draws, fn {r, _c, _text, _s} -> r end)
      min_row = Enum.min(rows)
      assert min_row >= 2
    end

    test "positions below cursor when preferred" do
      s = spec(position: {:anchor, 5, 10, :below}, height: {:rows, 5}, width: {:cols, 20})
      draws = FloatingWindow.render(s)
      rows = Enum.map(draws, fn {r, _c, _text, _s} -> r end)
      min_row = Enum.min(rows)
      assert min_row > 5
    end

    test "flips above when not enough room below" do
      s = spec(position: {:anchor, 21, 10, :below}, height: {:rows, 5}, width: {:cols, 20})
      draws = FloatingWindow.render(s)
      rows = Enum.map(draws, fn {r, _c, _text, _s} -> r end)
      max_row = Enum.max(rows)
      assert max_row <= 21
    end

    test "clamps column to viewport" do
      s = spec(position: {:anchor, 10, 70, :above}, height: {:rows, 3}, width: {:cols, 20})
      draws = FloatingWindow.render(s)
      cols = Enum.map(draws, fn {_r, c, _text, _s} -> c end)
      max_col = Enum.max(cols)
      assert max_col < 80
    end
  end
end
