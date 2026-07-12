defmodule Minga.RenderModel.Window.RowTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.Window.Row

  describe "stable_id/3" do
    test "uses an injective kind, source, and producer slot layout" do
      ids = [
        Row.stable_id(:normal, 12, 0),
        Row.stable_id(:wrap_continuation, 12, 1),
        Row.stable_id(:fold_start, 12, 0),
        Row.stable_id(:virtual_line, 12, 1),
        Row.stable_id(:block, 12, 1),
        Row.stable_id(:decoration_fold, 12, 0),
        Row.stable_id(:normal, 13, 0)
      ]

      assert Enum.uniq(ids) == ids
      assert Row.stable_id(:normal, 12, 7) == Row.stable_id(:normal, 12, 7)
    end

    test "rejects values that cannot fit instead of masking into collisions" do
      assert_raise FunctionClauseError, fn -> Row.stable_id(:normal, 0x1_0000_0000) end
      assert_raise FunctionClauseError, fn -> Row.stable_id(:normal, 1, 0x1000_0000) end
    end
  end

  describe "stable_decoration_id/3" do
    test "accepts only producer-allocated integer slots" do
      assert Row.stable_decoration_id(:virtual_line, 12, 7) ==
               Row.stable_decoration_id(:virtual_line, 12, 7)

      assert Row.stable_decoration_id(:virtual_line, 12, 7) !=
               Row.stable_decoration_id(:virtual_line, 12, 8)

      assert Row.stable_decoration_id(:block, 12, 7) !=
               Row.stable_decoration_id(:virtual_line, 12, 7)
    end
  end
end
