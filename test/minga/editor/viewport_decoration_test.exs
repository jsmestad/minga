defmodule Minga.Editor.ViewportDecorationTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Editor.Viewport

  describe "effective_page_lines/4" do
    test "returns display_rows when no decorations exist" do
      decs = Decorations.new()
      assert Viewport.effective_page_lines(0, 20, decs, 100) == 20
    end

    test "returns fewer buffer lines when block decorations consume rows" do
      decs = Decorations.new()

      # Add block decorations at several lines (each consuming 1 display row)
      {_id, decs} =
        Decorations.add_block_decoration(decs, 5,
          placement: :above,
          render: fn _w -> [{"header", []}] end
        )

      {_id, decs} =
        Decorations.add_block_decoration(decs, 10,
          placement: :above,
          render: fn _w -> [{"header", []}] end
        )

      {_id, decs} =
        Decorations.add_block_decoration(decs, 15,
          placement: :above,
          render: fn _w -> [{"header", []}] end
        )

      result = Viewport.effective_page_lines(0, 20, decs, 100)
      # With 3 block decorations in the range, we should get fewer buffer lines
      assert result < 20
      assert result >= 17
    end

    test "returns at least 1 even when decorations are very dense" do
      decs = Decorations.new()

      # Add many block decorations
      decs =
        Enum.reduce(0..9, decs, fn line, acc ->
          {_id, acc} =
            Decorations.add_block_decoration(acc, line,
              placement: :above,
              render: fn _w -> [{"header", []}] end
            )

          acc
        end)

      result = Viewport.effective_page_lines(0, 5, decs, 100)
      assert result >= 1
    end

    test "handles cursor near end of file" do
      decs = Decorations.new()
      result = Viewport.effective_page_lines(95, 20, decs, 100)
      # Only 5 lines left, so result capped at 5
      assert result == 5
    end
  end
end
